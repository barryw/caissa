/* egtb.c -- Phase-1 (3-man) endgame tablebase probe. See egtb.h.
 * The index math MUST stay byte-identical to tools/egtb_gen.py (test/egtb_parity). */
#include "egtb.h"
#include "search.h"        /* MATE_SCORE */
#include "memcfg.h"
#include "egtb_tables.h"   /* generated: EGTB_*_BASE/SIZE, egtb_kk_idx[], EGTB_MAX_DTM */

#ifndef CREF_EGTB
#define CREF_EGTB 1
#endif

#if CREF_EGTB

/* ---- canonical index (mirror of egtb_gen.py) ---- */
/* squares are 0..63, a1=0 (== idx64_from_0x88). */
static unsigned char d4(int op, unsigned char s) {
    unsigned char t = (unsigned char)(((s & 7) << 3) | (s >> 3));  /* transpose (f,r)->(r,f) */
    switch (op) {
        case 0: return s;
        case 1: return s ^ 7;
        case 2: return s ^ 56;
        case 3: return s ^ 63;
        case 4: return t;
        case 5: return t ^ 7;
        case 6: return t ^ 56;
        case 7: return t ^ 63;
    }
    return s;
}
static int in_tri(unsigned char s) { int f = s & 7, r = s >> 3; return f <= r && r <= 3; }
static int fold_op(unsigned char wk) {
    int i;
    for (i = 0; i < 8; i++) if (in_tri(d4(i, wk))) return i;
    return 0;
}
static unsigned long idx_nop(unsigned char wk, unsigned char bk, unsigned char sp, int stm) {
    int op = fold_op(wk);
    wk = d4(op, wk); bk = d4(op, bk); sp = d4(op, sp);
    {
        unsigned k = egtb_kk_idx[(unsigned)wk * 64 + bk];
        return ((unsigned long)k * 64 + sp) * 2 + stm;
    }
}
static unsigned long idx_kpk(unsigned char wk, unsigned char bk, unsigned char p, int stm) {
    if ((p & 7) >= 4) { wk ^= 7; bk ^= 7; p ^= 7; }
    {
        unsigned pidx = (unsigned)((p >> 3) - 1) * 4 + (p & 7);
        return (((unsigned long)pidx * 64 + wk) * 64 + bk) * 2 + stm;
    }
}

/* ---- table byte read (host flat / C64 REU DMA) ---- */
#if defined(CREF_TT_REU) && CREF_TT_REU
/* EGTB lives in the REU just above the TT. Read ONE byte via $DF00 DMA. The TT
 * occupies TT_SIZE*sizeof(TTEntry) bytes from REU offset 0 (see search.c). */
#ifndef CREF_EGTB_REU_BASE
#define CREF_EGTB_REU_BASE ((unsigned long)(1UL << CREF_TT_BITS) * 12UL)  /* TTEntry=12B */
#endif
#define EGTB_REU_REG ((volatile unsigned char *)0xDF00)
static unsigned char egtb_read(unsigned long off) {
    unsigned char val;
    unsigned long reu = CREF_EGTB_REU_BASE + off;
    unsigned a = (unsigned)&val;
    __asm__ volatile ("sei" ::: "memory");
    EGTB_REU_REG[0x02] = (unsigned char)a;        EGTB_REU_REG[0x03] = (unsigned char)(a >> 8);
    EGTB_REU_REG[0x04] = (unsigned char)reu;      EGTB_REU_REG[0x05] = (unsigned char)(reu >> 8);
    EGTB_REU_REG[0x06] = (unsigned char)(reu >> 16);
    EGTB_REU_REG[0x07] = 1;                        EGTB_REU_REG[0x08] = 0;   /* len = 1 */
    EGTB_REU_REG[0x0A] = 0;
    EGTB_REU_REG[0x01] = 0x91;                     /* fetch REU->C64 */
    __asm__ volatile ("cli" ::: "memory");
    return val;
}
void egtb_set_data(const unsigned char *blob) { (void)blob; }   /* REU build: tables preloaded */
#define egtb_ready() 1
#else
static const unsigned char *g_egtb = 0;            /* host flat copy of egtb_tables.bin */
void egtb_set_data(const unsigned char *blob) { g_egtb = blob; }
static unsigned char egtb_read(unsigned long off) { return g_egtb[off]; }
#define egtb_ready() (g_egtb != 0)                 /* inert until the .bin is loaded */
#endif

/* ---- probe ---- */
int egtb_probe(const Board *b, int ply, int *score) {
    int i, npieces = 0, strong_sq88 = -1;
    int combo = -1;   /* 0=KQK 1=KRK 2=KPK */
    unsigned long base = 0;
    if (!egtb_ready()) return 0;   /* tables not loaded -> inert (NOT a draw) */
    /* gate: exactly 3 men, find the non-king piece */
    for (i = 0; i < 128; i++) {
        if (i & 0x88) continue;
        {
            unsigned char p = b->sq[i];
            if (!p) continue;
            npieces++;
            if (PT(p) != PT_KING) strong_sq88 = i;
        }
        if (npieces > 3) return 0;
    }
    if (npieces != 3 || strong_sq88 < 0) return 0;
    {
        unsigned char sp = b->sq[strong_sq88];
        switch (PT(sp)) {
            case PT_QUEEN: combo = 0; base = EGTB_KQK_BASE; break;
            case PT_ROOK:  combo = 1; base = EGTB_KRK_BASE; break;
            case PT_PAWN:  combo = 2; base = EGTB_KPK_BASE; break;
            default: return 0;   /* KBK / KNK = draw, not tabled */
        }
        {
            int strong_white = IS_WHITE(sp) ? 1 : 0;
            unsigned char wk = (unsigned char)idx64_from_0x88(b->wk);
            unsigned char bk = (unsigned char)idx64_from_0x88(b->bk);
            unsigned char spc = (unsigned char)idx64_from_0x88(strong_sq88);
            int stm = (b->wtm == strong_white) ? 0 : 1;   /* 0 = strong side to move */
            unsigned char nwk, nbk, nsp;
            unsigned long idx;
            unsigned char v;
            if (strong_white) { nwk = wk; nbk = bk; nsp = spc; }
            else { nwk = bk ^ 56; nbk = wk ^ 56; nsp = spc ^ 56; }
            idx = (combo == 2) ? idx_kpk(nwk, nbk, nsp, stm)
                               : idx_nop(nwk, nbk, nsp, stm);
            v = egtb_read(base + idx);
            if (v == 0) { *score = 0; return 1; }                 /* draw */
            if (v < 128) { *score = MATE_SCORE - (ply + v); }     /* STM wins in v */
            else { int dtm = 255 - v; *score = -(MATE_SCORE - (ply + dtm)); } /* STM loses */
            return 1;
        }
    }
}

#else
int egtb_probe(const Board *b, int ply, int *score) { (void)b; (void)ply; (void)score; return 0; }
void egtb_set_data(const unsigned char *blob) { (void)blob; }
#endif
