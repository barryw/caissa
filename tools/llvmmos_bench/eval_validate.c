/* eval_validate.c -- drive the llvm-mos 6502 "eval" image (eval6502.sim) inside
 * the cycle-exact fast6502 core and print eval_full's score for each input FEN.
 *
 * This is the host side of the bit-exact safety net for hand-asm'ing eval_full:
 * tools/eval_corpus_check.py feeds it the 22157-position texel corpus on stdin
 * and diffs every score against tools/texel_eval.py eval_full. See eval6502.c
 * for the memory ABI.
 *
 * Flow per FEN (handshake described in eval6502.c):
 *   1. load eval6502.sim chunks into the 6502's flat 64K, PC <- reset vector
 *   2. run until the sim putchar register == SIM_READY (main() is ready)
 *   3. write the FEN string into g_fen[], set g_go = 1
 *   4. run until the sim exit register is written (main returned) or g_done == 1
 *   5. read g_score / g_status, print the signed score (or ERR on parse-fail)
 *
 * ABI symbol addresses are read from the linker .map at startup, so a rebuild
 * that relocates symbols stays correct with no edits here.
 *
 * Build: cc -O2 eval_validate.c ../fast6502_bridge/cpu6502.c -o eval_validate
 * Run:   ./eval_validate eval6502.sim eval6502.map < fenlist   (FENs on stdin)
 *        -> one line per FEN on stdout: signed g_score, or "ERR" if g_status==1
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
#define MAX_CYCLES_RUN  60000000000ULL   /* generous ceiling per FEN */

static cpu6502_t cpu;

/* ---- ABI symbol addresses, resolved from the .map ---- */
static uint16_t A_g_fen, A_g_score, A_g_done, A_g_status, A_g_go;

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

/* Run the loaded image for one eval: handshake, inject FEN, finish.
 * Fills *score_out and *status_out. Returns 0 on success; -1 on timeout/fail. */
static int run_eval(const char *fen, int *score_out, int *status_out) {
    uint16_t reset;

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

    /* (3) inject FEN, then flip g_go */
    {
        size_t i;
        for (i = 0; i < strlen(fen) && i < 99; i++)
            cpu.mem[(uint16_t)(A_g_fen + i)] = (uint8_t)fen[i];
        cpu.mem[(uint16_t)(A_g_fen + i)] = 0;
        cpu.mem[A_g_done] = 0;
        cpu.mem[A_g_go]   = 1;
    }

    /* (4) run until exit (main returned) */
    while (cpu.cycles < MAX_CYCLES_RUN) {
        cpu6502_step(&cpu);
        if (cpu.mem[SIM_EXIT_REG] != EXIT_SENTINEL) break;
    }
    if (cpu.cycles >= MAX_CYCLES_RUN) { fprintf(stderr, "timeout during eval\n"); return -1; }

    /* (5) read result */
    *status_out = cpu.mem[A_g_status];
    if (cpu.mem[A_g_done] != 1) { fprintf(stderr, "g_done not set\n"); return -1; }
    /* g_score is a signed 16-bit int, little-endian in 6502 RAM. */
    {
        uint16_t raw = cpu.mem[A_g_score] | (cpu.mem[(uint16_t)(A_g_score + 1)] << 8);
        *score_out = (int16_t)raw;
    }
    return 0;
}

int main(int argc, char **argv) {
    const char *image, *mapf;
    char line[300];

    if (argc < 3) {
        fprintf(stderr, "usage: %s eval6502.sim eval6502.map < fenlist\n", argv[0]);
        return 2;
    }
    image = argv[1]; mapf = argv[2];

    if (map_addr(mapf, "g_fen",   &A_g_fen)   ||
        map_addr(mapf, "g_score", &A_g_score) ||
        map_addr(mapf, "g_done",  &A_g_done)  ||
        map_addr(mapf, "g_status",&A_g_status)||
        map_addr(mapf, "g_go",    &A_g_go)) return 2;

    fprintf(stderr,
      "ABI: g_fen=0x%04X g_score=0x%04X g_done=0x%04X g_status=0x%04X g_go=0x%04X\n",
      A_g_fen, A_g_score, A_g_done, A_g_status, A_g_go);

    if (load_image(image) < 0) return 2;

    while (fgets(line, sizeof line, stdin)) {
        char fen[200];
        int score, st;
        char *nl, *tab;
        /* a fenlist line is a bare FEN (possibly TSV: FEN<TAB>...) */
        tab = strchr(line, '\t'); if (tab) *tab = 0;
        nl = strpbrk(line, "\r\n"); if (nl) *nl = 0;
        if (line[0] == 0 || line[0] == '#') continue;
        strncpy(fen, line, sizeof fen - 1); fen[sizeof fen - 1] = 0;

        /* reload image fresh each FEN (clears all engine state). */
        load_image(image);
        if (run_eval(fen, &score, &st) != 0) {
            printf("ERR\n");
            fflush(stdout);
            continue;
        }
        if (st != 0) printf("ERR\n");
        else         printf("%d\n", score);
        fflush(stdout);
    }
    return 0;
}
