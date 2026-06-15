/* board.c -- FEN, make/unmake, zobrist, uci for the native reference engine. */
#include "board.h"
#include "movegen.h"
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

/* ---- zobrist ----------------------------------------------------------- */
/* hash_t is `unsigned long`: 64-bit on the host, 32-bit on cc65. cc65 cannot
 * represent literals wider than 32 bits, so the original splitmix64 mixer (with
 * its 64-bit constants) is replaced by a 32-bit-constant murmur3-style finalizer
 * that mixes correctly at EITHER width: every shift/multiply is well-defined for
 * any unsigned type and wraps mod 2^width. On the 64-bit host the high bits are
 * still filled (the multiplies fold the shifted-in low bits upward); on cc65 the
 * key is a 32-bit value. Either way it is only a hash key for the TT/repetition
 * table -- it never affects eval, movegen, or search results. */
static hash_t Z_PIECE[64][12];
static hash_t Z_SIDE, Z_CASTLE[16], Z_EP[8];
static int z_inited = 0;

static hash_t splitmix_next(hash_t *s) {
    hash_t z;
    *s += 0x9E3779B9UL;
    z = *s;
    z = (z ^ (z >> 15)) * 0x85EBCA6BUL;
    z = (z ^ (z >> 13)) * 0xC2B2AE35UL;
    return z ^ (z >> 16);
}
static void z_init(void) {
    hash_t s = 0x9ABCDEFUL;
    int i, j;
    for (i = 0; i < 64; i++)
        for (j = 0; j < 12; j++) Z_PIECE[i][j] = splitmix_next(&s);
    Z_SIDE = splitmix_next(&s);
    for (i = 0; i < 16; i++) Z_CASTLE[i] = splitmix_next(&s);
    for (i = 0; i < 8; i++) Z_EP[i] = splitmix_next(&s);
    z_inited = 1;
}
static int pidx(uint8_t piece) {
    return (PT(piece) - 1) * 2 + (IS_WHITE(piece) ? 1 : 0);
}

hash_t board_zobrist(const Board *b) {
    hash_t h = 0;
    int i;
    if (!z_inited) z_init();
    for (i = 0; i < 128; i++) {
        uint8_t p;
        if (i & 0x88) continue;
        p = b->sq[i];
        if (p) h ^= Z_PIECE[idx64_from_0x88(i)][pidx(p)];
    }
    if (!b->wtm) h ^= Z_SIDE;
    h ^= Z_CASTLE[b->castle & 15];
    if (b->ep >= 0) h ^= Z_EP[b->ep & 7];
    return h;
}

/* ---- FEN ---------------------------------------------------------------- */
int board_from_fen(Board *b, const char *fen) {
    int rank = 7, file = 0;          /* FEN starts at rank 8 (our rank index 7) */
    const char *p = fen;

    if (!z_inited) z_init();
    memset(b, 0, sizeof(*b));
    b->ep = -1;
    b->wk = b->bk = -1;

    for (; *p && *p != ' '; p++) {
        char c = *p;
        int type = 0, white, idx;
        uint8_t piece;
        if (c == '/') { rank--; file = 0; continue; }
        if (c >= '1' && c <= '8') { file += c - '0'; continue; }
        white = (c >= 'A' && c <= 'Z');
        switch (c | 0x20) {
            case 'p': type = PT_PAWN; break;
            case 'n': type = PT_KNIGHT; break;
            case 'b': type = PT_BISHOP; break;
            case 'r': type = PT_ROOK; break;
            case 'q': type = PT_QUEEN; break;
            case 'k': type = PT_KING; break;
            default: return -1;
        }
        idx = (7 - rank) * 16 + file;
        piece = (uint8_t)(type | (white ? WHITE_FLAG : 0));
        b->sq[idx] = piece;
        if (type == PT_KING) { if (white) b->wk = idx; else b->bk = idx; }
        file++;
    }
    while (*p == ' ') p++;
    b->wtm = (*p == 'w');
    while (*p && *p != ' ') p++;
    while (*p == ' ') p++;
    /* castling */
    b->castle = 0;
    for (; *p && *p != ' '; p++) {
        switch (*p) {
            case 'K': b->castle |= CASTLE_WK; break;
            case 'Q': b->castle |= CASTLE_WQ; break;
            case 'k': b->castle |= CASTLE_BK; break;
            case 'q': b->castle |= CASTLE_BQ; break;
            default: break; /* '-' */
        }
    }
    while (*p == ' ') p++;
    /* ep */
    if (*p && *p != '-') {
        int f = p[0] - 'a';
        int r = p[1] - '1';
        b->ep = (7 - r) * 16 + f;
        p += 2;
    } else if (*p == '-') p++;
    while (*p == ' ') p++;
    /* halfmove, fullmove (optional) */
    b->halfmove = 0; b->fullmove = 1;
    if (*p) { b->halfmove = atoi(p); while (*p && *p != ' ') p++; while (*p == ' ') p++; }
    if (*p) b->fullmove = atoi(p);
    b->hash = board_zobrist(b);
    return (b->wk >= 0 && b->bk >= 0) ? 0 : -1;
}

void board_to_fen(const Board *b, char *out) {
    char *o = out;
    int rank, file;
    for (rank = 7; rank >= 0; rank--) {
        int empty = 0;
        for (file = 0; file < 8; file++) {
            int idx = (7 - rank) * 16 + file;
            uint8_t pc = b->sq[idx];
            const char *L = ".pnbrqk";
            char ch;
            if (!pc) { empty++; continue; }
            if (empty) { *o++ = '0' + empty; empty = 0; }
            ch = L[PT(pc)];
            if (IS_WHITE(pc)) ch -= 32;
            *o++ = ch;
        }
        if (empty) *o++ = '0' + empty;
        if (rank) *o++ = '/';
    }
    *o++ = ' '; *o++ = b->wtm ? 'w' : 'b'; *o++ = ' ';
    if (!b->castle) *o++ = '-';
    else {
        if (b->castle & CASTLE_WK) *o++ = 'K';
        if (b->castle & CASTLE_WQ) *o++ = 'Q';
        if (b->castle & CASTLE_BK) *o++ = 'k';
        if (b->castle & CASTLE_BQ) *o++ = 'q';
    }
    *o++ = ' ';
    if (b->ep < 0) *o++ = '-';
    else { *o++ = 'a' + (b->ep & 7); *o++ = '1' + (7 - (b->ep >> 4)); }
    sprintf(o, " %d %d", b->halfmove, b->fullmove);
}

/* ---- castle-right masking ---------------------------------------------- */
/* Clear rights when a from/to square touches a king/rook home square. */
static int castle_mask(int sq, int cur) {
    /* home squares: e1=116 a1=112 h1=119 e8=4 a8=0 h8=7 */
    switch (sq) {
        case 116: return cur & ~(CASTLE_WK | CASTLE_WQ);
        case 112: return cur & ~CASTLE_WQ;
        case 119: return cur & ~CASTLE_WK;
        case 4:   return cur & ~(CASTLE_BK | CASTLE_BQ);
        case 0:   return cur & ~CASTLE_BQ;
        case 7:   return cur & ~CASTLE_BK;
        default:  return cur;
    }
}

/* ---- make / unmake ------------------------------------------------------ */
void make_move(Board *b, Move m, Undo *u) {
    uint8_t piece = b->sq[m.from];
    int white = IS_WHITE(piece) ? 1 : 0;
    uint8_t colorflag = white ? WHITE_FLAG : 0;
    int push = white ? -16 : 16;
    hash_t h;
    uint8_t placed;

    u->castle = b->castle;
    u->ep = b->ep;
    u->halfmove = b->halfmove;
    u->wk = b->wk; u->bk = b->bk;
    u->hash = b->hash;
    u->captured = 0;
    u->cap_sq = m.to;

    h = b->hash;
    if (b->ep >= 0) h ^= Z_EP[b->ep & 7];
    h ^= Z_CASTLE[b->castle & 15];

    /* lift mover */
    h ^= Z_PIECE[idx64_from_0x88(m.from)][pidx(piece)];
    b->sq[m.from] = 0;

    /* capture */
    if (m.flags & MF_EP) {
        u->cap_sq = m.to - push;        /* captured pawn sits "behind" to */
        u->captured = b->sq[u->cap_sq];
        h ^= Z_PIECE[idx64_from_0x88(u->cap_sq)][pidx(u->captured)];
        b->sq[u->cap_sq] = 0;
    } else if (m.flags & MF_CAPTURE) {
        u->captured = b->sq[m.to];
        h ^= Z_PIECE[idx64_from_0x88(m.to)][pidx(u->captured)];
        /* (capture of a rook on its home square clears opp rights below) */
    }

    /* place mover (promotion swaps type) */
    placed = (m.flags & MF_PROMO) ? (uint8_t)(m.promo | colorflag) : piece;
    h ^= Z_PIECE[idx64_from_0x88(m.to)][pidx(placed)];
    b->sq[m.to] = placed;
    if (PT(piece) == PT_KING) { if (white) b->wk = m.to; else b->bk = m.to; }

    /* castling: relocate the rook */
    if (m.flags & MF_CASTLE_K) {
        int rf = m.to + 1, rt = m.to - 1;
        uint8_t rook = b->sq[rf];
        h ^= Z_PIECE[idx64_from_0x88(rf)][pidx(rook)];
        h ^= Z_PIECE[idx64_from_0x88(rt)][pidx(rook)];
        b->sq[rt] = rook; b->sq[rf] = 0;
    } else if (m.flags & MF_CASTLE_Q) {
        int rf = m.to - 2, rt = m.to + 1;
        uint8_t rook = b->sq[rf];
        h ^= Z_PIECE[idx64_from_0x88(rf)][pidx(rook)];
        h ^= Z_PIECE[idx64_from_0x88(rt)][pidx(rook)];
        b->sq[rt] = rook; b->sq[rf] = 0;
    }

    /* castle rights */
    b->castle = castle_mask(m.from, b->castle);
    b->castle = castle_mask(m.to, b->castle);
    h ^= Z_CASTLE[b->castle & 15];

    /* ep square */
    if (m.flags & MF_DOUBLE) {
        b->ep = m.from + push;
        h ^= Z_EP[b->ep & 7];
    } else {
        b->ep = -1;
    }

    /* halfmove clock */
    if (PT(piece) == PT_PAWN || (m.flags & (MF_CAPTURE | MF_EP)))
        b->halfmove = 0;
    else
        b->halfmove++;

    if (!white) b->fullmove++;
    b->wtm ^= 1;
    h ^= Z_SIDE;
    b->hash = h;
}

void unmake_move(Board *b, Move m, const Undo *u) {
    int white;
    uint8_t colorflag;
    uint8_t placed;

    b->wtm ^= 1;                       /* back to the mover's side */
    white = b->wtm;
    colorflag = white ? WHITE_FLAG : 0;

    placed = b->sq[m.to];
    b->sq[m.to] = 0;
    /* restore mover on from (promotion -> back to pawn) */
    b->sq[m.from] = (m.flags & MF_PROMO) ? (uint8_t)(PT_PAWN | colorflag) : placed;

    /* restore captured */
    if (u->captured) b->sq[u->cap_sq] = u->captured;

    /* un-castle rook */
    if (m.flags & MF_CASTLE_K) {
        int rf = m.to + 1, rt = m.to - 1;
        b->sq[rf] = b->sq[rt]; b->sq[rt] = 0;
    } else if (m.flags & MF_CASTLE_Q) {
        int rf = m.to - 2, rt = m.to + 1;
        b->sq[rf] = b->sq[rt]; b->sq[rt] = 0;
    }

    if (!white) b->fullmove--;
    b->castle = u->castle;
    b->ep = u->ep;
    b->halfmove = u->halfmove;
    b->wk = u->wk; b->bk = u->bk;
    b->hash = u->hash;
}

/* ---- uci ---------------------------------------------------------------- */
void move_to_uci(Move m, char *out) {
    int n = 4;
    out[0] = 'a' + (m.from & 7);
    out[1] = '1' + (7 - (m.from >> 4));
    out[2] = 'a' + (m.to & 7);
    out[3] = '1' + (7 - (m.to >> 4));
    if (m.flags & MF_PROMO) out[n++] = ".pnbrqk"[m.promo];
    out[n] = 0;
}

/* uci move list off the C stack (cc65 frame limit). Call-scoped, host-only path. */
static Move g_uci_list[MAX_MOVES];

int move_from_uci(const Board *b, const char *uci, Move *out) {
    int from, to, promo = 0;
    Move *list = g_uci_list;
    int n, i;
    if (!uci[0] || !uci[1] || !uci[2] || !uci[3]) return -1;
    from = (7 - (uci[1] - '1')) * 16 + (uci[0] - 'a');
    to   = (7 - (uci[3] - '1')) * 16 + (uci[2] - 'a');
    if (uci[4]) {
        switch (uci[4]) {
            case 'n': promo = PT_KNIGHT; break;
            case 'b': promo = PT_BISHOP; break;
            case 'r': promo = PT_ROOK; break;
            case 'q': promo = PT_QUEEN; break;
            default: return -1;
        }
    }
    n = gen_legal(b, list);
    for (i = 0; i < n; i++) {
        if (list[i].from == from && list[i].to == to) {
            if (promo && list[i].promo != promo) continue;
            if (!promo && (list[i].flags & MF_PROMO)) continue;
            *out = list[i];
            return 0;
        }
    }
    return -1;
}
