/* caissa_prof.c -- cycle-exact per-function profiler for the 6502 image.
 *
 * Runs the SAME /tmp/caissa.sim image as caissa_cli on the cpu6502 core, but
 * accumulates a cycle-weighted PC histogram (cycles spent at each address) and
 * attributes it to the .map symbols. Answers "where do the chip's cycles go?"
 * so speed work can target the real hot function instead of guessing.
 *
 *   caissa_prof "FEN" DEPTH            -> top functions by cycle share
 *   ENGINE6502_SIM / ENGINE6502_MAP   override image/map (default /tmp/caissa.*)
 *
 * Build: cc -O2 caissa_prof.c ../fast6502_bridge/cpu6502.c -o caissa_prof
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include "../fast6502_bridge/cpu6502.h"

#define SIM_EXIT_REG    0xFFF8
#define SIM_PUTCHAR_REG 0xFFF9
#define EXIT_SENTINEL   0x5A
#define SIM_READY       0xA5
#define MAX_CYCLES_RUN  400000000000ULL

static cpu6502_t cpu;
static uint64_t pchist[0x10000];     /* cycles attributed to each PC */

typedef struct { unsigned addr; char name[64]; } Sym;
static Sym  syms[8192];
static int  nsym;

static int sym_cmp(const void *a, const void *b) {
    unsigned x = ((const Sym *)a)->addr, y = ((const Sym *)b)->addr;
    return x < y ? -1 : x > y ? 1 : 0;
}

/* Parse every "ADDR ... NAME" line of the ld map into (addr,name). A symbol
 * line begins with a hex address and ends with a token containing a letter or
 * '_' (filters the size/align numeric columns and section headers). */
static void load_syms(const char *mapfile) {
    FILE *f = fopen(mapfile, "r");
    char line[512];
    if (!f) { fprintf(stderr, "cannot open map %s\n", mapfile); exit(2); }
    while (fgets(line, sizeof line, f)) {
        unsigned addr; char buf[512], *tok, *last = NULL, *save;
        if (sscanf(line, " %x", &addr) != 1) continue;
        strncpy(buf, line, sizeof buf - 1); buf[sizeof buf - 1] = 0;
        for (tok = strtok_r(buf, " \t\r\n", &save); tok; tok = strtok_r(NULL, " \t\r\n", &save))
            last = tok;
        if (!last) continue;
        int has_alpha = 0;
        for (char *p = last; *p; p++)
            if ((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') || *p == '_') { has_alpha = 1; break; }
        if (!has_alpha) continue;
        if (strchr(last, ':') || strchr(last, '(') || strchr(last, '.')) continue; /* sections/files */
        if (nsym < (int)(sizeof syms / sizeof syms[0])) {
            syms[nsym].addr = addr;
            strncpy(syms[nsym].name, last, sizeof syms[nsym].name - 1);
            nsym++;
        }
    }
    fclose(f);
    qsort(syms, nsym, sizeof *syms, sym_cmp);
}

static int find_addr(const char *sym, uint16_t *out) {
    for (int i = 0; i < nsym; i++)
        if (!strcmp(syms[i].name, sym)) { *out = (uint16_t)syms[i].addr; return 0; }
    fprintf(stderr, "symbol %s not found\n", sym);
    return -1;
}

/* owning symbol = largest symbol address <= pc */
static int owner(unsigned pc) {
    int lo = 0, hi = nsym - 1, best = -1;
    while (lo <= hi) {
        int mid = (lo + hi) / 2;
        if (syms[mid].addr <= pc) { best = mid; lo = mid + 1; }
        else hi = mid - 1;
    }
    return best;
}

static int load_image(const char *path) {
    FILE *f = fopen(path, "rb");
    long fsz, off = 0; uint8_t *buf;
    if (!f) { perror("fopen image"); return -1; }
    fseek(f, 0, SEEK_END); fsz = ftell(f); fseek(f, 0, SEEK_SET);
    buf = malloc(fsz);
    if (fread(buf, 1, fsz, f) != (size_t)fsz) { perror("fread"); fclose(f); return -1; }
    fclose(f);
    memset(cpu.mem, 0, sizeof cpu.mem);
    while (off + 4 <= fsz) {
        uint16_t addr = buf[off] | (buf[off+1] << 8);
        uint16_t len  = buf[off+2] | (buf[off+3] << 8);
        off += 4;
        if (off + len > fsz) break;
        for (uint16_t i = 0; i < len; i++) cpu.mem[(uint16_t)(addr + i)] = buf[off + i];
        off += len;
    }
    free(buf);
    return 0;
}

int main(int argc, char **argv) {
    const char *sim = getenv("ENGINE6502_SIM"); const char *map = getenv("ENGINE6502_MAP");
    if (!sim) sim = "/tmp/caissa.sim";
    if (!map) map = "/tmp/caissa.map";
    if (argc < 3) { fprintf(stderr, "usage: %s \"FEN\" DEPTH\n", argv[0]); return 2; }
    const char *fen = argv[1]; int depth = atoi(argv[2]);

    load_syms(map);
    uint16_t A_fen, A_depth, A_done, A_go, A_nodes, A_qnodes;
    if (find_addr("g_fen", &A_fen) || find_addr("g_depth", &A_depth) ||
        find_addr("g_done", &A_done) || find_addr("g_go", &A_go) ||
        find_addr("g_nodes", &A_nodes) || find_addr("g_qnodes", &A_qnodes)) return 2;
    if (load_image(sim) < 0) return 2;

    cpu6502_reset(&cpu);
    cpu.mem[SIM_EXIT_REG] = EXIT_SENTINEL; cpu.mem[SIM_PUTCHAR_REG] = 0;
    cpu.pc = cpu.mem[0xFFFC] | (cpu.mem[0xFFFD] << 8);
    /* run to READY */
    while (cpu.cycles < MAX_CYCLES_RUN) {
        cpu6502_step(&cpu);
        if (cpu.mem[SIM_PUTCHAR_REG] == SIM_READY) break;
    }
    /* poke request */
    { size_t i; for (i = 0; i < strlen(fen) && i < 99; i++) cpu.mem[(uint16_t)(A_fen + i)] = (uint8_t)fen[i];
      cpu.mem[(uint16_t)(A_fen + i)] = 0; cpu.mem[A_depth] = (uint8_t)depth;
      cpu.mem[A_done] = 0; cpu.mem[A_go] = 1; }
    /* run the search, accumulating cycle-weighted PC histogram */
    uint64_t start = cpu.cycles;
    while (cpu.cycles < MAX_CYCLES_RUN) {
        uint16_t pc = cpu.pc;
        uint64_t c0 = cpu.cycles;
        cpu6502_step(&cpu);
        pchist[pc] += cpu.cycles - c0;
        if (cpu.mem[SIM_EXIT_REG] != EXIT_SENTINEL) break;
    }
    uint64_t total = cpu.cycles - start;

    /* fold PC histogram into per-symbol cycle totals */
    static uint64_t symcyc[8192];
    for (unsigned pc = 0; pc < 0x10000; pc++)
        if (pchist[pc]) { int s = owner(pc); if (s >= 0) symcyc[s] += pchist[pc]; }

    /* sort symbol indices by cycles desc */
    int idx[8192]; for (int i = 0; i < nsym; i++) idx[i] = i;
    for (int i = 0; i < nsym; i++)
        for (int j = i + 1; j < nsym; j++)
            if (symcyc[idx[j]] > symcyc[idx[i]]) { int t = idx[i]; idx[i] = idx[j]; idx[j] = t; }

    unsigned long nodes = cpu.mem[A_nodes] | (cpu.mem[A_nodes+1]<<8) |
                          ((unsigned long)cpu.mem[A_nodes+2]<<16) | ((unsigned long)cpu.mem[A_nodes+3]<<24);
    unsigned long qnodes = cpu.mem[A_qnodes] | (cpu.mem[A_qnodes+1]<<8) |
                           ((unsigned long)cpu.mem[A_qnodes+2]<<16) | ((unsigned long)cpu.mem[A_qnodes+3]<<24);
    /* Optional 3rd arg: dump the cycle histogram across a single function's PC
     * range in 16-byte buckets (relative position -> which loop is hot). */
    if (argc >= 4) {
        const char *want = argv[3];
        for (int i = 0; i < nsym; i++) {
            if (strcmp(syms[i].name, want)) continue;
            unsigned lo = syms[i].addr;
            unsigned hi = (i + 1 < nsym) ? syms[i+1].addr : lo + 0x800;
            uint64_t fn = 0; for (unsigned pc = lo; pc < hi; pc++) fn += pchist[pc];
            printf("=== %s  [%04X,%04X)  %llu cycles ===\n", want, lo, hi, (unsigned long long)fn);
            for (unsigned base = lo; base < hi; base += 16) {
                uint64_t b = 0; for (unsigned pc = base; pc < base+16 && pc < hi; pc++) b += pchist[pc];
                if (b) printf("  +%-4u (%04X)  %12llu  %5.1f%%\n", base - lo, base,
                              (unsigned long long)b, fn ? 100.0*b/fn : 0.0);
            }
            return 0;
        }
        fprintf(stderr, "fn %s not found\n", want); return 2;
    }

    printf("FEN %s  depth %d\n", fen, depth);
    printf("total cycles=%llu  nodes=%lu  qnodes=%lu  (%.0f cyc/node)\n",
           (unsigned long long)total, nodes, qnodes,
           (nodes+qnodes) ? (double)total/(nodes+qnodes) : 0.0);
    printf("%-32s %14s  %6s\n", "function", "cycles", "share");
    double acc = 0;
    for (int i = 0; i < nsym && i < 28; i++) {
        if (!symcyc[idx[i]]) break;
        double share = 100.0 * symcyc[idx[i]] / total;
        acc += share;
        printf("%-32s %14llu  %5.1f%%  (cum %5.1f%%)\n",
               syms[idx[i]].name, (unsigned long long)symcyc[idx[i]], share, acc);
    }
    return 0;
}
