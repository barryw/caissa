/* validate.c -- drive the llvm-mos 6502 "bestmove" image (engine6502.sim) inside
 * the cycle-exact fast6502 core and compare its chosen move, move-for-move, to
 * the host reference engine (native/cref bestmove).
 *
 * This is the VALIDATION GATE for "native C chess engine, running on a real 6502,
 * computes the same best move as the host." See engine6502.c for the memory ABI.
 *
 * Flow per FEN (handshake described in engine6502.c):
 *   1. load engine6502.sim chunks into the 6502's flat 64K, PC <- reset vector
 *   2. run until the sim putchar register == SIM_READY (main() is ready)
 *   3. write the FEN string into g_fen[], the depth into g_depth, set g_go = 1
 *   4. run until the sim exit register is written (main returned) or g_done == 1
 *   5. read g_from/g_to/g_promo, decode to UCI, compare to cref
 *
 * ABI symbol addresses are read from the linker .map at startup, so a rebuild
 * that relocates symbols stays correct with no edits here.
 *
 * Build: cc -O2 validate.c ../fast6502_bridge/cpu6502.c -o validate
 * Run:   ./validate engine6502.sim engine6502.map <fenlist> <depth> [oracle]
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include "../fast6502_bridge/cpu6502.h"

#define SIM_EXIT_REG    0xFFF8
#define SIM_PUTCHAR_REG 0xFFF9   /* mos sim putchar register (sim-io.h: 0xFFF0+9) */
#define EXIT_SENTINEL   0x5A
#define SIM_READY       0xA5
#define MAX_CYCLES_RUN  60000000000ULL   /* generous ceiling per move */

static cpu6502_t cpu;

/* ---- ABI symbol addresses, resolved from the .map ---- */
static uint16_t A_g_fen, A_g_depth, A_g_from, A_g_to, A_g_promo, A_g_done,
                A_g_status, A_g_go;

/* Parse one symbol's VMA from the lld map. Lines look like:
 *     8400      8400        64     1                 g_fen
 * i.e. whitespace-separated; column 1 is the hex VMA, last column the name. */
static int map_addr(const char *mapfile, const char *sym, uint16_t *out) {
    FILE *f = fopen(mapfile, "r");
    char line[512];
    size_t slen = strlen(sym);
    if (!f) { fprintf(stderr, "cannot open map %s\n", mapfile); return -1; }
    while (fgets(line, sizeof line, f)) {
        /* last whitespace-delimited token == sym ? */
        char *tok, *last = NULL, *save;
        char buf[512];
        strncpy(buf, line, sizeof buf - 1); buf[sizeof buf - 1] = 0;
        for (tok = strtok_r(buf, " \t\r\n", &save); tok;
             tok = strtok_r(NULL, " \t\r\n", &save))
            last = tok;
        if (last && strlen(last) == slen && strcmp(last, sym) == 0) {
            /* first token is the hex VMA */
            unsigned v;
            if (sscanf(line, " %x", &v) == 1) { *out = (uint16_t)v; fclose(f); return 0; }
        }
    }
    fclose(f);
    fprintf(stderr, "symbol %s not found in %s\n", sym, mapfile);
    return -1;
}

static int load_image(const char *path) {
    FILE *f = fopen(path, "rb");
    long fsz; uint8_t *buf; long off = 0; int chunks = 0;
    if (!f) { perror("fopen image"); return -1; }
    fseek(f, 0, SEEK_END); fsz = ftell(f); fseek(f, 0, SEEK_SET);
    buf = malloc(fsz);
    if (fread(buf, 1, fsz, f) != (size_t)fsz) { perror("fread"); fclose(f); return -1; }
    fclose(f);
    memset(cpu.mem, 0, sizeof(cpu.mem));
    while (off + 4 <= fsz) {
        uint16_t addr = buf[off] | (buf[off+1] << 8);
        uint16_t len  = buf[off+2] | (buf[off+3] << 8);
        off += 4;
        if (off + len > fsz) break;
        for (uint16_t i = 0; i < len; i++)
            cpu.mem[(uint16_t)(addr + i)] = buf[off + i];
        off += len; chunks++;
    }
    free(buf);
    return chunks;
}

/* 0x88 square -> "e2"-style file/rank. board.h: idx = (7-rank)*16 + file,
 * a8 = 0 .. h1 = 119; file = idx&7, rank8..1 as (7 - idx/16). */
static void sq0x88_to_str(uint8_t sq, char *out) {
    int file = sq & 7;
    int rank = 7 - (sq >> 4);          /* 0..7, 0 = rank 1 */
    out[0] = 'a' + file;
    out[1] = '1' + rank;
    out[2] = 0;
}

static const char promo_char[7] = {0,0,'n','b','r','q',0};

/* Run the loaded image for one bestmove: handshake, inject, finish.
 * Returns 0 on success and fills uci[]; -1 on timeout/parse-fail. */
static int run_bestmove(const char *fen, unsigned char depth, char *uci,
                        unsigned long long *cycles_out, int *status_out) {
    uint16_t reset;
    unsigned long long c0;

    cpu6502_reset(&cpu);
    cpu.mem[SIM_EXIT_REG]    = EXIT_SENTINEL;
    cpu.mem[SIM_PUTCHAR_REG] = 0x00;
    reset = cpu.mem[0xFFFC] | (cpu.mem[0xFFFD] << 8);
    cpu.pc = reset;

    /* (2) run until READY */
    while (cpu.cycles < MAX_CYCLES_RUN) {
        cpu6502_step(&cpu);
        if (cpu.mem[SIM_PUTCHAR_REG] == SIM_READY) break;
        if (cpu.mem[SIM_EXIT_REG] != EXIT_SENTINEL) {
            fprintf(stderr, "image exited before READY\n");
            return -1;
        }
    }
    if (cpu.cycles >= MAX_CYCLES_RUN) { fprintf(stderr, "timeout waiting READY\n"); return -1; }

    /* (3) inject FEN + depth, then flip g_go */
    {
        size_t i;
        for (i = 0; i < strlen(fen) && i < 99; i++)
            cpu.mem[(uint16_t)(A_g_fen + i)] = (uint8_t)fen[i];
        cpu.mem[(uint16_t)(A_g_fen + i)] = 0;
        cpu.mem[A_g_depth] = depth;
        cpu.mem[A_g_done]  = 0;
        cpu.mem[A_g_go]    = 1;
    }

    /* (4) run until exit (main returned) */
    c0 = cpu.cycles;
    while (cpu.cycles < MAX_CYCLES_RUN) {
        cpu6502_step(&cpu);
        if (cpu.mem[SIM_EXIT_REG] != EXIT_SENTINEL) break;
    }
    if (cpu.cycles >= MAX_CYCLES_RUN) { fprintf(stderr, "timeout during search\n"); return -1; }
    *cycles_out = cpu.cycles - c0;

    /* (5) read result */
    *status_out = cpu.mem[A_g_status];
    if (cpu.mem[A_g_done] != 1) { fprintf(stderr, "g_done not set\n"); return -1; }
    if (*status_out != 0) { strcpy(uci, "0000"); return 0; }   /* FEN parse error */
    {
        uint8_t from = cpu.mem[A_g_from], to = cpu.mem[A_g_to], pr = cpu.mem[A_g_promo];
        char fs[3], ts[3];
        sq0x88_to_str(from, fs);
        sq0x88_to_str(to, ts);
        uci[0] = fs[0]; uci[1] = fs[1]; uci[2] = ts[0]; uci[3] = ts[1];
        if (pr >= 2 && pr <= 5) { uci[4] = promo_char[pr]; uci[5] = 0; }
        else uci[4] = 0;
    }
    return 0;
}

/* call the host oracle: `<oracle> bestmove "FEN" DEPTH` -> first uci token */
static int oracle_bestmove(const char *oracle, const char *fen, int depth, char *uci) {
    char cmd[1024], line[256];
    FILE *p;
    snprintf(cmd, sizeof cmd, "%s bestmove \"%s\" %d", oracle, fen, depth);
    p = popen(cmd, "r");
    if (!p) return -1;
    if (!fgets(line, sizeof line, p)) { pclose(p); return -1; }
    pclose(p);
    /* "bestmove <uci> score ..." */
    if (sscanf(line, "bestmove %5s", uci) != 1) return -1;
    return 0;
}

int main(int argc, char **argv) {
    const char *image, *mapf, *fenlist, *oracle;
    int depth;
    FILE *ff;
    char line[300];
    int total = 0, ok = 0, fails = 0;
    unsigned long long cyc_sum = 0, cyc_max = 0;

    if (argc < 5) {
        fprintf(stderr,
          "usage: %s engine6502.sim engine6502.map fenlist.txt depth [oracle=../../build/cref]\n",
          argv[0]);
        return 2;
    }
    image = argv[1]; mapf = argv[2]; fenlist = argv[3]; depth = atoi(argv[4]);
    oracle = (argc > 5) ? argv[5] : "../../build/cref";

    if (map_addr(mapf, "g_fen",   &A_g_fen)   ||
        map_addr(mapf, "g_depth", &A_g_depth) ||
        map_addr(mapf, "g_from",  &A_g_from)  ||
        map_addr(mapf, "g_to",    &A_g_to)    ||
        map_addr(mapf, "g_promo", &A_g_promo) ||
        map_addr(mapf, "g_done",  &A_g_done)  ||
        map_addr(mapf, "g_status",&A_g_status)||
        map_addr(mapf, "g_go",    &A_g_go)) return 2;

    fprintf(stderr,
      "ABI: g_fen=0x%04X g_depth=0x%04X g_from=0x%04X g_to=0x%04X g_promo=0x%04X "
      "g_done=0x%04X g_status=0x%04X g_go=0x%04X\n",
      A_g_fen, A_g_depth, A_g_from, A_g_to, A_g_promo, A_g_done, A_g_status, A_g_go);

    if (load_image(image) < 0) return 2;

    ff = fopen(fenlist, "r");
    if (!ff) { perror("fopen fenlist"); return 2; }

    while (fgets(line, sizeof line, ff)) {
        char fen[200], uci6502[8], ucihost[8];
        unsigned long long cyc; int st;
        char *nl;
        /* a fenlist line is a bare FEN (possibly TSV: FEN<TAB>...) */
        char *tab = strchr(line, '\t'); if (tab) *tab = 0;
        nl = strpbrk(line, "\r\n"); if (nl) *nl = 0;
        if (line[0] == 0 || line[0] == '#') continue;
        strncpy(fen, line, sizeof fen - 1); fen[sizeof fen - 1] = 0;

        /* reload image fresh each move (clears all engine state). */
        load_image(image);
        if (run_bestmove(fen, (unsigned char)depth, uci6502, &cyc, &st) != 0) {
            printf("[ERR ] 6502 run failed: %s\n", fen);
            fails++; total++; continue;
        }
        if (oracle_bestmove(oracle, fen, depth, ucihost) != 0) {
            printf("[ERR ] oracle failed: %s\n", fen);
            fails++; total++; continue;
        }
        total++;
        cyc_sum += cyc; if (cyc > cyc_max) cyc_max = cyc;
        if (strcmp(uci6502, ucihost) == 0) {
            ok++;
            printf("[ OK ] %-6s  cyc=%-10llu  %s\n", uci6502, cyc, fen);
        } else {
            printf("[DIFF] 6502=%-6s host=%-6s  %s\n", uci6502, ucihost, fen);
        }
    }
    fclose(ff);

    printf("\n=== VALIDATION: %d/%d identical to oracle '%s' at depth %d"
           " (%d run-errors) ===\n", ok, total, oracle, depth, fails);
    if (total)
        printf("cycles/move: avg=%llu  max=%llu  -> @1MHz avg=%.2fs max=%.2fs\n",
               cyc_sum / total, cyc_max,
               (cyc_sum / (double)total) / 1e6, cyc_max / 1e6);
    return (ok == total && fails == 0) ? 0 : 1;
}
