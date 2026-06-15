/* eval.c -- full static eval, BIT-EXACT port of tools/texel_eval.py eval_full().
 *
 * WHITE-POV centipawns, full (non-lazy) static eval. Verified against the python
 * oracle over the 22k-position dataset (tools/native_eval_check.py).
 *
 * Ported routine-for-routine from texel_eval.py `_Eval` / `eval_full`. Every
 * term reads its tunable weight from g_w so the self-play A/B harness can
 * override behavior, mirroring python's apply_eval_overrides: the per-type
 * lookup tables (PIECE_VALUE_TBL, PAWN_ATTACK_PENALTY, QUEEN_ATTACK_PENALTY,
 * MINOR_ATTACK_PENALTY, PINNED_PIECE_PENALTY) are rebuilt from g_w at the start
 * of every eval_full() so overrides take effect.
 *
 * Load-bearing exactness details reproduced verbatim from the oracle:
 *   - _add8:  8-bit mod-256 ray-walk arithmetic (clc/adc on the square byte).
 *   - _add8s/_sub8s: SIGNED-BYTE accumulation for king safety (wraps past +-127
 *     into two's-complement) before the x10 multiply (_byte_x10).
 *   - mobility = (raw_count >> 1) * 10, contributing only if the halved value is
 *     nonzero.
 *   - king march penalty uses a literal "<< 3" shift (NOT g_w.king_march_step).
 *   - pin detection re-derives the king square as the ray origin per direction,
 *     so all pins are found (multi-pin), and pinned-attack pressure is applied.
 */
#include "eval.h"

/* ------------------------------------------------------------------------- */
/* Tunable weights (override target). Baselines set by eval_reset_weights().  */
/* ------------------------------------------------------------------------- */
EvalWeights g_w;

void eval_reset_weights(void) {
    g_w.pawn = 100;
    g_w.knight = 320;
    g_w.bishop = 330;
    g_w.rook = 500;
    g_w.queen = 900;
    g_w.king = 0;

    g_w.pawn_attack_minor = 600;
    g_w.pawn_attack_rook = 600;
    g_w.pawn_attack_queen = 850;
    g_w.queen_attack_minor = 750;
    g_w.minor_attack_rook = 280;
    g_w.minor_attack_queen = 350;
    g_w.knight_outpost = 250;

    g_w.pinned_pawn = 120;
    g_w.pinned_minor = 250;
    g_w.pinned_rook = 350;
    g_w.pinned_queen = 450;
    g_w.pinned_attacked = 200;

    g_w.doubled_pawn = 150;
    g_w.isolated_pawn = 200;
    g_w.advanced_pawn = 80;
    g_w.deep_advanced_pawn = 160;
    g_w.rook_behind_passer = 200;
    g_w.connected_passer = 120;
    g_w.protected_passer = 80;
    g_w.blockaded_passer = 100;
    g_w.bishop_pair = 200;
    g_w.rook_open_file = 250;
    g_w.rook_semi_open_file = 120;
    g_w.heavy_seventh_rank = 180;

    g_w.endgame_nonpawn_limit = 1;
    g_w.endgame_king_activity = 300;
    g_w.endgame_rook_open_file = 600;
    g_w.endgame_rook_king_cutoff = 250;

    g_w.passed_pawn_bonus[0] = 400;
    g_w.passed_pawn_bonus[1] = 300;
    g_w.passed_pawn_bonus[2] = 250;
    g_w.passed_pawn_bonus[3] = 200;
    g_w.passed_pawn_bonus[4] = 150;
    g_w.passed_pawn_bonus[5] = 100;
    g_w.passed_pawn_bonus[6] = 0;
    g_w.passed_pawn_bonus[7] = 0;

    g_w.castled = 30;
    g_w.pawn_shield = 10;
    g_w.open_file_penalty = 25;
    g_w.semi_open_file_penalty = 12;
    g_w.king_center = 30;
    g_w.king_march_base = 8;
    g_w.king_march_step = 8;
    g_w.king_zone_attack = 5;

    /* New A/B eval terms: default 0 keeps the eval bit-exact to baseline. */
    g_w.tempo = 0;
    g_w.trapped_penalty = 0;
    g_w.king_attack_escalation = 0;
    g_w.pawn_storm = 0;
    g_w.queen_attacks_minor = 0;
}

/* ------------------------------------------------------------------------- */
/* 0x88 engine constants (mirror texel_eval.py)                              */
/* ------------------------------------------------------------------------- */
#define WHITE_COLOR  0x80
#define EMPTY        0
#define OFFBOARD_MASK 0x88
#define BOARD_SIZE   0x80

#define PAWN_T   1
#define KNIGHT_T 2
#define BISHOP_T 3
#define ROOK_T   4
#define QUEEN_T  5
#define KING_T   6

#define WHITE_PAWN   (PAWN_T   | WHITE_COLOR)
#define BLACK_PAWN   (PAWN_T)
#define WHITE_KNIGHT (KNIGHT_T | WHITE_COLOR)
#define BLACK_KNIGHT (KNIGHT_T)
#define WHITE_BISHOP (BISHOP_T | WHITE_COLOR)
#define BLACK_BISHOP (BISHOP_T)
#define WHITE_QUEEN  (QUEEN_T  | WHITE_COLOR)
#define BLACK_QUEEN  (QUEEN_T)
#define WHITE_ROOK   (ROOK_T   | WHITE_COLOR)
#define BLACK_ROOK   (ROOK_T)

/* Ray/offset tables (signed deltas, applied via 8-bit mod-256 add). */
static const int KNIGHT_OFFSETS[8]      = { 0xDF, 0xE1, 0xEE, 0xF2, 0x0E, 0x12, 0x1F, 0x21 };
static const int ORTHOGONAL_OFFSETS[4]  = { 0xF0, 0x10, 0xFF, 0x01 };
static const int DIAGONAL_OFFSETS[4]    = { 0xEF, 0xF1, 0x0F, 0x11 };
static const int ALL_DIRECTION_OFFSETS[8] = { 0xEF, 0xF0, 0xF1, 0xFF, 0x01, 0x0F, 0x10, 0x11 };
/* Pin slider type per direction index (PinSliderTypes in eval.s). */
static const int PIN_SLIDER_TYPES[8] = { BISHOP_T, ROOK_T, BISHOP_T, ROOK_T,
                                         ROOK_T, BISHOP_T, ROOK_T, BISHOP_T };

/* ------------------------------------------------------------------------- */
/* Piece-square tables (x10, index 0 = a8 .. 63 = h1). Verbatim from oracle.  */
/* ------------------------------------------------------------------------- */
static const int PST_PAWN[64] = {
    0, 0, 0, 0, 0, 0, 0, 0,
    200, 200, 200, 200, 200, 200, 200, 200,
    100, 100, 200, 300, 300, 200, 100, 100,
    50, 50, 100, 250, 250, 100, 50, 50,
    0, 0, 0, 200, 200, 0, 0, 0,
    50, -50, -100, 0, 0, -100, -50, 50,
    50, 100, 100, -200, -200, 100, 100, 50,
    0, 0, 0, 0, 0, 0, 0, 0,
};
static const int PST_KNIGHT[64] = {
    -500, -400, -300, -300, -300, -300, -400, -500,
    -400, -200, 0, 50, 50, 0, -200, -400,
    -300, 50, 100, 150, 150, 100, 50, -300,
    -300, 0, 150, 200, 200, 150, 0, -300,
    -300, 50, 150, 200, 200, 150, 50, -300,
    -300, 0, 100, 150, 150, 100, 0, -300,
    -400, -200, 0, 0, -30, 0, -200, -400,
    -500, -400, -300, -300, -300, -300, -400, -500,
};
static const int PST_BISHOP[64] = {
    -200, -100, -100, -100, -100, -100, -100, -200,
    -100, 50, 0, 0, 0, 0, 50, -100,
    -100, 100, 100, 100, 100, 100, 100, -100,
    -100, 0, 100, 100, 100, 100, 0, -100,
    -100, 50, 50, 100, 100, 50, 50, -100,
    -100, 0, 50, 100, 100, 50, 0, -100,
    -100, 0, 0, 0, 0, 0, 0, -100,
    -200, -100, -100, -100, -100, -100, -100, -200,
};
static const int PST_ROOK[64] = {
    0, 0, 0, 50, 50, 0, 0, 0,
    50, 100, 100, 100, 100, 100, 100, 50,
    -50, 0, 0, 0, 0, 0, 0, -50,
    -50, 0, 0, 0, 0, 0, 0, -50,
    -50, 0, 0, 0, 0, 0, 0, -50,
    -50, 0, 0, 0, 0, 0, 0, -50,
    -50, 0, 0, 0, 0, 0, 0, -50,
    0, 0, 0, 50, 50, 0, 0, 0,
};
static const int PST_QUEEN[64] = {
    -200, -100, -100, -50, -50, -100, -100, -200,
    -100, 0, 50, 0, 0, 0, 0, -100,
    -100, 50, 50, 50, 50, 50, 0, -100,
    0, 0, 50, 50, 50, 50, 0, -50,
    -50, 0, 50, 50, 50, 50, 0, -50,
    -100, 0, 50, 50, 50, 50, 0, -100,
    -100, 0, 0, 0, 0, 0, 0, -100,
    -200, -100, -100, -50, -50, -100, -100, -200,
};
static const int PST_KING_MID[64] = {
    200, 300, 100, 0, 0, 100, 300, 200,
    200, 200, 0, 0, 0, 0, 200, 200,
    -100, -200, -200, -200, -200, -200, -200, -100,
    -200, -300, -300, -400, -400, -300, -300, -200,
    -300, -400, -400, -500, -500, -400, -400, -300,
    -300, -400, -400, -500, -500, -400, -400, -300,
    -300, -400, -400, -500, -500, -400, -400, -300,
    -300, -400, -400, -500, -500, -400, -400, -300,
};
/* Indexed by piece type 1..6 (NULL placeholder at index 0). */
static const int *const PST_BY_TYPE[7] = {
    0, PST_PAWN, PST_KNIGHT, PST_BISHOP, PST_ROOK, PST_QUEEN, PST_KING_MID
};

/* ------------------------------------------------------------------------- */
/* Per-eval state (mirrors texel_eval._Eval).                                */
/* ------------------------------------------------------------------------- */
typedef struct {
    const uint8_t *b;       /* 0x88 board (Board.sq[]) */
    int wk, bk;
    long score;             /* eval accumulator; masked to 16-bit at the end */
    int nonpawn;
    int pawns;
    int queens;
    int wbishops;
    int bbishops;
    int endgame;
    int wpf[8];             /* white pawns per file */
    int bpf[8];             /* black pawns per file */

    /* g_w-derived per-type lookup tables (rebuilt each eval_full). */
    int PIECE_VALUE_TBL[7];
    int PAWN_ATTACK_PENALTY[7];
    int QUEEN_ATTACK_PENALTY[7];
    int MINOR_ATTACK_PENALTY[7];
    int PINNED_PIECE_PENALTY[7];
} Eval;

/* 6502 8-bit add (wraps mod 256). */
static inline int add8(int a, int b) { return (a + b) & 0xFF; }

/* Signed-byte add/sub: wrap into two's-complement byte. */
static inline int add8s(int s, int v) {
    int r = (s + v) & 0xFF;
    return r >= 128 ? r - 256 : r;
}
static inline int sub8s(int s, int v) {
    int r = (s - v) & 0xFF;
    return r >= 128 ? r - 256 : r;
}
static inline int byte_x10(int signed_byte) { return signed_byte * 10; }

/* ------------------------------------------------------------------------- */
/* low-level pawn probes                                                     */
/* ------------------------------------------------------------------------- */
static inline int check_white_pawn_at(const Eval *e, int idx) {
    if (idx & OFFBOARD_MASK) return 0;
    return e->b[idx] == WHITE_PAWN;
}
static inline int check_black_pawn_at(const Eval *e, int idx) {
    if (idx & OFFBOARD_MASK) return 0;
    return e->b[idx] == BLACK_PAWN;
}

/* IsPiecePawnAttacked: only knight..queen (types 2..5). */
static int is_pawn_attacked(const Eval *e, int sq, int color, int ptype) {
    if (ptype < KNIGHT_T || ptype >= KING_T) return 0;
    if (color) { /* white piece -> black pawns attack from -15,-17 */
        if (check_black_pawn_at(e, add8(sq, -0x0F))) return 1;
        if (check_black_pawn_at(e, add8(sq, -0x11))) return 1;
        return 0;
    } else {     /* black piece -> white pawns attack from +15,+17 */
        if (check_white_pawn_at(e, add8(sq, 0x0F))) return 1;
        if (check_white_pawn_at(e, add8(sq, 0x11))) return 1;
        return 0;
    }
}

static int is_knight_attacked(const Eval *e, int sq, int color) {
    int enemy = color ? BLACK_KNIGHT : WHITE_KNIGHT;
    for (int i = 0; i < 8; i++) {
        int dest = add8(sq, KNIGHT_OFFSETS[i]);
        if (dest & OFFBOARD_MASK) continue;
        if (e->b[dest] == enemy) return 1;
    }
    return 0;
}

static int is_bishop_attacked(const Eval *e, int sq, int color) {
    int enemy = color ? BLACK_BISHOP : WHITE_BISHOP;
    for (int i = 0; i < 4; i++) {
        int off = DIAGONAL_OFFSETS[i];
        int ray = sq;
        for (;;) {
            ray = add8(ray, off);
            if (ray & OFFBOARD_MASK) break;
            int piece = e->b[ray];
            if (piece == EMPTY) continue;
            if (piece == enemy) return 1;
            break;
        }
    }
    return 0;
}

/* IsPieceQueenAttacked: only minors; enemy queen must sit on its home square. */
static int is_queen_attacked(const Eval *e, int sq, int color, int ptype) {
    int enemy;
    if (ptype < KNIGHT_T || ptype >= ROOK_T) return 0;
    if (color) { /* white piece: enemy black queen must be on d8 ($03) */
        if (e->b[0x03] != BLACK_QUEEN) return 0;
        enemy = BLACK_QUEEN;
    } else {     /* black piece: enemy white queen on d1 ($73) */
        if (e->b[0x73] != WHITE_QUEEN) return 0;
        enemy = WHITE_QUEEN;
    }
    for (int i = 0; i < 8; i++) {
        int off = ALL_DIRECTION_OFFSETS[i];
        int ray = sq;
        for (;;) {
            ray = add8(ray, off);
            if (ray & OFFBOARD_MASK) break;
            int piece = e->b[ray];
            if (piece == EMPTY) continue;
            if (piece == enemy) return 1;
            break;
        }
    }
    return 0;
}

/* ------------------------------------------------------------------------- */
/* Per-piece full-eval terms (main board pass)                               */
/* ------------------------------------------------------------------------- */
static void pawn_pressure(Eval *e, int sq, int color, int ptype) {
    if (!is_pawn_attacked(e, sq, color, ptype)) return;
    int pen = e->PAWN_ATTACK_PENALTY[ptype];
    if (color) e->score -= pen; else e->score += pen;
}

static void queen_pressure(Eval *e, int sq, int color, int ptype) {
    if (!is_queen_attacked(e, sq, color, ptype)) return;
    int pen = e->QUEEN_ATTACK_PENALTY[ptype];
    if (color) e->score -= pen; else e->score += pen;
}

static void minor_pressure(Eval *e, int sq, int color, int ptype) {
    if (ptype < ROOK_T || ptype >= KING_T) return; /* only rook(4), queen(5) */
    int attacked = is_knight_attacked(e, sq, color);
    if (!attacked) attacked = is_bishop_attacked(e, sq, color);
    if (!attacked) return;
    int pen = e->MINOR_ATTACK_PENALTY[ptype];
    if (pen == 0) return;
    if (color) e->score -= pen; else e->score += pen;
}

static void knight_outpost(Eval *e, int sq, int color, int ptype) {
    if (ptype != KNIGHT_T) return;
    int file = sq & 0x07;
    if (file < 2 || file >= 6) return;
    if (is_pawn_attacked(e, sq, color, ptype)) return;
    int row16 = sq & 0x70;
    if (color) { /* white outposts on rows 2..4 ($20.. <$50) */
        if (row16 < 0x20 || row16 >= 0x50) return;
        if (check_white_pawn_at(e, add8(sq, 0x0F)) || check_white_pawn_at(e, add8(sq, 0x11)))
            e->score += g_w.knight_outpost;
    } else {     /* black outposts on rows 3..5 ($30.. <$60) */
        if (row16 < 0x30 || row16 >= 0x60) return;
        if (check_black_pawn_at(e, add8(sq, -0x0F)) || check_black_pawn_at(e, add8(sq, -0x11)))
            e->score -= g_w.knight_outpost;
    }
}

static int count_knight_mobility(const Eval *e, int sq, int color) {
    int count = 0;
    for (int i = 0; i < 8; i++) {
        int dest = add8(sq, KNIGHT_OFFSETS[i]);
        if (dest & OFFBOARD_MASK) continue;
        int piece = e->b[dest];
        if (piece == EMPTY) count++;
        else if ((piece & WHITE_COLOR) != color) count++;
    }
    return count;
}

static int count_sliding_mobility(const Eval *e, int sq, int color,
                                  const int *offsets, int n) {
    int count = 0;
    for (int i = 0; i < n; i++) {
        int off = offsets[i];
        int ray = sq;
        for (;;) {
            ray = add8(ray, off);
            if (ray & OFFBOARD_MASK) break;
            int piece = e->b[ray];
            if (piece == EMPTY) { count++; continue; }
            if ((piece & WHITE_COLOR) != color) count++;
            break;
        }
    }
    return count;
}

static void mobility(Eval *e, int sq, int color, int ptype) {
    int raw;
    if (ptype == KNIGHT_T)      raw = count_knight_mobility(e, sq, color);
    else if (ptype == BISHOP_T) raw = count_sliding_mobility(e, sq, color, DIAGONAL_OFFSETS, 4);
    else if (ptype == ROOK_T)   raw = count_sliding_mobility(e, sq, color, ORTHOGONAL_OFFSETS, 4);
    else if (ptype == QUEEN_T)  raw = count_sliding_mobility(e, sq, color, ALL_DIRECTION_OFFSETS, 8);
    else return;
    /* New term: a piece with ZERO raw mobility is "trapped" -> penalize owner.
     * Reuses the raw count already computed; contributes 0 when the weight is 0. */
    if (raw == 0) {
        if (color) e->score -= g_w.trapped_penalty; else e->score += g_w.trapped_penalty;
    }
    /* ApplyMobilityScore: lsr (halve), then *10 (only if nonzero). */
    int half = raw >> 1;
    if (half == 0) return;
    int contrib = half * 10;
    if (color) e->score += contrib; else e->score -= contrib;
}

static void seventh_rank(Eval *e, int sq, int color, int ptype) {
    if (ptype != ROOK_T && ptype != QUEEN_T) return;
    int row16 = sq & 0x70;
    if (color) {
        if (row16 == 0x10) e->score += g_w.heavy_seventh_rank; /* white on rank 7 */
    } else {
        if (row16 == 0x60) e->score -= g_w.heavy_seventh_rank; /* black on rank 2 */
    }
}

static void advanced_pawn(Eval *e, int sq, int color, int ptype) {
    if (ptype != PAWN_T) return;
    int row16 = sq & 0x70;
    if (color) { /* white */
        if (row16 == 0x30) e->score += g_w.advanced_pawn;
        else if (row16 > 0x30) return;
        else if (row16 == 0x00) return;
        else e->score += g_w.deep_advanced_pawn;
    } else {     /* black */
        if (row16 == 0x40) e->score -= g_w.advanced_pawn;
        else if (row16 < 0x50) return;
        else if (row16 == 0x70) return;
        else e->score -= g_w.deep_advanced_pawn;
    }
}

/* ------------------------------------------------------------------------- */
/* Tail terms                                                                */
/* ------------------------------------------------------------------------- */
static void bishop_pair(Eval *e) {
    if (e->wbishops >= 2) e->score += g_w.bishop_pair;
    if (e->bbishops >= 2) e->score -= g_w.bishop_pair;
}

static int white_passed(const Eval *e, int file, int row) {
    const uint8_t *b = e->b;
    int r = row;
    for (;;) {
        r--;
        if (r < 0) return 1;
        int y = (r << 4) | file;
        if ((b[y] & 0x07) == PAWN_T && !(b[y] & WHITE_COLOR)) return 0;
        if (file != 0) {
            int yl = y - 1;
            if ((b[yl] & 0x07) == PAWN_T && !(b[yl] & WHITE_COLOR)) return 0;
        }
        if (file != 7) {
            int yr = y + 1;
            if ((b[yr] & 0x07) == PAWN_T && !(b[yr] & WHITE_COLOR)) return 0;
        }
    }
}

static int black_passed(const Eval *e, int file, int row) {
    const uint8_t *b = e->b;
    int r = row;
    for (;;) {
        r++;
        if (r == 8) return 1;
        int y = (r << 4) | file;
        if ((b[y] & 0x07) == PAWN_T && (b[y] & WHITE_COLOR)) return 0;
        if (file != 0) {
            int yl = y - 1;
            if ((b[yl] & 0x07) == PAWN_T && (b[yl] & WHITE_COLOR)) return 0;
        }
        if (file != 7) {
            int yr = y + 1;
            if ((b[yr] & 0x07) == PAWN_T && (b[yr] & WHITE_COLOR)) return 0;
        }
    }
}

static int white_connected(const Eval *e, int sq, int file) {
    const uint8_t *b = e->b;
    if (file != 0 && b[sq - 1] == WHITE_PAWN) return 1;
    if (file != 7 && b[sq + 1] == WHITE_PAWN) return 1;
    return 0;
}
static int black_connected(const Eval *e, int sq, int file) {
    const uint8_t *b = e->b;
    if (file != 0 && b[sq - 1] == BLACK_PAWN) return 1;
    if (file != 7 && b[sq + 1] == BLACK_PAWN) return 1;
    return 0;
}

static int white_protected(const Eval *e, int sq) {
    const uint8_t *b = e->b;
    int a = add8(sq, 0x0F);
    if (!(a & OFFBOARD_MASK) && b[a] == WHITE_PAWN) return 1;
    a = add8(sq, 0x11);
    if (!(a & OFFBOARD_MASK) && b[a] == WHITE_PAWN) return 1;
    return 0;
}
static int black_protected(const Eval *e, int sq) {
    const uint8_t *b = e->b;
    int a = add8(sq, -0x0F);
    if (!(a & OFFBOARD_MASK) && b[a] == BLACK_PAWN) return 1;
    a = add8(sq, -0x11);
    if (!(a & OFFBOARD_MASK) && b[a] == BLACK_PAWN) return 1;
    return 0;
}

static int white_blockaded(const Eval *e, int sq) {
    int a = add8(sq, -0x10);
    if (a & OFFBOARD_MASK) return 0;
    return e->b[a] != EMPTY;
}
static int black_blockaded(const Eval *e, int sq) {
    int a = add8(sq, 0x10);
    if (a & OFFBOARD_MASK) return 0;
    return e->b[a] != EMPTY;
}

static int white_rook_behind(const Eval *e, int file, int row) {
    const uint8_t *b = e->b;
    int r = row;
    for (;;) {
        r++;
        if (r == 8) return 0;
        int y = (r << 4) | file;
        if (b[y] == WHITE_ROOK) return 1;
    }
}
static int black_rook_behind(const Eval *e, int file, int row) {
    const uint8_t *b = e->b;
    int r = row;
    for (;;) {
        r--;
        if (r < 0) return 0;
        int y = (r << 4) | file;
        if (b[y] == BLACK_ROOK) return 1;
    }
}

static void rook_file_activity(Eval *e) {
    const uint8_t *b = e->b;
    for (int x = 0; x < BOARD_SIZE; x++, (x & 0x08) ? x += 8 : 0) {
        int p = b[x];
        if (p == WHITE_ROOK) {
            int f = x & 0x07;
            if (e->wpf[f] != 0) continue;
            if (e->bpf[f] != 0) e->score += g_w.rook_semi_open_file;
            else                e->score += g_w.rook_open_file;
        } else if (p == BLACK_ROOK) {
            int f = x & 0x07;
            if (e->bpf[f] != 0) continue;
            if (e->wpf[f] != 0) e->score -= g_w.rook_semi_open_file;
            else                e->score -= g_w.rook_open_file;
        }
    }
}

static void pawn_structure(Eval *e) {
    const uint8_t *b = e->b;
    for (int i = 0; i < 8; i++) { e->wpf[i] = 0; e->bpf[i] = 0; }
    for (int x = 0; x < BOARD_SIZE; x++, (x & 0x08) ? x += 8 : 0) {
        if ((b[x] & 0x07) != PAWN_T) continue;
        int file = x & 0x07;
        if (b[x] & WHITE_COLOR) e->wpf[file]++;
        else                    e->bpf[file]++;
    }

    /* doubled */
    for (int f = 0; f < 8; f++) {
        if (e->wpf[f] >= 2) e->score -= g_w.doubled_pawn;
        if (e->bpf[f] >= 2) e->score += g_w.doubled_pawn;
    }

    /* isolated */
    for (int f = 0; f < 8; f++) {
        if (e->wpf[f] != 0) {
            int left = (f > 0) ? e->wpf[f - 1] : 0;
            int right = (f < 7) ? e->wpf[f + 1] : 0;
            if (left == 0 && right == 0) e->score -= g_w.isolated_pawn;
        }
        if (e->bpf[f] != 0) {
            int left = (f > 0) ? e->bpf[f - 1] : 0;
            int right = (f < 7) ? e->bpf[f + 1] : 0;
            if (left == 0 && right == 0) e->score += g_w.isolated_pawn;
        }
    }

    /* passed pawns + connected/protected/blockaded/rook-behind */
    for (int x = 0; x < BOARD_SIZE; x++, (x & 0x08) ? x += 8 : 0) {
        if ((b[x] & 0x07) != PAWN_T) continue;
        int file = x & 0x07;
        int row = x >> 4;
        if (b[x] & WHITE_COLOR) {
            if (!white_passed(e, file, row)) continue;
            e->score += g_w.passed_pawn_bonus[row];
            if (white_connected(e, x, file)) e->score += g_w.connected_passer;
            if (white_protected(e, x))       e->score += g_w.protected_passer;
            if (white_blockaded(e, x))       e->score -= g_w.blockaded_passer;
            if (e->endgame && white_rook_behind(e, file, row))
                e->score += g_w.rook_behind_passer;
        } else {
            if (!black_passed(e, file, row)) continue;
            e->score -= g_w.passed_pawn_bonus[7 - row];
            if (black_connected(e, x, file)) e->score -= g_w.connected_passer;
            if (black_protected(e, x))       e->score -= g_w.protected_passer;
            if (black_blockaded(e, x))       e->score += g_w.blockaded_passer;
            if (e->endgame && black_rook_behind(e, file, row))
                e->score -= g_w.rook_behind_passer;
        }
    }

    if (!e->endgame) rook_file_activity(e);
}

/* ------------------------------------------------------------------------- */
/* king pins                                                                 */
/* ------------------------------------------------------------------------- */
static void pinned_attack_pressure(Eval *e, int pinned_color, int ptype, int sq) {
    if (is_pawn_attacked(e, sq, pinned_color, ptype) || is_knight_attacked(e, sq, pinned_color)) {
        if (pinned_color) e->score -= g_w.pinned_attacked;
        else              e->score += g_w.pinned_attacked;
    }
}

static void pins_from_king(Eval *e, int king_sq, int king_color) {
    const uint8_t *b = e->b;
    for (int d = 0; d < 8; d++) {
        int delta = ALL_DIRECTION_OFFSETS[d];
        int ray = king_sq;
        int candidate_type = 0;
        int candidate_sq = 0;
        for (;;) {
            ray = add8(ray, delta);
            if (ray & OFFBOARD_MASK) break;
            int piece = b[ray];
            if (piece == EMPTY) continue;
            if (candidate_type == 0) {
                /* first occupied must be friendly non-king */
                if ((piece & WHITE_COLOR) != king_color) break;
                candidate_sq = ray;
                int t = piece & 0x07;
                if (t == KING_T) break;
                candidate_type = t;
                continue;
            } else {
                /* next occupied must be enemy aligned slider */
                if ((piece & WHITE_COLOR) == king_color) break;
                int t = piece & 0x07;
                if (t != QUEEN_T) {
                    if (PIN_SLIDER_TYPES[d] != t) break;
                }
                int pen = e->PINNED_PIECE_PENALTY[candidate_type];
                if (pen == 0) break;
                if (king_color) e->score -= pen; /* pinned side white */
                else            e->score += pen;
                pinned_attack_pressure(e, king_color, candidate_type, candidate_sq);
                break;
            }
        }
    }
}

static void king_pins(Eval *e) {
    pins_from_king(e, e->wk, WHITE_COLOR);
    pins_from_king(e, e->bk, 0);
}

/* ------------------------------------------------------------------------- */
/* endgame                                                                   */
/* ------------------------------------------------------------------------- */
static int endgame_king_activity(int king_sq) {
    int acc = 0;
    int file = king_sq & 0x07;
    if (file >= 2 && file < 6) acc += g_w.endgame_king_activity;
    int row = king_sq >> 4;
    if (row >= 2 && row < 6) acc += g_w.endgame_king_activity;
    return acc;
}

static void endgame_rook_activity(Eval *e) {
    const uint8_t *b = e->b;
    for (int x = 0; x < BOARD_SIZE; x++, (x & 0x08) ? x += 8 : 0) {
        int p = b[x];
        if (p == WHITE_ROOK) {
            int f = x & 0x07;
            if (e->wpf[f] != 0) continue;
            e->score += g_w.endgame_rook_open_file;
            int dist = (e->bk & 0x07) - f;
            if (dist < 0) dist = -dist;
            if (dist < 2) e->score += g_w.endgame_rook_king_cutoff;
        } else if (p == BLACK_ROOK) {
            int f = x & 0x07;
            if (e->bpf[f] != 0) continue;
            e->score -= g_w.endgame_rook_open_file;
            int dist = (e->wk & 0x07) - f;
            if (dist < 0) dist = -dist;
            if (dist < 2) e->score -= g_w.endgame_rook_king_cutoff;
        }
    }
}

static void endgame(Eval *e) {
    e->score += endgame_king_activity(e->wk);
    e->score -= endgame_king_activity(e->bk);
    if (e->pawns != 0 && e->nonpawn != 0) endgame_rook_activity(e);
}

/* ------------------------------------------------------------------------- */
/* king safety (SIGNED-BYTE accumulation, then x10)                          */
/* ------------------------------------------------------------------------- */
static int penalize_white_file(const Eval *e, int s, int f) {
    if (e->wpf[f] != 0) return s;
    if (e->bpf[f] != 0) return sub8s(s, g_w.semi_open_file_penalty);
    return sub8s(s, g_w.open_file_penalty);
}
static int penalize_black_file(const Eval *e, int s, int f) {
    if (e->bpf[f] != 0) return s;
    if (e->wpf[f] != 0) return sub8s(s, g_w.semi_open_file_penalty);
    return sub8s(s, g_w.open_file_penalty);
}

static int white_file_exposure(const Eval *e, int s, int file) {
    if (e->pawns == 0) return s;
    if (file != 0) s = penalize_white_file(e, s, file - 1);
    s = penalize_white_file(e, s, file);
    if (file != 7) s = penalize_white_file(e, s, file + 1);
    return s;
}
static int black_file_exposure(const Eval *e, int s, int file) {
    if (e->pawns == 0) return s;
    if (file != 0) s = penalize_black_file(e, s, file - 1);
    s = penalize_black_file(e, s, file);
    if (file != 7) s = penalize_black_file(e, s, file + 1);
    return s;
}

static int king_zone_pressure(const Eval *e, int s, int king_sq, int attacker_color) {
    const uint8_t *b = e->b;
    /* slider rays (8 dirs); index gates rook-only / bishop-only dirs */
    for (int d = 0; d < 8; d++) {
        int delta = ALL_DIRECTION_OFFSETS[d];
        int ray = king_sq;
        for (;;) {
            ray = add8(ray, delta);
            if (ray & OFFBOARD_MASK) break;
            int piece = b[ray];
            if (piece == EMPTY) continue;
            if ((piece & WHITE_COLOR) != attacker_color) break;
            int t = piece & 0x07;
            if (t == QUEEN_T) {
                s = sub8s(s, g_w.king_zone_attack);
                break;
            }
            /* orthogonal directions: indices 1,3,4,6 */
            if (d == 1 || d == 3 || d == 4 || d == 6) {
                if (t == ROOK_T) s = sub8s(s, g_w.king_zone_attack);
                break;
            } else {
                if (t == BISHOP_T) s = sub8s(s, g_w.king_zone_attack);
                break;
            }
        }
    }
    /* knight attackers */
    for (int i = 0; i < 8; i++) {
        int dest = add8(king_sq, KNIGHT_OFFSETS[i]);
        if (dest & OFFBOARD_MASK) continue;
        int piece = b[dest];
        if (piece == EMPTY) continue;
        if ((piece & WHITE_COLOR) != attacker_color) continue;
        if ((piece & 0x07) == KNIGHT_T) s = sub8s(s, g_w.king_zone_attack);
    }
    return s;
}

static int single_king_safety(const Eval *e, int king_sq) {
    const uint8_t *b = e->b;
    int file = king_sq & 0x07;
    int row = king_sq >> 4;
    int s = 0;                          /* signed-byte accumulator */
    int is_white = (king_sq == e->wk);

    if (is_white) {
        int castled = (row == 7 && (file == 6 || file == 2));
        if (castled) {
            s = add8s(s, g_w.castled);
            if (file == 6) { /* kingside shield f2,g2,h2 = $65,$66,$67 */
                int idxs[3] = { 0x65, 0x66, 0x67 };
                for (int k = 0; k < 3; k++) {
                    int idx = idxs[k];
                    if ((b[idx] & 0x07) == PAWN_T && (b[idx] & WHITE_COLOR))
                        s = add8s(s, g_w.pawn_shield);
                }
            } else {        /* queenside shield a2,b2,c2 = $60,$61,$62 */
                int idxs[3] = { 0x60, 0x61, 0x62 };
                for (int k = 0; k < 3; k++) {
                    int idx = idxs[k];
                    if ((b[idx] & 0x07) == PAWN_T && (b[idx] & WHITE_COLOR))
                        s = add8s(s, g_w.pawn_shield);
                }
            }
        } else {
            if (file == 3 || file == 4) s = sub8s(s, g_w.king_center);
        }
        /* king march: ranks past rank 2. Row < 6 triggers (rows 0..5). */
        if (row < 6) {
            int advanced = 6 - row;
            int pen = ((advanced << 3) + g_w.king_march_base) & 0xFF;
            s = sub8s(s, pen);
        }
        s = white_file_exposure(e, s, file);
        s = king_zone_pressure(e, s, king_sq, 0); /* black attackers */
    } else {
        int castled = (row == 0 && (file == 6 || file == 2));
        if (castled) {
            s = add8s(s, g_w.castled);
            if (file == 6) { /* kingside f7,g7,h7 = $15,$16,$17 */
                int idxs[3] = { 0x15, 0x16, 0x17 };
                for (int k = 0; k < 3; k++) {
                    int idx = idxs[k];
                    if ((b[idx] & 0x07) == PAWN_T && !(b[idx] & WHITE_COLOR))
                        s = add8s(s, g_w.pawn_shield);
                }
            } else {        /* queenside a7,b7,c7 = $10,$11,$12 */
                int idxs[3] = { 0x10, 0x11, 0x12 };
                for (int k = 0; k < 3; k++) {
                    int idx = idxs[k];
                    if ((b[idx] & 0x07) == PAWN_T && !(b[idx] & WHITE_COLOR))
                        s = add8s(s, g_w.pawn_shield);
                }
            }
        } else {
            if (file == 3 || file == 4) s = sub8s(s, g_w.king_center);
        }
        /* black march: row >= 2 triggers; advanced = row - 1 */
        if (row >= 2) {
            int advanced = row - 1;
            int pen = ((advanced << 3) + g_w.king_march_base) & 0xFF;
            s = sub8s(s, pen);
        }
        s = black_file_exposure(e, s, file);
        s = king_zone_pressure(e, s, king_sq, WHITE_COLOR); /* white attackers */
    }
    return s;
}

static void king_safety(Eval *e) {
    int wb = single_king_safety(e, e->wk);
    e->score += byte_x10(wb);
    int bb = single_king_safety(e, e->bk);
    e->score -= byte_x10(bb);
}

/* ------------------------------------------------------------------------- */
/* New A/B eval terms (each contributes 0 when its weight is 0)               */
/* ------------------------------------------------------------------------- */

/* king_attack_escalation: count enemy pieces (sliders raying the king zone +
 * knights) attacking the given king, then apply a QUADRATIC escalation as a
 * DIRECT centipawn term (kept off the signed-byte king-safety accumulator to
 * avoid byte wrap). Detection mirrors king_zone_pressure: per-direction slider
 * with rook-only/bishop-only gating, queen on any direction, plus knights. */
static int count_king_zone_attackers(const Eval *e, int king_sq, int attacker_color) {
    const uint8_t *b = e->b;
    int c = 0;
    for (int d = 0; d < 8; d++) {
        int delta = ALL_DIRECTION_OFFSETS[d];
        int ray = king_sq;
        for (;;) {
            ray = add8(ray, delta);
            if (ray & OFFBOARD_MASK) break;
            int piece = b[ray];
            if (piece == EMPTY) continue;
            if ((piece & WHITE_COLOR) != attacker_color) break;
            int t = piece & 0x07;
            if (t == QUEEN_T) { c++; break; }
            /* orthogonal directions: indices 1,3,4,6 */
            if (d == 1 || d == 3 || d == 4 || d == 6) {
                if (t == ROOK_T) c++;
                break;
            } else {
                if (t == BISHOP_T) c++;
                break;
            }
        }
    }
    for (int i = 0; i < 8; i++) {
        int dest = add8(king_sq, KNIGHT_OFFSETS[i]);
        if (dest & OFFBOARD_MASK) continue;
        int piece = b[dest];
        if (piece == EMPTY) continue;
        if ((piece & WHITE_COLOR) != attacker_color) continue;
        if ((piece & 0x07) == KNIGHT_T) c++;
    }
    return c;
}

static void king_attack_escalation(Eval *e) {
    if (g_w.king_attack_escalation == 0) return;
    /* white king attacked by black pieces: more attackers -> worse for white. */
    int cw = count_king_zone_attackers(e, e->wk, 0);
    if (cw >= 2) e->score -= g_w.king_attack_escalation * (cw - 1) * (cw - 1);
    /* black king attacked by white pieces: better for white. */
    int cb = count_king_zone_attackers(e, e->bk, WHITE_COLOR);
    if (cb >= 2) e->score += g_w.king_attack_escalation * (cb - 1) * (cb - 1);
}

/* pawn_storm: own pawns advanced toward the ENEMY king (same file or an
 * adjacent file), monotonically increasing with advancement.
 *   white pawn near black king: file diff <=1, row 1..4 (chess rank 4..7),
 *     bonus = pawn_storm * (rank-3) = pawn_storm * (4 - row)  [rank = 8 - row]
 *   black pawn near white king: file diff <=1, row 3..6 (chess rank 5..2),
 *     bonus = pawn_storm * (6 - rank) = pawn_storm * (row - 2) */
static void pawn_storm(Eval *e) {
    if (g_w.pawn_storm == 0) return;
    const uint8_t *b = e->b;
    int bk_file = e->bk & 0x07;
    int wk_file = e->wk & 0x07;
    for (int x = 0; x < BOARD_SIZE; x++, (x & 0x08) ? x += 8 : 0) {
        int piece = b[x];
        if ((piece & 0x07) != PAWN_T) continue;
        int file = x & 0x07;
        int row = x >> 4;
        if (piece & WHITE_COLOR) {
            int df = file - bk_file; if (df < 0) df = -df;
            if (df > 1) continue;
            int rank = 8 - row;          /* chess rank */
            if (rank >= 4 && rank <= 7) e->score += g_w.pawn_storm * (rank - 3);
        } else {
            int df = file - wk_file; if (df < 0) df = -df;
            if (df > 1) continue;
            int rank = 8 - row;          /* chess rank */
            if (rank >= 2 && rank <= 5) e->score -= g_w.pawn_storm * (6 - rank);
        }
    }
}

/* queen_attacks_minor: for each queen, slide all 8 directions; if the first
 * piece hit is an ENEMY knight or bishop, penalize that minor's owner. */
static void queen_attacks_minor(Eval *e) {
    if (g_w.queen_attacks_minor == 0) return;
    const uint8_t *b = e->b;
    for (int x = 0; x < BOARD_SIZE; x++, (x & 0x08) ? x += 8 : 0) {
        int piece = b[x];
        if ((piece & 0x07) != QUEEN_T) continue;
        int qcolor = piece & WHITE_COLOR;
        for (int d = 0; d < 8; d++) {
            int off = ALL_DIRECTION_OFFSETS[d];
            int ray = x;
            for (;;) {
                ray = add8(ray, off);
                if (ray & OFFBOARD_MASK) break;
                int hit = b[ray];
                if (hit == EMPTY) continue;
                /* first piece hit */
                if ((hit & WHITE_COLOR) != qcolor) {
                    int t = hit & 0x07;
                    if (t == KNIGHT_T || t == BISHOP_T) {
                        /* penalize the attacked minor's owner */
                        if (hit & WHITE_COLOR) e->score -= g_w.queen_attacks_minor;
                        else                   e->score += g_w.queen_attacks_minor;
                    }
                }
                break;
            }
        }
    }
}

/* Lazy stage: material + PST only (white-POV), matching the 6502 EvaluateLazy
 * stage-one (eval.s lazy=1). The 6502 quiescence stand-pat uses THIS, paying for
 * the full positional terms only when the lazy score is within LAZY_EVAL_MARGIN
 * of the window -- so the native search must mirror it or it over-credits the
 * full-eval-only terms relative to the real engine. */
int eval_material_pst(const Board *b) {
    const int matv[7] = {0, g_w.pawn, g_w.knight, g_w.bishop, g_w.rook, g_w.queen, g_w.king};
    int score = 0;
    for (int x = 0; x < 128; x++) {
        if (x & 0x88) continue;
        uint8_t p = b->sq[x];
        if (!p) continue;
        int ptype = PT(p);
        const int *pst = PST_BY_TYPE[ptype];
        if (IS_WHITE(p)) {
            int idx = ((x & 0x70) >> 1) | (x & 0x07);
            score += matv[ptype] + pst[idx];
        } else {
            int idx = (((x & 0x70) >> 1) | (x & 0x07)) ^ 0x38;
            score -= matv[ptype] + pst[idx];
        }
    }
    return score;
}

/* ------------------------------------------------------------------------- */
/* Main eval entry                                                           */
/* ------------------------------------------------------------------------- */
int eval_full(const Board *board) {
    Eval e;
    e.b = board->sq;
    e.wk = board->wk;
    e.bk = board->bk;
    e.score = 0;
    e.nonpawn = 0;
    e.pawns = 0;
    e.queens = 0;
    e.wbishops = 0;
    e.bbishops = 0;
    e.endgame = 0;
    for (int i = 0; i < 8; i++) { e.wpf[i] = 0; e.bpf[i] = 0; }

    /* Rebuild g_w-derived per-type lookup tables (mirror apply_eval_overrides). */
    e.PIECE_VALUE_TBL[0] = 0;
    e.PIECE_VALUE_TBL[PAWN_T]   = g_w.pawn;
    e.PIECE_VALUE_TBL[KNIGHT_T] = g_w.knight;
    e.PIECE_VALUE_TBL[BISHOP_T] = g_w.bishop;
    e.PIECE_VALUE_TBL[ROOK_T]   = g_w.rook;
    e.PIECE_VALUE_TBL[QUEEN_T]  = g_w.queen;
    e.PIECE_VALUE_TBL[KING_T]   = g_w.king;

    for (int i = 0; i < 7; i++) {
        e.PAWN_ATTACK_PENALTY[i] = 0;
        e.QUEEN_ATTACK_PENALTY[i] = 0;
        e.MINOR_ATTACK_PENALTY[i] = 0;
        e.PINNED_PIECE_PENALTY[i] = 0;
    }
    /* PAWN_ATTACK_PENALTY = [0,0, minor, minor, rook, queen, 0] */
    e.PAWN_ATTACK_PENALTY[KNIGHT_T] = g_w.pawn_attack_minor;
    e.PAWN_ATTACK_PENALTY[BISHOP_T] = g_w.pawn_attack_minor;
    e.PAWN_ATTACK_PENALTY[ROOK_T]   = g_w.pawn_attack_rook;
    e.PAWN_ATTACK_PENALTY[QUEEN_T]  = g_w.pawn_attack_queen;
    /* QUEEN_ATTACK_PENALTY = [0,0, minor, minor, 0,0,0] */
    e.QUEEN_ATTACK_PENALTY[KNIGHT_T] = g_w.queen_attack_minor;
    e.QUEEN_ATTACK_PENALTY[BISHOP_T] = g_w.queen_attack_minor;
    /* MINOR_ATTACK_PENALTY = [0,0,0,0, rook, queen, 0] */
    e.MINOR_ATTACK_PENALTY[ROOK_T]  = g_w.minor_attack_rook;
    e.MINOR_ATTACK_PENALTY[QUEEN_T] = g_w.minor_attack_queen;
    /* PINNED_PIECE_PENALTY = [0, pawn, minor, minor, rook, queen, 0] */
    e.PINNED_PIECE_PENALTY[PAWN_T]   = g_w.pinned_pawn;
    e.PINNED_PIECE_PENALTY[KNIGHT_T] = g_w.pinned_minor;
    e.PINNED_PIECE_PENALTY[BISHOP_T] = g_w.pinned_minor;
    e.PINNED_PIECE_PENALTY[ROOK_T]   = g_w.pinned_rook;
    e.PINNED_PIECE_PENALTY[QUEEN_T]  = g_w.pinned_queen;

    const uint8_t *b = e.b;

    /* ---- main board pass (0x88 walk skipping offboard) ---- */
    for (int x = 0; x < BOARD_SIZE; x++, (x & 0x08) ? x += 8 : 0) {
        int piece = b[x];
        if (piece == EMPTY) continue;
        int color = piece & WHITE_COLOR;
        int ptype = piece & 0x07;

        /* phase counters + per-pawn advanced bonus */
        if (ptype == PAWN_T) {
            e.pawns++;
            advanced_pawn(&e, x, color, ptype);
        } else if (ptype != KING_T) {
            e.nonpawn++;
            if (ptype == BISHOP_T) {
                if (color) e.wbishops++; else e.bbishops++;
            }
            if (ptype == QUEEN_T) e.queens++;
        }

        /* per-piece full-eval terms (order matches eval.s) */
        pawn_pressure(&e, x, color, ptype);
        queen_pressure(&e, x, color, ptype);
        minor_pressure(&e, x, color, ptype);
        knight_outpost(&e, x, color, ptype);
        mobility(&e, x, color, ptype);
        seventh_rank(&e, x, color, ptype);

        /* material + PST */
        int val = e.PIECE_VALUE_TBL[ptype];
        const int *pst = PST_BY_TYPE[ptype];
        if (color) {
            e.score += val;
            int idx = ((x & 0x70) >> 1) | (x & 0x07);          /* Sq88To64 */
            e.score += pst[idx];
        } else {
            e.score -= val;
            int idx = (((x & 0x70) >> 1) | (x & 0x07)) ^ 0x38; /* Sq88To64Mirror */
            e.score -= pst[idx];
        }
    }

    /* endgame flag (matches asm branch logic) */
    if (e.nonpawn < g_w.endgame_nonpawn_limit + 1) {
        e.endgame = 1;
    } else if (e.nonpawn == g_w.endgame_nonpawn_limit + 1 && e.queens == 0) {
        e.endgame = 1;
    }

    /* ---- full tail ---- */
    bishop_pair(&e);
    if (e.pawns != 0) pawn_structure(&e);
    if (e.endgame) {
        endgame(&e);
    } else {
        king_pins(&e);
        king_safety(&e);
    }

    /* ---- new A/B eval terms (additive; each is 0 unless its weight is set) ---- */
    king_attack_escalation(&e);
    pawn_storm(&e);
    queen_attacks_minor(&e);
    /* tempo: side-to-move bonus on the white-POV score. */
    if (board->wtm) e.score += g_w.tempo; else e.score -= g_w.tempo;

    /* EvalScore is a 16-bit signed value; reproduce two's-complement. */
    int s = (int)(e.score & 0xFFFF);
    if (s >= 0x8000) s -= 0x10000;
    return s;
}
