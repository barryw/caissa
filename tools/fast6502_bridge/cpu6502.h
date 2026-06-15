/*
 * cpu6502.h - Fast functional NMOS 6502/6510 core (clean-room).
 *
 * Single-step interpreter over a flat 64K memory array.  Implements the full
 * set of *documented* NMOS opcodes that ca65 emits, with standard cycle counts
 * (including the +1 page-cross penalties on indexed reads and the +1/+2 on
 * taken branches).  ADC/SBC are implemented in binary; decimal mode is honoured
 * for flag-correctness only if the D flag is ever set (the chess engine never
 * uses it), so this stays a drop-in for the .NET sim6502 which the engine is
 * validated against.
 *
 * The only state the bridge needs is exposed directly: registers, flags, the
 * memory array, and a 64-bit cycle counter.  step() executes exactly one
 * instruction and returns the opcode that was executed so the caller can do
 * JSR/RTS nesting and BRK detection identically to sim6502's IsJsr/IsRts/IsBrk
 * (which inspect the opcode at PC *before* the step).
 */
#ifndef CPU6502_H
#define CPU6502_H

#include <stdint.h>

typedef struct {
    uint16_t pc;
    uint8_t  a, x, y, sp;
    uint8_t  status;     /* NV-BDIZC */
    uint8_t  mem[65536];
    uint64_t cycles;     /* running total, like sim6502's CycleCount */
} cpu6502_t;

/* Status flag bit masks. */
enum {
    FLAG_C = 0x01,
    FLAG_Z = 0x02,
    FLAG_I = 0x04,
    FLAG_D = 0x08,
    FLAG_B = 0x10,
    FLAG_U = 0x20,   /* unused, always reads 1 */
    FLAG_V = 0x40,
    FLAG_N = 0x80
};

/* Peek the opcode at PC without advancing or counting cycles. */
static inline uint8_t cpu6502_peek_opcode(const cpu6502_t *c) {
    return c->mem[c->pc];
}

/* Reset registers the way the bridge's RestoreBaseline does it:
 *   A=X=Y=0, flags cleared, I set, SP=0xFD, cycle counter=0.
 * PC is set by the caller before running a routine, so it is left untouched
 * here except to be deterministic (0). */
static inline void cpu6502_reset(cpu6502_t *c) {
    c->a = c->x = c->y = 0;
    c->sp = 0xFD;
    c->status = FLAG_I | FLAG_U;   /* I set, unused bit set; all others clear */
    c->pc = 0;
    c->cycles = 0;
}

/* Execute exactly one instruction.  Returns the opcode just executed. */
uint8_t cpu6502_step(cpu6502_t *c);

#endif /* CPU6502_H */
