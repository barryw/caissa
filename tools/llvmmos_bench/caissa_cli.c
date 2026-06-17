/* caissa_cli.c -- cref-compatible CLI over the REAL llvm-mos 6502 image.
 *
 * Drives /tmp/caissa.sim (the native C engine compiled to 6502, in its
 * exact on-chip RAM config) inside the cycle-exact fast6502 core and prints a
 * move in the SAME format as `native/cref bestmove`, so existing tooling
 * (tools/native_vs_stockfish.py via NATIVE_CREF=...) measures the ACTUAL 6502
 * binary vs Stockfish -- the definitive on-chip strength, not a host proxy.
 *
 *   caissa_cli bestmove "FEN" DEPTH   -> "bestmove <uci> score 0 depth D ..."
 *
 * Image/map paths default to /tmp/caissa.{sim,map}; override with
 * ENGINE6502_SIM / ENGINE6502_MAP env vars.
 *
 * Build: cc -O2 caissa_cli.c ../fast6502_bridge/cpu6502.c -o caissa_cli
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
static uint16_t A_g_fen, A_g_depth, A_g_from, A_g_to, A_g_promo, A_g_done, A_g_status, A_g_go;

static int map_addr(const char *mapfile, const char *sym, uint16_t *out) {
    FILE *f = fopen(mapfile, "r");
    char line[512];
    size_t slen = strlen(sym);
    if (!f) { fprintf(stderr, "cannot open map %s\n", mapfile); return -1; }
    while (fgets(line, sizeof line, f)) {
        char *tok, *last = NULL, *save, buf[512];
        strncpy(buf, line, sizeof buf - 1); buf[sizeof buf - 1] = 0;
        for (tok = strtok_r(buf, " \t\r\n", &save); tok; tok = strtok_r(NULL, " \t\r\n", &save))
            last = tok;
        if (last && strlen(last) == slen && strcmp(last, sym) == 0) {
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
        for (uint16_t i = 0; i < len; i++) cpu.mem[(uint16_t)(addr + i)] = buf[off + i];
        off += len; chunks++;
    }
    free(buf);
    return chunks;
}

static void sq0x88_to_str(uint8_t sq, char *out) {
    int file = sq & 7, rank = 7 - (sq >> 4);
    out[0] = 'a' + file; out[1] = '1' + rank; out[2] = 0;
}
static const char promo_char[7] = {0,0,'n','b','r','q',0};

static int run_bestmove(const char *fen, unsigned char depth, char *uci, int *status_out) {
    uint16_t reset;
    cpu6502_reset(&cpu);
    cpu.mem[SIM_EXIT_REG] = EXIT_SENTINEL; cpu.mem[SIM_PUTCHAR_REG] = 0x00;
    reset = cpu.mem[0xFFFC] | (cpu.mem[0xFFFD] << 8); cpu.pc = reset;
    while (cpu.cycles < MAX_CYCLES_RUN) {
        cpu6502_step(&cpu);
        if (cpu.mem[SIM_PUTCHAR_REG] == SIM_READY) break;
        if (cpu.mem[SIM_EXIT_REG] != EXIT_SENTINEL) { fprintf(stderr, "exited before READY\n"); return -1; }
    }
    if (cpu.cycles >= MAX_CYCLES_RUN) { fprintf(stderr, "timeout READY\n"); return -1; }
    { size_t i; for (i = 0; i < strlen(fen) && i < 99; i++) cpu.mem[(uint16_t)(A_g_fen + i)] = (uint8_t)fen[i];
      cpu.mem[(uint16_t)(A_g_fen + i)] = 0; cpu.mem[A_g_depth] = depth; cpu.mem[A_g_done] = 0; cpu.mem[A_g_go] = 1; }
    while (cpu.cycles < MAX_CYCLES_RUN) { cpu6502_step(&cpu); if (cpu.mem[SIM_EXIT_REG] != EXIT_SENTINEL) break; }
    if (cpu.cycles >= MAX_CYCLES_RUN) { fprintf(stderr, "timeout search\n"); return -1; }
    *status_out = cpu.mem[A_g_status];
    if (cpu.mem[A_g_done] != 1) { fprintf(stderr, "g_done not set\n"); return -1; }
    if (*status_out != 0) { strcpy(uci, "0000"); return 0; }
    { uint8_t from = cpu.mem[A_g_from], to = cpu.mem[A_g_to], pr = cpu.mem[A_g_promo];
      char fs[3], ts[3]; sq0x88_to_str(from, fs); sq0x88_to_str(to, ts);
      uci[0]=fs[0]; uci[1]=fs[1]; uci[2]=ts[0]; uci[3]=ts[1];
      if (pr >= 2 && pr <= 5) { uci[4] = promo_char[pr]; uci[5] = 0; } else uci[4] = 0; }
    return 0;
}

int main(int argc, char **argv) {
    const char *sim = getenv("ENGINE6502_SIM"); const char *map = getenv("ENGINE6502_MAP");
    if (!sim) sim = "/tmp/caissa.sim";
    if (!map) map = "/tmp/caissa.map";
    if (argc < 4 || strcmp(argv[1], "bestmove") != 0) {
        fprintf(stderr, "usage: %s bestmove \"FEN\" DEPTH\n", argv[0]); return 2;
    }
    const char *fen = argv[2]; int depth = atoi(argv[3]);
    if (map_addr(map,"g_fen",&A_g_fen)||map_addr(map,"g_depth",&A_g_depth)||map_addr(map,"g_from",&A_g_from)||
        map_addr(map,"g_to",&A_g_to)||map_addr(map,"g_promo",&A_g_promo)||map_addr(map,"g_done",&A_g_done)||
        map_addr(map,"g_status",&A_g_status)||map_addr(map,"g_go",&A_g_go)) return 2;
    if (load_image(sim) < 0) return 2;
    char uci[8]; int st;
    if (run_bestmove(fen, (unsigned char)depth, uci, &st) != 0) { printf("bestmove 0000\n"); return 1; }
    printf("bestmove %s score 0 depth %d nodes 0\n", uci, depth);
    return 0;
}
