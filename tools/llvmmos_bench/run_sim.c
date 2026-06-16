/* run_sim.c -- load an llvm-mos `mos-sim` image into the fast6502 core and run.
 *
 * The mos-sim linker (mos-platform/sim/lib/link.ld) emits a CHUNKED image:
 *   repeat: [ load_addr u16le ][ length u16le ][ length bytes ]
 * The final chunk writes the 6-byte vector area at 0xFFFA:
 *   NMI(2) RESET(2) IRQ(2)   -- RESET = address of _start (crt0).
 *
 * We load every chunk into flat 64K RAM, set PC from the reset vector
 * (mem[0xFFFC..0xFFFD]), and single-step until the program writes the sim
 * `exit` register at 0xFFF8 (mos-platform/sim/stdlib.c does this in _Exit), or
 * a cycle ceiling is hit. We report the total cycle count.
 *
 * Build (host): cc run_sim.c ../fast6502_bridge/cpu6502.c -O2 -o run_sim
 * Run:          ./run_sim image.sim
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include "../fast6502_bridge/cpu6502.h"

#define SIM_EXIT_REG    0xFFF8
#define SIM_PUTCHAR_REG 0xFFF9
#define EXIT_SENTINEL   0x5A      /* unlikely initial value; exit write changes it */
#define MAX_CYCLES      2000000000ULL

static cpu6502_t cpu;

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s image.sim\n", argv[0]); return 2; }

    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror("fopen"); return 2; }
    /* read whole file */
    fseek(f, 0, SEEK_END);
    long fsz = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *buf = malloc(fsz);
    if (fread(buf, 1, fsz, f) != (size_t)fsz) { perror("fread"); return 2; }
    fclose(f);

    cpu6502_reset(&cpu);
    memset(cpu.mem, 0, sizeof(cpu.mem));

    /* parse chunks */
    long off = 0;
    int chunks = 0;
    while (off + 4 <= fsz) {
        uint16_t addr = buf[off] | (buf[off+1] << 8);
        uint16_t len  = buf[off+2] | (buf[off+3] << 8);
        off += 4;
        if (off + len > fsz) {
            fprintf(stderr, "truncated chunk @%ld addr=%04x len=%u\n", off, addr, len);
            break;
        }
        for (uint16_t i = 0; i < len; i++)
            cpu.mem[(uint16_t)(addr + i)] = buf[off + i];
        off += len;
        chunks++;
    }
    free(buf);
    fprintf(stderr, "loaded %d chunks\n", chunks);

    /* arm the exit sentinel and set PC from the reset vector */
    cpu.mem[SIM_EXIT_REG] = EXIT_SENTINEL;
    uint16_t reset = cpu.mem[0xFFFC] | (cpu.mem[0xFFFD] << 8);
    cpu.pc = reset;
    fprintf(stderr, "reset vector -> $%04X\n", reset);

    /* run until exit register is written or cycle ceiling. Snapshot the
     * putchar register each step so we capture every byte the program emits
     * (the benchmark writes its result there to prove the loop is live). */
    unsigned long long steps = 0;
    uint8_t prev_pc_reg = cpu.mem[SIM_PUTCHAR_REG];
    int out[16]; int nout = 0;
    while (cpu.cycles < MAX_CYCLES) {
        cpu6502_step(&cpu);
        steps++;
        uint8_t pc_reg = cpu.mem[SIM_PUTCHAR_REG];
        if (pc_reg != prev_pc_reg) {
            if (nout < 16) out[nout++] = pc_reg;
            prev_pc_reg = pc_reg;
        }
        if (cpu.mem[SIM_EXIT_REG] != EXIT_SENTINEL) break;
    }

    if (cpu.cycles >= MAX_CYCLES) {
        fprintf(stderr, "TIMEOUT after %llu cycles (%llu steps) -- no exit write\n",
                cpu.cycles, steps);
        return 1;
    }

    printf("%llu\n", cpu.cycles);   /* stdout: just the cycle count */
    fprintf(stderr, "exit_status=%d  cycles=%llu  steps=%llu  putchar_bytes=[",
            (int)(int8_t)cpu.mem[SIM_EXIT_REG], cpu.cycles, steps);
    for (int k = 0; k < nout; k++) fprintf(stderr, "%s%d", k ? "," : "", out[k]);
    fprintf(stderr, "]\n");
    return 0;
}
