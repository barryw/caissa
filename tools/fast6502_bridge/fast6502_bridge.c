/*
 * fast6502_bridge.c - drop-in replacement for the .NET Sim6502HeadlessBridge.
 *
 * Speaks the identical JSON-lines stdin/stdout protocol (see
 * tools/sim6502_headless_runner.py) but drives a fast functional 6502 core
 * (cpu6502.c) instead of the cycle-accurate .NET sim6502.  With no cycle-based
 * timeout the move/eval/zobrist output is bit-for-bit identical; the win is
 * raw speed for on-chip Elo measurement.
 *
 * Behaviour is a faithful port of tools/Sim6502HeadlessBridge/Program.cs:
 *   - load prg (strip 2-byte load address), parse .sym (.label NAME=$HEX),
 *     snapshot post-load 64K as the baseline.
 *   - per request: RestoreBaseline, run InitZobristTables + (TTClear),
 *     WritePosition exactly as BuildPieceList does, run the routine to
 *     completion via JSR/RTS nesting, read the result bytes.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <stdint.h>
#include "cpu6502.h"

/* ----------------------------- symbol table ----------------------------- */
#define MAX_SYMBOLS 8192
typedef struct { char name[64]; int addr; } sym_t;
static sym_t g_syms[MAX_SYMBOLS];
static int   g_nsyms = 0;

static int sym_lookup(const char *name, int *addr) {
    for (int i = 0; i < g_nsyms; i++) {
        if (strcmp(g_syms[i].name, name) == 0) { *addr = g_syms[i].addr; return 1; }
    }
    return 0;
}
/* Required-symbol lookup: fatal if missing (matches Symbol() throwing). */
static int sym_req(const char *name) {
    int a;
    if (!sym_lookup(name, &a)) {
        fprintf(stderr, "Missing symbol: %s\n", name);
        exit(2);
    }
    return a;
}

static void load_symbols(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) { fprintf(stderr, "Cannot open symbols: %s\n", path); exit(2); }
    char line[512];
    while (fgets(line, sizeof line, f)) {
        /* Match: ^\.label\s+NAME=$HEX\s*$  (NAME = [A-Za-z_][A-Za-z0-9_]*) */
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (strncmp(p, ".label", 6) != 0) continue;
        p += 6;
        while (*p == ' ' || *p == '\t') p++;
        char name[64]; int ni = 0;
        if (!(isalpha((unsigned char)*p) || *p == '_')) continue;
        while ((isalnum((unsigned char)*p) || *p == '_') && ni < 63) name[ni++] = *p++;
        name[ni] = '\0';
        if (*p != '=') continue;
        p++;
        if (*p != '$') continue;
        p++;
        int addr = 0, got = 0;
        while (isxdigit((unsigned char)*p)) {
            int d = (*p <= '9') ? *p - '0'
                  : (tolower(*p) - 'a' + 10);
            addr = addr * 16 + d; p++; got = 1;
        }
        if (!got) continue;
        if (g_nsyms < MAX_SYMBOLS) {
            strcpy(g_syms[g_nsyms].name, name);
            g_syms[g_nsyms].addr = addr;
            g_nsyms++;
        }
    }
    fclose(f);
}

/* ----------------------------- machine ----------------------------- */
static cpu6502_t g_cpu;
static uint8_t   g_baseline[65536];
static int       g_findbest_addr;
static int       g_routine_timed_out = 0;

static void load_program(const char *path, int strip_header) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "Cannot open program: %s\n", path); exit(2); }
    static uint8_t buf[70000];
    size_t n = fread(buf, 1, sizeof buf, f);
    fclose(f);
    if (n == 0) { fprintf(stderr, "Program is empty: %s\n", path); exit(2); }
    int addr = 0;
    uint8_t *payload = buf; size_t plen = n;
    if (strip_header) {
        if (n < 2) { fprintf(stderr, "PRG missing load address\n"); exit(2); }
        addr = buf[0] | (buf[1] << 8);
        payload = buf + 2; plen = n - 2;
    }
    for (size_t i = 0; i < plen; i++)
        g_cpu.mem[(addr + i) & 0xFFFF] = payload[i];
}

/* RestoreBaseline: copy baseline 64K back; reset regs (A=X=Y=0, flags clear,
 * I set, SP=0xFD), cycle counter=0. */
static void restore_baseline(void) {
    memcpy(g_cpu.mem, g_baseline, sizeof g_baseline);
    cpu6502_reset(&g_cpu);
}

/* ExecuteRoutine: run from `address` to completion using JSR/RTS nesting.
 * Returns 1 if it exited cleanly (top-level RTS), 0 if BRK or timeout.
 * Sets g_routine_timed_out. timeout_cycles==0 means no limit. */
static int execute_routine(int address, uint64_t timeout_cycles) {
    int keep = 1;
    int sub_count = 1;
    int clean = 1;
    uint64_t start = g_cpu.cycles;
    g_cpu.pc = (uint16_t)address;
    g_routine_timed_out = 0;

    do {
        uint8_t op = cpu6502_peek_opcode(&g_cpu);

        if (op == 0x20) sub_count++;          /* JSR */

        if (op == 0x60) {                     /* RTS */
            sub_count--;
            if (sub_count == 0) { keep = 0; break; }
        }

        if (op == 0x00) {                     /* BRK -> unclean stop */
            keep = 0;
            clean = 0;
        }

        cpu6502_step(&g_cpu);

        if (timeout_cycles > 0 && (g_cpu.cycles - start) > timeout_cycles) {
            g_routine_timed_out = 1;
            keep = 0;
        }
    } while (keep);

    return clean && !g_routine_timed_out;
}

static int execute_required(int address, uint64_t timeout, const char *label) {
    int clean = execute_routine(address, timeout);
    if (!clean) {
        fprintf(stderr, "%s exited via BRK or timeout\n", label);
        return 0;
    }
    return 1;
}

/* ----------------------------- tiny JSON ----------------------------- */
/* The request objects are flat: integer fields, a "command" string, and a
 * "board88" array of 128 integers.  We only need to extract those forms. */

/* Find the value start for a top-level "key": in the line.  Returns pointer to
 * the first char of the value, or NULL if the key is absent. */
static const char *json_find(const char *json, const char *key) {
    size_t klen = strlen(key);
    const char *p = json;
    while ((p = strchr(p, '"')) != NULL) {
        const char *kstart = p + 1;
        if (strncmp(kstart, key, klen) == 0 && kstart[klen] == '"') {
            const char *q = kstart + klen + 1;
            while (*q == ' ' || *q == '\t') q++;
            if (*q == ':') {
                q++;
                while (*q == ' ' || *q == '\t') q++;
                return q;
            }
        }
        p = kstart;   /* keep scanning after this quote */
    }
    return NULL;
}

static int json_get_int(const char *json, const char *key, int fallback, int *found) {
    const char *v = json_find(json, key);
    if (!v) { if (found) *found = 0; return fallback; }
    if (found) *found = 1;
    return (int)strtol(v, NULL, 10);
}
static long long json_get_ll(const char *json, const char *key, long long fallback) {
    const char *v = json_find(json, key);
    if (!v) return fallback;
    return strtoll(v, NULL, 10);
}
/* Parse the "command" string value; copies up to out_sz-1 chars. */
static void json_get_str(const char *json, const char *key, char *out, size_t out_sz, const char *fallback) {
    const char *v = json_find(json, key);
    if (!v || *v != '"') { strncpy(out, fallback, out_sz - 1); out[out_sz - 1] = '\0'; return; }
    v++;
    size_t i = 0;
    while (*v && *v != '"' && i < out_sz - 1) out[i++] = *v++;
    out[i] = '\0';
}
/* Parse board88 array of 128 ints. Returns count parsed. */
static int json_get_board88(const char *json, int *out /*128*/) {
    const char *v = json_find(json, "board88");
    if (!v || *v != '[') return -1;
    v++;
    int n = 0;
    while (*v && *v != ']') {
        while (*v == ' ' || *v == ',' || *v == '\t' || *v == '\n') v++;
        if (*v == ']') break;
        if (!(isdigit((unsigned char)*v) || *v == '-')) { v++; continue; }
        long val = strtol(v, (char **)&v, 10);
        if (n < 128) out[n] = (int)(val & 0xFF);
        n++;
    }
    return n;
}

/* ----------------------------- WritePosition ----------------------------- */
/* Returns 0 on success, -1 on piece-list overflow (error). */
static int write_position(const char *json) {
    int board88[128];
    int bn = json_get_board88(json, board88);
    if (bn != 128) { fprintf(stderr, "board88 must contain 128 bytes, got %d\n", bn); return -1; }

    int found;
    int whiteKing = json_get_int(json, "whitekingsq", 0, &found);
    int blackKing = json_get_int(json, "blackkingsq", 0, &found);

    /* BuildPieceList: king square first, then scan 0..127 skipping empties and
     * the king square; add squares whose white-bit matches the side. */
    int wpl[64], bpl[64], wn = 0, bn_pieces = 0;
    wpl[wn++] = whiteKing;
    bpl[bn_pieces++] = blackKing;
    for (int i = 0; i < 128; i++) {
        int piece = board88[i];
        if (piece == 0x30) continue;
        if (i == whiteKing || i == blackKing) {
            /* Skip the side's own king square; but a king sq only matches its
             * own colour scan, and the reference skips i==kingSquare per-list.
             * Replicate exactly: for white list skip whiteKing; for black skip
             * blackKing.  Handled below per-list instead. */
        }
    }
    /* Replicate BuildPieceList precisely, once per side. */
    wn = 0; bn_pieces = 0;
    wpl[wn++] = whiteKing;
    for (int i = 0; i < 128; i++) {
        int piece = board88[i];
        if (piece == 0x30 || i == whiteKing) continue;
        if (piece & 0x80) wpl[wn++] = i;       /* white */
    }
    bpl[bn_pieces++] = blackKing;
    for (int i = 0; i < 128; i++) {
        int piece = board88[i];
        if (piece == 0x30 || i == blackKing) continue;
        if (!(piece & 0x80)) bpl[bn_pieces++] = i; /* black */
    }
    if (wn > 16) { fprintf(stderr, "White piece list overflow: %d\n", wn); return -1; }
    if (bn_pieces > 16) { fprintf(stderr, "Black piece list overflow: %d\n", bn_pieces); return -1; }

    int board_addr = sym_req("Board88");
    for (int i = 0; i < 128; i++) g_cpu.mem[(board_addr + i) & 0xFFFF] = 0x30;
    for (int i = 0; i < 128; i++) g_cpu.mem[(board_addr + i) & 0xFFFF] = (uint8_t)board88[i];

    int wpl_addr = sym_req("WhitePieceList");
    int bpl_addr = sym_req("BlackPieceList");
    for (int i = 0; i < 16; i++) g_cpu.mem[(wpl_addr + i) & 0xFFFF] = 0xFF;
    for (int i = 0; i < 16; i++) g_cpu.mem[(bpl_addr + i) & 0xFFFF] = 0xFF;
    for (int i = 0; i < wn; i++)        g_cpu.mem[(wpl_addr + i) & 0xFFFF] = (uint8_t)wpl[i];
    for (int i = 0; i < bn_pieces; i++) g_cpu.mem[(bpl_addr + i) & 0xFFFF] = (uint8_t)bpl[i];

#define WB(label, val) g_cpu.mem[sym_req(label) & 0xFFFF] = (uint8_t)((val) & 0xFF)
    WB("currentplayer", json_get_int(json, "currentplayer", 0, &found));
    WB("difficulty",    json_get_int(json, "difficulty", 0, &found));
    WB("whitekingsq",   whiteKing);
    WB("blackkingsq",   blackKing);
    WB("castlerights",  json_get_int(json, "castlerights", 0, &found));
    WB("enpassantsq",   json_get_int(json, "enpassantsq", 0, &found));
    WB("HalfmoveClock", json_get_int(json, "halfmoveClock", 0, &found));

    int fullMove = json_get_int(json, "fullmoveNumber", 1, &found);
    int fm_addr = sym_req("FullmoveNumber");
    g_cpu.mem[fm_addr & 0xFFFF]       = (uint8_t)(fullMove & 0xFF);
    g_cpu.mem[(fm_addr + 1) & 0xFFFF] = (uint8_t)((fullMove >> 8) & 0xFF);

    WB("HistoryCount", 0);
    WB("WhitePieceCount", wn);
    WB("BlackPieceCount", bn_pieces);
    { int a; if (sym_lookup("promotionsq", &a)) g_cpu.mem[a & 0xFFFF] = 0xFF; }
    WB("BestMoveFrom", 0xFF);
    WB("BestMoveTo", 0xFF);
#undef WB
    return 0;
}

/* read a byte by symbol */
static int read_byte_sym(const char *label) {
    return g_cpu.mem[sym_req(label) & 0xFFFF];
}
static int try_read_byte_sym(const char *label, int *out) {
    int a;
    if (!sym_lookup(label, &a)) return 0;
    *out = g_cpu.mem[a & 0xFFFF];
    return 1;
}

/* ----------------------------- commands ----------------------------- */
static void emit_bestmove(int id, const char *json) {
    restore_baseline();
    uint64_t timeout = (uint64_t)json_get_ll(json, "timeoutCycles", 0);

    if (!execute_required(sym_req("InitZobristTables"), timeout, "InitZobristTables")) { printf("{\"id\":%d,\"ok\":false,\"error\":\"InitZobristTables\"}\n", id); fflush(stdout); return; }
    if (!execute_required(sym_req("TTClear"), timeout, "TTClear")) { printf("{\"id\":%d,\"ok\":false,\"error\":\"TTClear\"}\n", id); fflush(stdout); return; }
    if (write_position(json) != 0) { printf("{\"id\":%d,\"ok\":false,\"error\":\"WritePosition\"}\n", id); fflush(stdout); return; }

    uint64_t before = g_cpu.cycles;
    int clean = execute_routine(g_findbest_addr, timeout);
    int timed_out = g_routine_timed_out;
    uint64_t total = g_cpu.cycles;

    int bestFrom = read_byte_sym("BestMoveFrom");
    int bestTo   = read_byte_sym("BestMoveTo");
    if (timed_out) {
        bestFrom = read_byte_sym("CommittedBestFrom");
        bestTo   = read_byte_sym("CommittedBestTo");
    }
    int encoded = (bestFrom << 8) | bestTo;
    int ok = clean || (timed_out && bestFrom != 0xFF);

    int scd; int has_scd = try_read_byte_sym("SearchCompletedDepth", &scd);
    int sd;  int has_sd  = try_read_byte_sym("SearchDepth", &sd);
    int rmc; int has_rmc = try_read_byte_sym("SearchRootMoveCount", &rmc);
    int ub;  int has_ub  = try_read_byte_sym("SearchUsedBook", &ub);

    printf("{\"id\":%d,\"ok\":%s,\"timedOut\":%s,"
           "\"bestMoveFrom\":%d,\"bestMoveTo\":%d,\"encoded\":%d,"
           "\"cycles\":%llu,\"searchCycles\":%llu,",
           id, ok ? "true" : "false", timed_out ? "true" : "false",
           bestFrom, bestTo, encoded,
           (unsigned long long)total, (unsigned long long)(total - before));
    if (has_sd)  printf("\"searchDepth\":%d,", sd);          else printf("\"searchDepth\":null,");
    if (has_scd) printf("\"searchCompletedDepth\":%d,", scd); else printf("\"searchCompletedDepth\":null,");
    if (has_rmc) printf("\"searchRootMoveCount\":%d,", rmc);  else printf("\"searchRootMoveCount\":null,");
    if (has_ub)  printf("\"searchUsedBook\":%d,", ub);        else printf("\"searchUsedBook\":null,");
    printf("\"pc\":%d}\n", g_cpu.pc);
    fflush(stdout);
}

static void emit_zobrist(int id, const char *json) {
    restore_baseline();
    uint64_t timeout = (uint64_t)json_get_ll(json, "timeoutCycles", 0);
    if (!execute_required(sym_req("InitZobristTables"), timeout, "InitZobristTables")) { printf("{\"id\":%d,\"ok\":false,\"error\":\"InitZobristTables\"}\n", id); fflush(stdout); return; }
    if (write_position(json) != 0) { printf("{\"id\":%d,\"ok\":false,\"error\":\"WritePosition\"}\n", id); fflush(stdout); return; }
    int clean = execute_routine(sym_req("ComputeZobristHash"), timeout);
    int zaddr = sym_req("ZobristHash");
    int keyLo = g_cpu.mem[zaddr & 0xFFFF];
    int keyHi = g_cpu.mem[(zaddr + 1) & 0xFFFF];
    printf("{\"id\":%d,\"ok\":%s,\"keyLo\":%d,\"keyHi\":%d,\"key\":%d,\"cycles\":%llu,\"pc\":%d}\n",
           id, clean ? "true" : "false", keyLo, keyHi, (keyHi << 8) | keyLo,
           (unsigned long long)g_cpu.cycles, g_cpu.pc);
    fflush(stdout);
}

static void emit_eval(int id, const char *json) {
    restore_baseline();
    uint64_t timeout = (uint64_t)json_get_ll(json, "timeoutCycles", 0);
    if (!execute_required(sym_req("InitZobristTables"), timeout, "InitZobristTables")) { printf("{\"id\":%d,\"ok\":false,\"error\":\"InitZobristTables\"}\n", id); fflush(stdout); return; }
    if (write_position(json) != 0) { printf("{\"id\":%d,\"ok\":false,\"error\":\"WritePosition\"}\n", id); fflush(stdout); return; }
    int found;
    int lazy = json_get_int(json, "lazy", 0, &found);
    int ela; if (sym_lookup("EvalLazyStage", &ela)) g_cpu.mem[ela & 0xFFFF] = (uint8_t)(lazy & 0xFF);
    int clean = execute_routine(sym_req("EvaluatePosition"), timeout);
    int eaddr = sym_req("EvalScore");
    int lo = g_cpu.mem[eaddr & 0xFFFF];
    int hi = g_cpu.mem[(eaddr + 1) & 0xFFFF];
    int raw = (hi << 8) | lo;
    if (raw >= 0x8000) raw -= 0x10000;
    printf("{\"id\":%d,\"ok\":%s,\"eval\":%d,\"evalLo\":%d,\"evalHi\":%d,\"cycles\":%llu}\n",
           id, clean ? "true" : "false", raw, lo, hi, (unsigned long long)g_cpu.cycles);
    fflush(stdout);
}

/* ----------------------------- main loop ----------------------------- */
int main(int argc, char **argv) {
    const char *program_path = NULL, *symbols_path = NULL;
    const char *findbest_label = "ChessFindBestMove";
    int strip_header = 1;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--program") == 0 && i + 1 < argc)      program_path = argv[++i];
        else if (strcmp(argv[i], "--symbols") == 0 && i + 1 < argc) symbols_path = argv[++i];
        else if (strcmp(argv[i], "--find-best-move") == 0 && i + 1 < argc) findbest_label = argv[++i];
        else if (strcmp(argv[i], "--no-strip-header") == 0)         strip_header = 0;
        else if (strcmp(argv[i], "--help") == 0) {
            fprintf(stderr, "Usage: fast6502_bridge --program <prg> --symbols <sym> "
                            "[--find-best-move ChessFindBestMove]\n");
            return 0;
        } else {
            fprintf(stderr, "Unknown argument: %s\n", argv[i]);
            return 2;
        }
    }
    if (!program_path) { fprintf(stderr, "--program is required\n"); return 2; }
    if (!symbols_path) { fprintf(stderr, "--symbols is required\n"); return 2; }

    memset(&g_cpu, 0, sizeof g_cpu);
    load_symbols(symbols_path);
    load_program(program_path, strip_header);
    memcpy(g_baseline, g_cpu.mem, sizeof g_baseline);
    g_findbest_addr = sym_req(findbest_label);

    /* ready line */
    printf("{\"ready\":true,\"emulator\":\"fast6502\",\"processor\":\"MOS6510\",\"findBestMove\":\"%s\"}\n",
           findbest_label);
    fflush(stdout);

    char *line = NULL;
    size_t cap = 0;
    ssize_t len;
    while ((len = getline(&line, &cap, stdin)) != -1) {
        /* skip blank */
        char *s = line;
        while (*s == ' ' || *s == '\t' || *s == '\r' || *s == '\n') s++;
        if (*s == '\0') continue;

        int found;
        int id = json_get_int(line, "id", 0, &found);
        char cmd[32];
        json_get_str(line, "command", cmd, sizeof cmd, "bestmove");

        if (strcmp(cmd, "quit") == 0) {
            printf("{\"id\":%d,\"ok\":true,\"command\":\"quit\"}\n", id);
            fflush(stdout);
            break;
        } else if (strcmp(cmd, "bestmove") == 0) {
            emit_bestmove(id, line);
        } else if (strcmp(cmd, "zobrist") == 0) {
            emit_zobrist(id, line);
        } else if (strcmp(cmd, "eval") == 0) {
            emit_eval(id, line);
        } else {
            /* ponder/ponderuse stubbed; unknown -> error like the reference */
            printf("{\"id\":%d,\"ok\":false,\"error\":\"Unknown command: %s\"}\n", id, cmd);
            fflush(stdout);
        }
    }
    free(line);
    return 0;
}
