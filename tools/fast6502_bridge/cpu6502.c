/*
 * cpu6502.c - NMOS 6502 instruction interpreter (documented opcodes).
 *
 * Cycle counts follow the canonical NMOS table.  Indexed reads that cross a
 * page boundary cost +1; RMW and store forms of those modes do not (they always
 * pay the fixed cost).  Taken branches cost +1, +1 more if the branch crosses a
 * page.  This matches the .NET sim6502 the engine is validated against closely
 * enough that, with no cycle-based timeout, move/eval/zobrist output is
 * identical; exact cycle totals are not part of the correctness gate.
 */
#include "cpu6502.h"

/* ----- memory helpers (flat 64K, no banking) ----- */
static inline uint8_t  rd(cpu6502_t *c, uint16_t a)            { return c->mem[a]; }
static inline void     wr(cpu6502_t *c, uint16_t a, uint8_t v) { c->mem[a] = v; }
static inline uint8_t  fetch(cpu6502_t *c)                     { return c->mem[c->pc++]; }

static inline uint16_t rd16(cpu6502_t *c, uint16_t a) {
    return (uint16_t)c->mem[a] | ((uint16_t)c->mem[(uint16_t)(a + 1)] << 8);
}
/* Zero-page 16-bit read wraps within page 0. */
static inline uint16_t rd16_zp(cpu6502_t *c, uint8_t a) {
    return (uint16_t)c->mem[a] | ((uint16_t)c->mem[(uint8_t)(a + 1)] << 8);
}

/* ----- stack ----- */
static inline void push8(cpu6502_t *c, uint8_t v) { c->mem[0x100 + c->sp] = v; c->sp--; }
static inline uint8_t pull8(cpu6502_t *c) { c->sp++; return c->mem[0x100 + c->sp]; }
static inline void push16(cpu6502_t *c, uint16_t v) { push8(c, v >> 8); push8(c, v & 0xFF); }
static inline uint16_t pull16(cpu6502_t *c) { uint8_t lo = pull8(c); uint8_t hi = pull8(c); return lo | (hi << 8); }

/* ----- flag helpers ----- */
static inline void set_flag(cpu6502_t *c, uint8_t m, int on) {
    if (on) c->status |= m; else c->status &= (uint8_t)~m;
}
static inline void set_zn(cpu6502_t *c, uint8_t v) {
    set_flag(c, FLAG_Z, v == 0);
    set_flag(c, FLAG_N, v & 0x80);
}

/* page-cross detection for +1 cycle */
static inline int page_crossed(uint16_t base, uint16_t addr) {
    return (base & 0xFF00) != (addr & 0xFF00);
}

/* ----- addressing-mode effective-address resolvers -----
 * Each returns the effective address.  For read-form indexed modes the caller
 * passes add_cycle=1 so a page cross adds a cycle; for store/RMW forms it
 * passes add_cycle=0. */
static inline uint16_t am_zp(cpu6502_t *c)  { return fetch(c); }
static inline uint16_t am_zpx(cpu6502_t *c) { return (uint8_t)(fetch(c) + c->x); }
static inline uint16_t am_zpy(cpu6502_t *c) { return (uint8_t)(fetch(c) + c->y); }
static inline uint16_t am_abs(cpu6502_t *c) { uint16_t a = rd16(c, c->pc); c->pc += 2; return a; }
static inline uint16_t am_absx(cpu6502_t *c, int add_cycle) {
    uint16_t base = rd16(c, c->pc); c->pc += 2;
    uint16_t addr = base + c->x;
    if (add_cycle && page_crossed(base, addr)) c->cycles++;
    return addr;
}
static inline uint16_t am_absy(cpu6502_t *c, int add_cycle) {
    uint16_t base = rd16(c, c->pc); c->pc += 2;
    uint16_t addr = base + c->y;
    if (add_cycle && page_crossed(base, addr)) c->cycles++;
    return addr;
}
static inline uint16_t am_indx(cpu6502_t *c) { /* (zp,X) */
    uint8_t zp = (uint8_t)(fetch(c) + c->x);
    return rd16_zp(c, zp);
}
static inline uint16_t am_indy(cpu6502_t *c, int add_cycle) { /* (zp),Y */
    uint8_t zp = fetch(c);
    uint16_t base = rd16_zp(c, zp);
    uint16_t addr = base + c->y;
    if (add_cycle && page_crossed(base, addr)) c->cycles++;
    return addr;
}

/* ----- ALU core ops ----- */
static inline void op_adc(cpu6502_t *c, uint8_t m) {
    uint8_t carry = (c->status & FLAG_C) ? 1 : 0;
    uint8_t a = c->a;
    if (c->status & FLAG_D) {
        /* NMOS 6502 decimal ADC (Bruce Clark's algorithm). Z from the binary
         * result; N/V from the pre-correction intermediate; C from the final.
         * Caissa never sets D, so this path is exercised only by Colossus. */
        int al = (a & 0x0F) + (m & 0x0F) + carry;
        if (al >= 0x0A) al = ((al + 0x06) & 0x0F) + 0x10;
        int a_ = (a & 0xF0) + (m & 0xF0) + al;
        set_flag(c, FLAG_Z, (uint8_t)(a + m + carry) == 0);
        set_flag(c, FLAG_N, (a_ & 0x80) != 0);
        set_flag(c, FLAG_V, (((a_ ^ a) & 0x80) && !((a ^ m) & 0x80)) != 0);
        if (a_ >= 0xA0) a_ += 0x60;
        set_flag(c, FLAG_C, a_ >= 0x100);
        c->a = (uint8_t)(a_ & 0xFF);
    } else {
        uint16_t sum = (uint16_t)a + m + carry;
        uint8_t res = (uint8_t)sum;
        set_flag(c, FLAG_C, sum > 0xFF);
        set_flag(c, FLAG_V, (~(a ^ m) & (a ^ res) & 0x80) != 0);
        c->a = res;
        set_zn(c, c->a);
    }
}
static inline void op_sbc(cpu6502_t *c, uint8_t m) {
    uint8_t carry = (c->status & FLAG_C) ? 1 : 0;
    uint8_t a = c->a;
    /* Flags (N,V,Z,C) come from the BINARY subtraction in BOTH modes on NMOS;
     * decimal mode only adjusts the A register value. A - M - (1-C) = A + ~M + C. */
    uint16_t bin = (uint16_t)a + (uint8_t)~m + carry;
    uint8_t res = (uint8_t)bin;
    set_flag(c, FLAG_C, bin > 0xFF);
    set_flag(c, FLAG_V, ((a ^ m) & (a ^ res) & 0x80) != 0);
    set_zn(c, res);
    if (c->status & FLAG_D) {
        int al = (a & 0x0F) - (m & 0x0F) + carry - 1;
        if (al < 0) al = ((al - 0x06) & 0x0F) - 0x10;
        int a_ = (a & 0xF0) - (m & 0xF0) + al;
        if (a_ < 0) a_ -= 0x60;
        c->a = (uint8_t)(a_ & 0xFF);
    } else {
        c->a = res;
    }
}
static inline void op_cmp_reg(cpu6502_t *c, uint8_t reg, uint8_t m) {
    uint16_t diff = (uint16_t)reg - m;
    set_flag(c, FLAG_C, reg >= m);
    set_zn(c, (uint8_t)diff);
}
static inline void op_bit(cpu6502_t *c, uint8_t m) {
    set_flag(c, FLAG_Z, (c->a & m) == 0);
    set_flag(c, FLAG_N, m & 0x80);
    set_flag(c, FLAG_V, m & 0x40);
}
static inline uint8_t op_asl(cpu6502_t *c, uint8_t v) {
    set_flag(c, FLAG_C, v & 0x80);
    v <<= 1; set_zn(c, v); return v;
}
static inline uint8_t op_lsr(cpu6502_t *c, uint8_t v) {
    set_flag(c, FLAG_C, v & 0x01);
    v >>= 1; set_zn(c, v); return v;
}
static inline uint8_t op_rol(cpu6502_t *c, uint8_t v) {
    uint8_t cin = (c->status & FLAG_C) ? 1 : 0;
    set_flag(c, FLAG_C, v & 0x80);
    v = (uint8_t)((v << 1) | cin); set_zn(c, v); return v;
}
static inline uint8_t op_ror(cpu6502_t *c, uint8_t v) {
    uint8_t cin = (c->status & FLAG_C) ? 0x80 : 0;
    set_flag(c, FLAG_C, v & 0x01);
    v = (uint8_t)((v >> 1) | cin); set_zn(c, v); return v;
}

static inline void branch(cpu6502_t *c, int take) {
    int8_t off = (int8_t)fetch(c);
    if (take) {
        uint16_t old = c->pc;
        uint16_t nw = (uint16_t)(c->pc + off);
        c->cycles += 1;                       /* taken branch */
        if (page_crossed(old, nw)) c->cycles += 1;
        c->pc = nw;
    }
}

uint8_t cpu6502_step(cpu6502_t *c) {
    uint8_t op = fetch(c);
    uint16_t a;
    uint8_t m;

    switch (op) {
    /* ---------------- LDA ---------------- */
    case 0xA9: c->a = fetch(c);                 set_zn(c,c->a); c->cycles+=2; break; /* imm */
    case 0xA5: c->a = rd(c,am_zp(c));           set_zn(c,c->a); c->cycles+=3; break; /* zp */
    case 0xB5: c->a = rd(c,am_zpx(c));          set_zn(c,c->a); c->cycles+=4; break; /* zp,X */
    case 0xAD: c->a = rd(c,am_abs(c));          set_zn(c,c->a); c->cycles+=4; break; /* abs */
    case 0xBD: c->a = rd(c,am_absx(c,1));       set_zn(c,c->a); c->cycles+=4; break; /* abs,X */
    case 0xB9: c->a = rd(c,am_absy(c,1));       set_zn(c,c->a); c->cycles+=4; break; /* abs,Y */
    case 0xA1: c->a = rd(c,am_indx(c));         set_zn(c,c->a); c->cycles+=6; break; /* (zp,X) */
    case 0xB1: c->a = rd(c,am_indy(c,1));       set_zn(c,c->a); c->cycles+=5; break; /* (zp),Y */

    /* ---------------- LDX ---------------- */
    case 0xA2: c->x = fetch(c);                 set_zn(c,c->x); c->cycles+=2; break;
    case 0xA6: c->x = rd(c,am_zp(c));           set_zn(c,c->x); c->cycles+=3; break;
    case 0xB6: c->x = rd(c,am_zpy(c));          set_zn(c,c->x); c->cycles+=4; break;
    case 0xAE: c->x = rd(c,am_abs(c));          set_zn(c,c->x); c->cycles+=4; break;
    case 0xBE: c->x = rd(c,am_absy(c,1));       set_zn(c,c->x); c->cycles+=4; break;

    /* ---------------- LDY ---------------- */
    case 0xA0: c->y = fetch(c);                 set_zn(c,c->y); c->cycles+=2; break;
    case 0xA4: c->y = rd(c,am_zp(c));           set_zn(c,c->y); c->cycles+=3; break;
    case 0xB4: c->y = rd(c,am_zpx(c));          set_zn(c,c->y); c->cycles+=4; break;
    case 0xAC: c->y = rd(c,am_abs(c));          set_zn(c,c->y); c->cycles+=4; break;
    case 0xBC: c->y = rd(c,am_absx(c,1));       set_zn(c,c->y); c->cycles+=4; break;

    /* ---------------- STA ---------------- */
    case 0x85: wr(c,am_zp(c),c->a);             c->cycles+=3; break;
    case 0x95: wr(c,am_zpx(c),c->a);            c->cycles+=4; break;
    case 0x8D: wr(c,am_abs(c),c->a);            c->cycles+=4; break;
    case 0x9D: wr(c,am_absx(c,0),c->a);         c->cycles+=5; break;
    case 0x99: wr(c,am_absy(c,0),c->a);         c->cycles+=5; break;
    case 0x81: wr(c,am_indx(c),c->a);           c->cycles+=6; break;
    case 0x91: wr(c,am_indy(c,0),c->a);         c->cycles+=6; break;

    /* ---------------- STX ---------------- */
    case 0x86: wr(c,am_zp(c),c->x);             c->cycles+=3; break;
    case 0x96: wr(c,am_zpy(c),c->x);            c->cycles+=4; break;
    case 0x8E: wr(c,am_abs(c),c->x);            c->cycles+=4; break;

    /* ---------------- STY ---------------- */
    case 0x84: wr(c,am_zp(c),c->y);             c->cycles+=3; break;
    case 0x94: wr(c,am_zpx(c),c->y);            c->cycles+=4; break;
    case 0x8C: wr(c,am_abs(c),c->y);            c->cycles+=4; break;

    /* ---------------- transfers ---------------- */
    case 0xAA: c->x=c->a; set_zn(c,c->x); c->cycles+=2; break; /* TAX */
    case 0xA8: c->y=c->a; set_zn(c,c->y); c->cycles+=2; break; /* TAY */
    case 0x8A: c->a=c->x; set_zn(c,c->a); c->cycles+=2; break; /* TXA */
    case 0x98: c->a=c->y; set_zn(c,c->a); c->cycles+=2; break; /* TYA */
    case 0xBA: c->x=c->sp; set_zn(c,c->x); c->cycles+=2; break; /* TSX */
    case 0x9A: c->sp=c->x; c->cycles+=2; break;                 /* TXS (no flags) */

    /* ---------------- stack ---------------- */
    case 0x48: push8(c,c->a); c->cycles+=3; break;             /* PHA */
    case 0x68: c->a=pull8(c); set_zn(c,c->a); c->cycles+=4; break; /* PLA */
    case 0x08: push8(c, c->status | FLAG_B | FLAG_U); c->cycles+=3; break; /* PHP (B set) */
    case 0x28: c->status = (pull8(c) & ~FLAG_B) | FLAG_U; c->cycles+=4; break; /* PLP */

    /* ---------------- logic ---------------- */
    case 0x29: c->a &= fetch(c);          set_zn(c,c->a); c->cycles+=2; break; /* AND imm */
    case 0x25: c->a &= rd(c,am_zp(c));    set_zn(c,c->a); c->cycles+=3; break;
    case 0x35: c->a &= rd(c,am_zpx(c));   set_zn(c,c->a); c->cycles+=4; break;
    case 0x2D: c->a &= rd(c,am_abs(c));   set_zn(c,c->a); c->cycles+=4; break;
    case 0x3D: c->a &= rd(c,am_absx(c,1)); set_zn(c,c->a); c->cycles+=4; break;
    case 0x39: c->a &= rd(c,am_absy(c,1)); set_zn(c,c->a); c->cycles+=4; break;
    case 0x21: c->a &= rd(c,am_indx(c));  set_zn(c,c->a); c->cycles+=6; break;
    case 0x31: c->a &= rd(c,am_indy(c,1)); set_zn(c,c->a); c->cycles+=5; break;

    case 0x09: c->a |= fetch(c);          set_zn(c,c->a); c->cycles+=2; break; /* ORA */
    case 0x05: c->a |= rd(c,am_zp(c));    set_zn(c,c->a); c->cycles+=3; break;
    case 0x15: c->a |= rd(c,am_zpx(c));   set_zn(c,c->a); c->cycles+=4; break;
    case 0x0D: c->a |= rd(c,am_abs(c));   set_zn(c,c->a); c->cycles+=4; break;
    case 0x1D: c->a |= rd(c,am_absx(c,1)); set_zn(c,c->a); c->cycles+=4; break;
    case 0x19: c->a |= rd(c,am_absy(c,1)); set_zn(c,c->a); c->cycles+=4; break;
    case 0x01: c->a |= rd(c,am_indx(c));  set_zn(c,c->a); c->cycles+=6; break;
    case 0x11: c->a |= rd(c,am_indy(c,1)); set_zn(c,c->a); c->cycles+=5; break;

    case 0x49: c->a ^= fetch(c);          set_zn(c,c->a); c->cycles+=2; break; /* EOR */
    case 0x45: c->a ^= rd(c,am_zp(c));    set_zn(c,c->a); c->cycles+=3; break;
    case 0x55: c->a ^= rd(c,am_zpx(c));   set_zn(c,c->a); c->cycles+=4; break;
    case 0x4D: c->a ^= rd(c,am_abs(c));   set_zn(c,c->a); c->cycles+=4; break;
    case 0x5D: c->a ^= rd(c,am_absx(c,1)); set_zn(c,c->a); c->cycles+=4; break;
    case 0x59: c->a ^= rd(c,am_absy(c,1)); set_zn(c,c->a); c->cycles+=4; break;
    case 0x41: c->a ^= rd(c,am_indx(c));  set_zn(c,c->a); c->cycles+=6; break;
    case 0x51: c->a ^= rd(c,am_indy(c,1)); set_zn(c,c->a); c->cycles+=5; break;

    /* ---------------- BIT ---------------- */
    case 0x24: op_bit(c, rd(c,am_zp(c)));  c->cycles+=3; break;
    case 0x2C: op_bit(c, rd(c,am_abs(c))); c->cycles+=4; break;

    /* ---------------- ADC ---------------- */
    case 0x69: op_adc(c, fetch(c));           c->cycles+=2; break;
    case 0x65: op_adc(c, rd(c,am_zp(c)));     c->cycles+=3; break;
    case 0x75: op_adc(c, rd(c,am_zpx(c)));    c->cycles+=4; break;
    case 0x6D: op_adc(c, rd(c,am_abs(c)));    c->cycles+=4; break;
    case 0x7D: op_adc(c, rd(c,am_absx(c,1))); c->cycles+=4; break;
    case 0x79: op_adc(c, rd(c,am_absy(c,1))); c->cycles+=4; break;
    case 0x61: op_adc(c, rd(c,am_indx(c)));   c->cycles+=6; break;
    case 0x71: op_adc(c, rd(c,am_indy(c,1))); c->cycles+=5; break;

    /* ---------------- SBC ---------------- */
    case 0xE9: op_sbc(c, fetch(c));           c->cycles+=2; break;
    case 0xE5: op_sbc(c, rd(c,am_zp(c)));     c->cycles+=3; break;
    case 0xF5: op_sbc(c, rd(c,am_zpx(c)));    c->cycles+=4; break;
    case 0xED: op_sbc(c, rd(c,am_abs(c)));    c->cycles+=4; break;
    case 0xFD: op_sbc(c, rd(c,am_absx(c,1))); c->cycles+=4; break;
    case 0xF9: op_sbc(c, rd(c,am_absy(c,1))); c->cycles+=4; break;
    case 0xE1: op_sbc(c, rd(c,am_indx(c)));   c->cycles+=6; break;
    case 0xF1: op_sbc(c, rd(c,am_indy(c,1))); c->cycles+=5; break;

    /* ---------------- CMP ---------------- */
    case 0xC9: op_cmp_reg(c, c->a, fetch(c));           c->cycles+=2; break;
    case 0xC5: op_cmp_reg(c, c->a, rd(c,am_zp(c)));     c->cycles+=3; break;
    case 0xD5: op_cmp_reg(c, c->a, rd(c,am_zpx(c)));    c->cycles+=4; break;
    case 0xCD: op_cmp_reg(c, c->a, rd(c,am_abs(c)));    c->cycles+=4; break;
    case 0xDD: op_cmp_reg(c, c->a, rd(c,am_absx(c,1))); c->cycles+=4; break;
    case 0xD9: op_cmp_reg(c, c->a, rd(c,am_absy(c,1))); c->cycles+=4; break;
    case 0xC1: op_cmp_reg(c, c->a, rd(c,am_indx(c)));   c->cycles+=6; break;
    case 0xD1: op_cmp_reg(c, c->a, rd(c,am_indy(c,1))); c->cycles+=5; break;

    /* ---------------- CPX / CPY ---------------- */
    case 0xE0: op_cmp_reg(c, c->x, fetch(c));        c->cycles+=2; break;
    case 0xE4: op_cmp_reg(c, c->x, rd(c,am_zp(c)));  c->cycles+=3; break;
    case 0xEC: op_cmp_reg(c, c->x, rd(c,am_abs(c))); c->cycles+=4; break;
    case 0xC0: op_cmp_reg(c, c->y, fetch(c));        c->cycles+=2; break;
    case 0xC4: op_cmp_reg(c, c->y, rd(c,am_zp(c)));  c->cycles+=3; break;
    case 0xCC: op_cmp_reg(c, c->y, rd(c,am_abs(c))); c->cycles+=4; break;

    /* ---------------- INC / DEC (memory) ---------------- */
    case 0xE6: a=am_zp(c);    m=rd(c,a)+1; wr(c,a,m); set_zn(c,m); c->cycles+=5; break;
    case 0xF6: a=am_zpx(c);   m=rd(c,a)+1; wr(c,a,m); set_zn(c,m); c->cycles+=6; break;
    case 0xEE: a=am_abs(c);   m=rd(c,a)+1; wr(c,a,m); set_zn(c,m); c->cycles+=6; break;
    case 0xFE: a=am_absx(c,0);m=rd(c,a)+1; wr(c,a,m); set_zn(c,m); c->cycles+=7; break;
    case 0xC6: a=am_zp(c);    m=rd(c,a)-1; wr(c,a,m); set_zn(c,m); c->cycles+=5; break;
    case 0xD6: a=am_zpx(c);   m=rd(c,a)-1; wr(c,a,m); set_zn(c,m); c->cycles+=6; break;
    case 0xCE: a=am_abs(c);   m=rd(c,a)-1; wr(c,a,m); set_zn(c,m); c->cycles+=6; break;
    case 0xDE: a=am_absx(c,0);m=rd(c,a)-1; wr(c,a,m); set_zn(c,m); c->cycles+=7; break;

    /* ---------------- INX/INY/DEX/DEY ---------------- */
    case 0xE8: c->x++; set_zn(c,c->x); c->cycles+=2; break;
    case 0xC8: c->y++; set_zn(c,c->y); c->cycles+=2; break;
    case 0xCA: c->x--; set_zn(c,c->x); c->cycles+=2; break;
    case 0x88: c->y--; set_zn(c,c->y); c->cycles+=2; break;

    /* ---------------- shifts/rotates ---------------- */
    case 0x0A: c->a=op_asl(c,c->a); c->cycles+=2; break; /* ASL A */
    case 0x06: a=am_zp(c);    wr(c,a,op_asl(c,rd(c,a))); c->cycles+=5; break;
    case 0x16: a=am_zpx(c);   wr(c,a,op_asl(c,rd(c,a))); c->cycles+=6; break;
    case 0x0E: a=am_abs(c);   wr(c,a,op_asl(c,rd(c,a))); c->cycles+=6; break;
    case 0x1E: a=am_absx(c,0);wr(c,a,op_asl(c,rd(c,a))); c->cycles+=7; break;

    case 0x4A: c->a=op_lsr(c,c->a); c->cycles+=2; break; /* LSR A */
    case 0x46: a=am_zp(c);    wr(c,a,op_lsr(c,rd(c,a))); c->cycles+=5; break;
    case 0x56: a=am_zpx(c);   wr(c,a,op_lsr(c,rd(c,a))); c->cycles+=6; break;
    case 0x4E: a=am_abs(c);   wr(c,a,op_lsr(c,rd(c,a))); c->cycles+=6; break;
    case 0x5E: a=am_absx(c,0);wr(c,a,op_lsr(c,rd(c,a))); c->cycles+=7; break;

    case 0x2A: c->a=op_rol(c,c->a); c->cycles+=2; break; /* ROL A */
    case 0x26: a=am_zp(c);    wr(c,a,op_rol(c,rd(c,a))); c->cycles+=5; break;
    case 0x36: a=am_zpx(c);   wr(c,a,op_rol(c,rd(c,a))); c->cycles+=6; break;
    case 0x2E: a=am_abs(c);   wr(c,a,op_rol(c,rd(c,a))); c->cycles+=6; break;
    case 0x3E: a=am_absx(c,0);wr(c,a,op_rol(c,rd(c,a))); c->cycles+=7; break;

    case 0x6A: c->a=op_ror(c,c->a); c->cycles+=2; break; /* ROR A */
    case 0x66: a=am_zp(c);    wr(c,a,op_ror(c,rd(c,a))); c->cycles+=5; break;
    case 0x76: a=am_zpx(c);   wr(c,a,op_ror(c,rd(c,a))); c->cycles+=6; break;
    case 0x6E: a=am_abs(c);   wr(c,a,op_ror(c,rd(c,a))); c->cycles+=6; break;
    case 0x7E: a=am_absx(c,0);wr(c,a,op_ror(c,rd(c,a))); c->cycles+=7; break;

    /* ---------------- jumps / calls ---------------- */
    case 0x4C: c->pc = rd16(c, c->pc); c->cycles+=3; break; /* JMP abs */
    case 0x6C: { /* JMP (ind) with NMOS page-wrap bug */
        uint16_t ptr = rd16(c, c->pc);
        uint16_t lo = c->mem[ptr];
        uint16_t hi = c->mem[(ptr & 0xFF00) | ((ptr + 1) & 0x00FF)];
        c->pc = lo | (hi << 8);
        c->cycles += 5;
        break; }
    case 0x20: { /* JSR abs */
        uint16_t target = rd16(c, c->pc);
        c->pc += 2;
        push16(c, c->pc - 1);   /* return address - 1 */
        c->pc = target;
        c->cycles += 6;
        break; }
    case 0x60: c->pc = pull16(c) + 1; c->cycles += 6; break; /* RTS */
    case 0x40: { /* RTI */
        c->status = (pull8(c) & ~FLAG_B) | FLAG_U;
        c->pc = pull16(c);
        c->cycles += 6;
        break; }

    /* ---------------- branches ---------------- */
    case 0x90: branch(c, !(c->status & FLAG_C)); c->cycles+=2; break; /* BCC */
    case 0xB0: branch(c,  (c->status & FLAG_C)); c->cycles+=2; break; /* BCS */
    case 0xD0: branch(c, !(c->status & FLAG_Z)); c->cycles+=2; break; /* BNE */
    case 0xF0: branch(c,  (c->status & FLAG_Z)); c->cycles+=2; break; /* BEQ */
    case 0x10: branch(c, !(c->status & FLAG_N)); c->cycles+=2; break; /* BPL */
    case 0x30: branch(c,  (c->status & FLAG_N)); c->cycles+=2; break; /* BMI */
    case 0x50: branch(c, !(c->status & FLAG_V)); c->cycles+=2; break; /* BVC */
    case 0x70: branch(c,  (c->status & FLAG_V)); c->cycles+=2; break; /* BVS */

    /* ---------------- flag ops ---------------- */
    case 0x18: set_flag(c,FLAG_C,0); c->cycles+=2; break; /* CLC */
    case 0x38: set_flag(c,FLAG_C,1); c->cycles+=2; break; /* SEC */
    case 0x58: set_flag(c,FLAG_I,0); c->cycles+=2; break; /* CLI */
    case 0x78: set_flag(c,FLAG_I,1); c->cycles+=2; break; /* SEI */
    case 0xB8: set_flag(c,FLAG_V,0); c->cycles+=2; break; /* CLV */
    case 0xD8: set_flag(c,FLAG_D,0); c->cycles+=2; break; /* CLD */
    case 0xF8: set_flag(c,FLAG_D,1); c->cycles+=2; break; /* SED */

    /* ---------------- misc ---------------- */
    case 0xEA: c->cycles+=2; break; /* NOP */
    case 0x00: { /* BRK */
        /* The bridge detects BRK at PC and stops *before* executing, so this
         * body is effectively unreachable in routine execution.  Implement
         * faithfully anyway: BRK pushes PC+2 and status (B set), sets I, and
         * vectors through $FFFE. */
        c->pc++; /* BRK has a padding byte */
        push16(c, c->pc);
        push8(c, c->status | FLAG_B | FLAG_U);
        set_flag(c, FLAG_I, 1);
        c->pc = rd16(c, 0xFFFE);
        c->cycles += 7;
        break; }

    default:
        /* Undocumented/illegal opcode.  ca65 output for this engine uses only
         * documented opcodes, so reaching here means a decode bug or runaway
         * PC.  Treat as a 2-cycle NOP-equivalent so the harness can surface it
         * via the never-terminating path rather than corrupting state. */
        c->cycles += 2;
        break;
    }

    return op;
}
