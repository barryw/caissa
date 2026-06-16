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
    g_w.knight = 366;
    g_w.bishop = 302;
    g_w.rook = 466;
    g_w.queen = 874;
    g_w.king = 0;

    g_w.pawn_attack_minor = 0;
    g_w.pawn_attack_rook = 0;
    g_w.pawn_attack_queen = 0;
    g_w.queen_attack_minor = 0;
    g_w.minor_attack_rook = 70;
    g_w.minor_attack_queen = 0;
    g_w.knight_outpost = 0;

    g_w.pinned_pawn = 0;
    g_w.pinned_minor = 62;
    g_w.pinned_rook = 87;
    g_w.pinned_queen = 112;
    g_w.pinned_attacked = 100;

    g_w.doubled_pawn = 37;
    g_w.isolated_pawn = 0;
    g_w.advanced_pawn = 0;
    g_w.deep_advanced_pawn = 0;
    g_w.rook_behind_passer = 150;
    g_w.connected_passer = 0;
    g_w.protected_passer = 0;
    g_w.blockaded_passer = 150;
    g_w.bishop_pair = 50;
    g_w.rook_open_file = 0;
    g_w.rook_semi_open_file = 30;
    g_w.heavy_seventh_rank = 0;

    g_w.endgame_nonpawn_limit = 1;
    g_w.endgame_king_activity = 0;
    g_w.endgame_rook_open_file = 150;
    g_w.endgame_rook_king_cutoff = 0;

    g_w.passed_pawn_bonus[0] = 400;
    g_w.passed_pawn_bonus[1] = 300;
    g_w.passed_pawn_bonus[2] = 250;
    g_w.passed_pawn_bonus[3] = 200;
    g_w.passed_pawn_bonus[4] = 150;
    g_w.passed_pawn_bonus[5] = 100;
    g_w.passed_pawn_bonus[6] = 0;
    g_w.passed_pawn_bonus[7] = 0;

    g_w.castled = 0;
    g_w.pawn_shield = 0;
    g_w.open_file_penalty = 0;
    g_w.semi_open_file_penalty = 0;
    g_w.king_center = 0;
    g_w.king_march_base = 0;
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
    237, 121, 122, 117, 141, 98, 143, 59,
    28, 37, 30, 74, 31, 45, 34, 2,
    3, 2, -13, -15, 15, -5, -7, 27,
    -13, -4, -16, 2, -14, -6, 13, -7,
    -24, -14, -10, -48, -26, 7, 23, -19,
    -11, -8, -10, -73, -23, 20, 29, -25,
    0, 0, 0, 0, 0, 0, 0, 0,
};
static const int PST_KNIGHT[64] = {
    -294, -127, -101, -112, -190, -74, 17, -205,
    -102, -105, -117, -39, -77, -48, -86, -49,
    -144, -76, -48, -51, -35, -70, -41, -125,
    -83, -86, -77, -51, -56, -43, -71, -55,
    -106, -82, -56, -59, -92, -72, -68, -95,
    -106, -104, -83, -55, -45, -78, -73, -137,
    -98, -44, -84, -100, -70, -85, -59, -85,
    -152, -132, -102, -74, -107, -128, -121, 133,
};
static const int PST_BISHOP[64] = {
    -39, -61, -31, -8, -23, -46, -110, -52,
    -53, -29, -31, 16, -36, 25, -89, -49,
    0, -47, -29, 14, 15, -43, -56, 22,
    -39, -5, 0, 27, -2, 3, 7, 3,
    32, 4, 25, 4, 26, 13, 15, -2,
    -5, 46, -3, 32, -1, 25, 10, 1,
    -5, -15, 32, -14, 9, -8, 24, 16,
    40, 18, -39, -11, -25, -11, 42, -33,
};
static const int PST_ROOK[64] = {
    11, 7, 14, -14, 38, 39, -4, 5,
    16, 9, 43, 23, 41, 38, -4, 66,
    33, 12, 20, 52, 10, 15, 26, -22,
    9, 1, -13, 11, 5, -4, 18, 5,
    -2, -2, -9, -4, -9, -8, 1, 12,
    9, 5, -3, 1, -11, 4, 14, 28,
    -28, -25, -4, 11, -18, -2, -16, -29,
    -15, -18, -2, 10, 11, -17, -26, -41,
};
static const int PST_QUEEN[64] = {
    -132, -134, -151, -26, -18, -22, -48, 20,
    -78, -50, 1, -23, -28, 119, -46, 65,
    -81, -20, -39, -23, 27, 120, -53, 63,
    -67, -73, -28, -36, 8, -13, 18, 11,
    -72, -21, -56, -47, -24, -15, -22, 10,
    -18, -47, -35, -41, -11, -12, -37, -37,
    -82, -33, -26, -30, -34, -20, -27, 1,
    -47, -51, -45, -41, -12, -101, -24, -51,
};
static const int PST_KING_MID[64] = {
    -482, -387, -603, -625, -276, -309, -222, 281,
    -345, -286, -261, -298, -299, -358, -301, -173,
    -310, -253, -339, -278, -351, -230, -221, -275,
    -281, -294, -277, -265, -314, -305, -289, -334,
    -380, -294, -299, -316, -325, -349, -330, -338,
    -367, -337, -342, -318, -317, -340, -338, -371,
    -346, -343, -339, -343, -345, -342, -336, -339,
    -346, -310, -339, -387, -350, -358, -339, -330,
};
/* Indexed by piece type 1..6 (NULL placeholder at index 0). */
static const int *const PST_BY_TYPE[7] = {
    0, PST_PAWN, PST_KNIGHT, PST_BISHOP, PST_ROOK, PST_QUEEN, PST_KING_MID
};

/* ------------------------------------------------------------------------- */
/* Endgame piece-square tables (x10). EXACT copies of the MG tables above, so  */
/* the tapered blend (EG-minus-MG) is a no-op until these EG values diverge.   */
/* Mirrors tools/texel_eval.py PST_EG_*.                                       */
/* ------------------------------------------------------------------------- */
static const int PST_EG_PAWN[64] = {
    0, 0, 0, 0, 0, 0, 0, 0,
    237, 121, 122, 117, 141, 98, 143, 59,
    28, 37, 30, 74, 31, 45, 34, 2,
    3, 2, -13, -15, 15, -5, -7, 27,
    -13, -4, -16, 2, -14, -6, 13, -7,
    -24, -14, -10, -48, -26, 7, 23, -19,
    -11, -8, -10, -73, -23, 20, 29, -25,
    0, 0, 0, 0, 0, 0, 0, 0,
};
static const int PST_EG_KNIGHT[64] = {
    -294, -127, -101, -112, -190, -74, 17, -205,
    -102, -105, -117, -39, -77, -48, -86, -49,
    -144, -76, -48, -51, -35, -70, -41, -125,
    -83, -86, -77, -51, -56, -43, -71, -55,
    -106, -82, -56, -59, -92, -72, -68, -95,
    -106, -104, -83, -55, -45, -78, -73, -137,
    -98, -44, -84, -100, -70, -85, -59, -85,
    -152, -132, -102, -74, -107, -128, -121, 133,
};
static const int PST_EG_BISHOP[64] = {
    -39, -61, -31, -8, -23, -46, -110, -52,
    -53, -29, -31, 16, -36, 25, -89, -49,
    0, -47, -29, 14, 15, -43, -56, 22,
    -39, -5, 0, 27, -2, 3, 7, 3,
    32, 4, 25, 4, 26, 13, 15, -2,
    -5, 46, -3, 32, -1, 25, 10, 1,
    -5, -15, 32, -14, 9, -8, 24, 16,
    40, 18, -39, -11, -25, -11, 42, -33,
};
static const int PST_EG_ROOK[64] = {
    11, 7, 14, -14, 38, 39, -4, 5,
    16, 9, 43, 23, 41, 38, -4, 66,
    33, 12, 20, 52, 10, 15, 26, -22,
    9, 1, -13, 11, 5, -4, 18, 5,
    -2, -2, -9, -4, -9, -8, 1, 12,
    9, 5, -3, 1, -11, 4, 14, 28,
    -28, -25, -4, 11, -18, -2, -16, -29,
    -15, -18, -2, 10, 11, -17, -26, -41,
};
static const int PST_EG_QUEEN[64] = {
    -132, -134, -151, -26, -18, -22, -48, 20,
    -78, -50, 1, -23, -28, 119, -46, 65,
    -81, -20, -39, -23, 27, 120, -53, 63,
    -67, -73, -28, -36, 8, -13, 18, 11,
    -72, -21, -56, -47, -24, -15, -22, 10,
    -18, -47, -35, -41, -11, -12, -37, -37,
    -82, -33, -26, -30, -34, -20, -27, 1,
    -47, -51, -45, -41, -12, -101, -24, -51,
};
static const int PST_EG_KING[64] = {
    -482, -387, -603, -625, -276, -309, -222, 281,
    -345, -286, -261, -298, -299, -358, -301, -173,
    -310, -253, -339, -278, -351, -230, -221, -275,
    -281, -294, -277, -265, -314, -305, -289, -334,
    -380, -294, -299, -316, -325, -349, -330, -338,
    -367, -337, -342, -318, -317, -340, -338, -371,
    -346, -343, -339, -343, -345, -342, -336, -339,
    -346, -310, -339, -387, -350, -358, -339, -330,
};
/* Indexed by piece type 1..6 (NULL placeholder at index 0). */
static const int *const PST_EG_BY_TYPE[7] = {
    0, PST_EG_PAWN, PST_EG_KNIGHT, PST_EG_BISHOP, PST_EG_ROOK, PST_EG_QUEEN, PST_EG_KING
};

/* ------------------------------------------------------------------------- */
/* Per-eval state (mirrors texel_eval._Eval).                                */
/* ------------------------------------------------------------------------- */
typedef struct {
    const uint8_t *b;       /* 0x88 board (Board.sq[]) */
    int wk, bk;
    /* eval accumulator. 16-bit, wrapping (uint16_t). The eval only ever does
     * += / -= on this, and the result is the value mod 2^16 reinterpreted as a
     * signed 16-bit int (see end of eval_full). Modular arithmetic makes a
     * wrapping 16-bit accumulator bit-identical to a wide accumulator that is
     * masked once at the end -- and it matches the 6502's native 16-bit EvalScore
     * while replacing every 32-bit `long` add/sub with a cheap 16-bit op. */
    uint16_t score;
    int nonpawn;
    int pawns;
    int queens;
    int wbishops;
    int bbishops;
    int endgame;
    int phase;              /* tapered-eval game phase: N/B=1,R=2,Q=4, clamp 24 */
    int egdiff;             /* signed EG-minus-MG PST accumulator (tapered in) */
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
static int add8(int a, int b) { return (a + b) & 0xFF; }

/* Signed-byte add/sub: wrap into two's-complement byte. */
static int add8s(int s, int v) {
    int r = (s + v) & 0xFF;
    return r >= 128 ? r - 256 : r;
}
static int sub8s(int s, int v) {
    int r = (s - v) & 0xFF;
    return r >= 128 ? r - 256 : r;
}
static int byte_x10(int signed_byte) { return signed_byte * 10; }

/* ------------------------------------------------------------------------- */
/* low-level pawn probes                                                     */
/* ------------------------------------------------------------------------- */
static int check_white_pawn_at(const Eval *e, int idx) {
    if (idx & OFFBOARD_MASK) return 0;
    return e->b[idx] == WHITE_PAWN;
}
static int check_black_pawn_at(const Eval *e, int idx) {
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
    int i;
    for (i = 0; i < 8; i++) {
        int dest = add8(sq, KNIGHT_OFFSETS[i]);
        if (dest & OFFBOARD_MASK) continue;
        if (e->b[dest] == enemy) return 1;
    }
    return 0;
}

static int is_bishop_attacked(const Eval *e, int sq, int color) {
    int enemy = color ? BLACK_BISHOP : WHITE_BISHOP;
    int i;
    for (i = 0; i < 4; i++) {
        int off = DIAGONAL_OFFSETS[i];
        int ray = sq;
        for (;;) {
            int piece;
            ray = add8(ray, off);
            if (ray & OFFBOARD_MASK) break;
            piece = e->b[ray];
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
    int i;
    if (ptype < KNIGHT_T || ptype >= ROOK_T) return 0;
    if (color) { /* white piece: enemy black queen must be on d8 ($03) */
        if (e->b[0x03] != BLACK_QUEEN) return 0;
        enemy = BLACK_QUEEN;
    } else {     /* black piece: enemy white queen on d1 ($73) */
        if (e->b[0x73] != WHITE_QUEEN) return 0;
        enemy = WHITE_QUEEN;
    }
    for (i = 0; i < 8; i++) {
        int off = ALL_DIRECTION_OFFSETS[i];
        int ray = sq;
        for (;;) {
            int piece;
            ray = add8(ray, off);
            if (ray & OFFBOARD_MASK) break;
            piece = e->b[ray];
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
    int pen;
    if (!is_pawn_attacked(e, sq, color, ptype)) return;
    pen = e->PAWN_ATTACK_PENALTY[ptype];
    if (color) e->score -= pen; else e->score += pen;
}

static void queen_pressure(Eval *e, int sq, int color, int ptype) {
    int pen;
    if (!is_queen_attacked(e, sq, color, ptype)) return;
    pen = e->QUEEN_ATTACK_PENALTY[ptype];
    if (color) e->score -= pen; else e->score += pen;
}

static void minor_pressure(Eval *e, int sq, int color, int ptype) {
    int attacked, pen;
    if (ptype < ROOK_T || ptype >= KING_T) return; /* only rook(4), queen(5) */
    attacked = is_knight_attacked(e, sq, color);
    if (!attacked) attacked = is_bishop_attacked(e, sq, color);
    if (!attacked) return;
    pen = e->MINOR_ATTACK_PENALTY[ptype];
    if (pen == 0) return;
    if (color) e->score -= pen; else e->score += pen;
}

static void knight_outpost(Eval *e, int sq, int color, int ptype) {
    int file, row16;
    if (ptype != KNIGHT_T) return;
    file = sq & 0x07;
    if (file < 2 || file >= 6) return;
    if (is_pawn_attacked(e, sq, color, ptype)) return;
    row16 = sq & 0x70;
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
    int i;
    for (i = 0; i < 8; i++) {
        int dest = add8(sq, KNIGHT_OFFSETS[i]);
        int piece;
        if (dest & OFFBOARD_MASK) continue;
        piece = e->b[dest];
        if (piece == EMPTY) count++;
        else if ((piece & WHITE_COLOR) != color) count++;
    }
    return count;
}

static int count_sliding_mobility(const Eval *e, int sq, int color,
                                  const int *offsets, int n) {
    int count = 0;
    int i;
    for (i = 0; i < n; i++) {
        int off = offsets[i];
        int ray = sq;
        for (;;) {
            int piece;
            ray = add8(ray, off);
            if (ray & OFFBOARD_MASK) break;
            piece = e->b[ray];
            if (piece == EMPTY) { count++; continue; }
            if ((piece & WHITE_COLOR) != color) count++;
            break;
        }
    }
    return count;
}

static void mobility(Eval *e, int sq, int color, int ptype) {
    int raw;
    int half, contrib;
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
    half = raw >> 1;
    if (half == 0) return;
    contrib = half * 10;
    if (color) e->score += contrib; else e->score -= contrib;
}

static void seventh_rank(Eval *e, int sq, int color, int ptype) {
    int row16;
    if (ptype != ROOK_T && ptype != QUEEN_T) return;
    row16 = sq & 0x70;
    if (color) {
        if (row16 == 0x10) e->score += g_w.heavy_seventh_rank; /* white on rank 7 */
    } else {
        if (row16 == 0x60) e->score -= g_w.heavy_seventh_rank; /* black on rank 2 */
    }
}

static void advanced_pawn(Eval *e, int sq, int color, int ptype) {
    int row16;
    if (ptype != PAWN_T) return;
    row16 = sq & 0x70;
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
    int y;
    for (;;) {
        r--;
        if (r < 0) return 1;
        y = (r << 4) | file;
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
    int y;
    for (;;) {
        r++;
        if (r == 8) return 1;
        y = (r << 4) | file;
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
    int y;
    for (;;) {
        r++;
        if (r == 8) return 0;
        y = (r << 4) | file;
        if (b[y] == WHITE_ROOK) return 1;
    }
}
static int black_rook_behind(const Eval *e, int file, int row) {
    const uint8_t *b = e->b;
    int r = row;
    int y;
    for (;;) {
        r--;
        if (r < 0) return 0;
        y = (r << 4) | file;
        if (b[y] == BLACK_ROOK) return 1;
    }
}

static void rook_file_activity(Eval *e) {
    const uint8_t *b = e->b;
    int x;
    for (x = 0; x < BOARD_SIZE; x++, (x & 0x08) ? x += 8 : 0) {
        int p = b[x];
        int f;
        if (p == WHITE_ROOK) {
            f = x & 0x07;
            if (e->wpf[f] != 0) continue;
            if (e->bpf[f] != 0) e->score += g_w.rook_semi_open_file;
            else                e->score += g_w.rook_open_file;
        } else if (p == BLACK_ROOK) {
            f = x & 0x07;
            if (e->bpf[f] != 0) continue;
            if (e->wpf[f] != 0) e->score -= g_w.rook_semi_open_file;
            else                e->score -= g_w.rook_open_file;
        }
    }
}

static void pawn_structure(Eval *e) {
    const uint8_t *b = e->b;
    int i, x, f;
    for (i = 0; i < 8; i++) { e->wpf[i] = 0; e->bpf[i] = 0; }
    for (x = 0; x < BOARD_SIZE; x++, (x & 0x08) ? x += 8 : 0) {
        int file;
        if ((b[x] & 0x07) != PAWN_T) continue;
        file = x & 0x07;
        if (b[x] & WHITE_COLOR) e->wpf[file]++;
        else                    e->bpf[file]++;
    }

    /* doubled */
    for (f = 0; f < 8; f++) {
        if (e->wpf[f] >= 2) e->score -= g_w.doubled_pawn;
        if (e->bpf[f] >= 2) e->score += g_w.doubled_pawn;
    }

    /* isolated */
    for (f = 0; f < 8; f++) {
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
    for (x = 0; x < BOARD_SIZE; x++, (x & 0x08) ? x += 8 : 0) {
        int file, row;
        if ((b[x] & 0x07) != PAWN_T) continue;
        file = x & 0x07;
        row = x >> 4;
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
    int d;
    for (d = 0; d < 8; d++) {
        int delta = ALL_DIRECTION_OFFSETS[d];
        int ray = king_sq;
        int candidate_type = 0;
        int candidate_sq = 0;
        for (;;) {
            int piece;
            ray = add8(ray, delta);
            if (ray & OFFBOARD_MASK) break;
            piece = b[ray];
            if (piece == EMPTY) continue;
            if (candidate_type == 0) {
                /* first occupied must be friendly non-king */
                int t;
                if ((piece & WHITE_COLOR) != king_color) break;
                candidate_sq = ray;
                t = piece & 0x07;
                if (t == KING_T) break;
                candidate_type = t;
                continue;
            } else {
                /* next occupied must be enemy aligned slider */
                int t, pen;
                if ((piece & WHITE_COLOR) == king_color) break;
                t = piece & 0x07;
                if (t != QUEEN_T) {
                    if (PIN_SLIDER_TYPES[d] != t) break;
                }
                pen = e->PINNED_PIECE_PENALTY[candidate_type];
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
    int row = king_sq >> 4;
    if (file >= 2 && file < 6) acc += g_w.endgame_king_activity;
    if (row >= 2 && row < 6) acc += g_w.endgame_king_activity;
    return acc;
}

static void endgame_rook_activity(Eval *e) {
    const uint8_t *b = e->b;
    int x;
    for (x = 0; x < BOARD_SIZE; x++, (x & 0x08) ? x += 8 : 0) {
        int p = b[x];
        int f, dist;
        if (p == WHITE_ROOK) {
            f = x & 0x07;
            if (e->wpf[f] != 0) continue;
            e->score += g_w.endgame_rook_open_file;
            dist = (e->bk & 0x07) - f;
            if (dist < 0) dist = -dist;
            if (dist < 2) e->score += g_w.endgame_rook_king_cutoff;
        } else if (p == BLACK_ROOK) {
            f = x & 0x07;
            if (e->bpf[f] != 0) continue;
            e->score -= g_w.endgame_rook_open_file;
            dist = (e->wk & 0x07) - f;
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
    int d, i;
    /* slider rays (8 dirs); index gates rook-only / bishop-only dirs */
    for (d = 0; d < 8; d++) {
        int delta = ALL_DIRECTION_OFFSETS[d];
        int ray = king_sq;
        for (;;) {
            int piece, t;
            ray = add8(ray, delta);
            if (ray & OFFBOARD_MASK) break;
            piece = b[ray];
            if (piece == EMPTY) continue;
            if ((piece & WHITE_COLOR) != attacker_color) break;
            t = piece & 0x07;
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
    for (i = 0; i < 8; i++) {
        int dest = add8(king_sq, KNIGHT_OFFSETS[i]);
        int piece;
        if (dest & OFFBOARD_MASK) continue;
        piece = b[dest];
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
    int k;

    if (is_white) {
        int castled = (row == 7 && (file == 6 || file == 2));
        if (castled) {
            s = add8s(s, g_w.castled);
            if (file == 6) { /* kingside shield f2,g2,h2 = $65,$66,$67 */
                int idxs[3] = { 0x65, 0x66, 0x67 };
                for (k = 0; k < 3; k++) {
                    int idx = idxs[k];
                    if ((b[idx] & 0x07) == PAWN_T && (b[idx] & WHITE_COLOR))
                        s = add8s(s, g_w.pawn_shield);
                }
            } else {        /* queenside shield a2,b2,c2 = $60,$61,$62 */
                int idxs[3] = { 0x60, 0x61, 0x62 };
                for (k = 0; k < 3; k++) {
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
                for (k = 0; k < 3; k++) {
                    int idx = idxs[k];
                    if ((b[idx] & 0x07) == PAWN_T && !(b[idx] & WHITE_COLOR))
                        s = add8s(s, g_w.pawn_shield);
                }
            } else {        /* queenside a7,b7,c7 = $10,$11,$12 */
                int idxs[3] = { 0x10, 0x11, 0x12 };
                for (k = 0; k < 3; k++) {
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
    int bb;
    e->score += byte_x10(wb);
    bb = single_king_safety(e, e->bk);
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
    int d, i;
    for (d = 0; d < 8; d++) {
        int delta = ALL_DIRECTION_OFFSETS[d];
        int ray = king_sq;
        for (;;) {
            int piece, t;
            ray = add8(ray, delta);
            if (ray & OFFBOARD_MASK) break;
            piece = b[ray];
            if (piece == EMPTY) continue;
            if ((piece & WHITE_COLOR) != attacker_color) break;
            t = piece & 0x07;
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
    for (i = 0; i < 8; i++) {
        int dest = add8(king_sq, KNIGHT_OFFSETS[i]);
        int piece;
        if (dest & OFFBOARD_MASK) continue;
        piece = b[dest];
        if (piece == EMPTY) continue;
        if ((piece & WHITE_COLOR) != attacker_color) continue;
        if ((piece & 0x07) == KNIGHT_T) c++;
    }
    return c;
}

static void king_attack_escalation(Eval *e) {
    int cw, cb;
    if (g_w.king_attack_escalation == 0) return;
    /* white king attacked by black pieces: more attackers -> worse for white. */
    cw = count_king_zone_attackers(e, e->wk, 0);
    if (cw >= 2) e->score -= g_w.king_attack_escalation * (cw - 1) * (cw - 1);
    /* black king attacked by white pieces: better for white. */
    cb = count_king_zone_attackers(e, e->bk, WHITE_COLOR);
    if (cb >= 2) e->score += g_w.king_attack_escalation * (cb - 1) * (cb - 1);
}

/* pawn_storm: own pawns advanced toward the ENEMY king (same file or an
 * adjacent file), monotonically increasing with advancement.
 *   white pawn near black king: file diff <=1, row 1..4 (chess rank 4..7),
 *     bonus = pawn_storm * (rank-3) = pawn_storm * (4 - row)  [rank = 8 - row]
 *   black pawn near white king: file diff <=1, row 3..6 (chess rank 5..2),
 *     bonus = pawn_storm * (6 - rank) = pawn_storm * (row - 2) */
static void pawn_storm(Eval *e) {
    const uint8_t *b;
    int bk_file, wk_file, x;
    if (g_w.pawn_storm == 0) return;
    b = e->b;
    bk_file = e->bk & 0x07;
    wk_file = e->wk & 0x07;
    for (x = 0; x < BOARD_SIZE; x++, (x & 0x08) ? x += 8 : 0) {
        int piece = b[x];
        int file, row;
        if ((piece & 0x07) != PAWN_T) continue;
        file = x & 0x07;
        row = x >> 4;
        if (piece & WHITE_COLOR) {
            int df = file - bk_file;
            int rank;
            if (df < 0) df = -df;
            if (df > 1) continue;
            rank = 8 - row;          /* chess rank */
            if (rank >= 4 && rank <= 7) e->score += g_w.pawn_storm * (rank - 3);
        } else {
            int df = file - wk_file;
            int rank;
            if (df < 0) df = -df;
            if (df > 1) continue;
            rank = 8 - row;          /* chess rank */
            if (rank >= 2 && rank <= 5) e->score -= g_w.pawn_storm * (6 - rank);
        }
    }
}

/* queen_attacks_minor: for each queen, slide all 8 directions; if the first
 * piece hit is an ENEMY knight or bishop, penalize that minor's owner. */
static void queen_attacks_minor(Eval *e) {
    const uint8_t *b;
    int x;
    if (g_w.queen_attacks_minor == 0) return;
    b = e->b;
    for (x = 0; x < BOARD_SIZE; x++, (x & 0x08) ? x += 8 : 0) {
        int piece = b[x];
        int qcolor, d;
        if ((piece & 0x07) != QUEEN_T) continue;
        qcolor = piece & WHITE_COLOR;
        for (d = 0; d < 8; d++) {
            int off = ALL_DIRECTION_OFFSETS[d];
            int ray = x;
            for (;;) {
                int hit;
                ray = add8(ray, off);
                if (ray & OFFBOARD_MASK) break;
                hit = b[ray];
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
    int matv[7];
    int score = 0;
    int egdiff = 0;   /* signed EG-minus-MG accumulator, tapered in below */
    int phase = 0;    /* game phase: N/B=1, R=2, Q=4 both colors, clamp 24 */
    int x;
    matv[0] = 0;
    matv[PAWN_T]   = g_w.pawn;
    matv[KNIGHT_T] = g_w.knight;
    matv[BISHOP_T] = g_w.bishop;
    matv[ROOK_T]   = g_w.rook;
    matv[QUEEN_T]  = g_w.queen;
    matv[KING_T]   = g_w.king;
    for (x = 0; x < 128; x++) {
        uint8_t p;
        int ptype, idx;
        const int *pst, *pst_eg;
        if (x & 0x88) continue;
        p = b->sq[x];
        if (!p) continue;
        ptype = PT(p);
        /* game-phase accumulation (both colors): N/B=1, R=2, Q=4 */
        if (ptype == KNIGHT_T || ptype == BISHOP_T) phase += 1;
        else if (ptype == ROOK_T) phase += 2;
        else if (ptype == QUEEN_T) phase += 4;
        pst = PST_BY_TYPE[ptype];
        pst_eg = PST_EG_BY_TYPE[ptype];
        if (IS_WHITE(p)) {
            idx = ((x & 0x70) >> 1) | (x & 0x07);
            score += matv[ptype] + pst[idx];
            egdiff += pst_eg[idx] - pst[idx];
        } else {
            idx = (((x & 0x70) >> 1) | (x & 0x07)) ^ 0x38;
            score -= matv[ptype] + pst[idx];
            egdiff -= pst_eg[idx] - pst[idx];
        }
    }
    /* tapered PST: blend accumulated EG-minus-MG toward the endgame by phase.
     * Plain C integer division truncates toward zero (matches the oracle).
     * Guarded on egdiff!=0 so the wide multiply/divide is skipped while the EG
     * tables equal the MG tables (egdiff stays 0); stays bit-exact if they ever
     * diverge. */
    if (egdiff) {
        if (phase > 24) phase = 24;
        score += egdiff * (24 - phase) / 24;
    }
    return score;
}

/* ------------------------------------------------------------------------- */
/* Main eval entry                                                           */
/* ------------------------------------------------------------------------- */
int eval_full(const Board *board) {
    Eval e;
    const uint8_t *b;
    int i, x, s;
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
    e.phase = 0;
    e.egdiff = 0;
    for (i = 0; i < 8; i++) { e.wpf[i] = 0; e.bpf[i] = 0; }

    /* Rebuild g_w-derived per-type lookup tables (mirror apply_eval_overrides). */
    e.PIECE_VALUE_TBL[0] = 0;
    e.PIECE_VALUE_TBL[PAWN_T]   = g_w.pawn;
    e.PIECE_VALUE_TBL[KNIGHT_T] = g_w.knight;
    e.PIECE_VALUE_TBL[BISHOP_T] = g_w.bishop;
    e.PIECE_VALUE_TBL[ROOK_T]   = g_w.rook;
    e.PIECE_VALUE_TBL[QUEEN_T]  = g_w.queen;
    e.PIECE_VALUE_TBL[KING_T]   = g_w.king;

    for (i = 0; i < 7; i++) {
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

    b = e.b;

    /* ---- main board pass (0x88 walk skipping offboard) ---- */
    for (x = 0; x < BOARD_SIZE; x++, (x & 0x08) ? x += 8 : 0) {
        int piece = b[x];
        int color, ptype, val, idx;
        const int *pst, *pst_eg;
        if (piece == EMPTY) continue;
        color = piece & WHITE_COLOR;
        ptype = piece & 0x07;

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
            /* game-phase accumulation (both colors): N/B=1, R=2, Q=4 */
            if (ptype == ROOK_T) e.phase += 2;
            else if (ptype == QUEEN_T) e.phase += 4;
            else e.phase += 1;          /* knight or bishop */
        }

        /* per-piece full-eval terms (order matches eval.s). Every one of these
         * six is a guarded no-op for pawns (type 1) and kings (type 6) -- they
         * only act on knight..queen -- so the whole block is skipped for those
         * two types, eliminating six call+guard sequences per pawn/king with no
         * change to the computed value. */
        if (ptype != PAWN_T && ptype != KING_T) {
            pawn_pressure(&e, x, color, ptype);
            queen_pressure(&e, x, color, ptype);
            minor_pressure(&e, x, color, ptype);
            knight_outpost(&e, x, color, ptype);
            mobility(&e, x, color, ptype);
            seventh_rank(&e, x, color, ptype);
        }

        /* material + PST (MG added now; EG-minus-MG accumulated for the
         * phase-tapered blend applied once after the loop). */
        val = e.PIECE_VALUE_TBL[ptype];
        pst = PST_BY_TYPE[ptype];
        pst_eg = PST_EG_BY_TYPE[ptype];
        if (color) {
            e.score += val;
            idx = ((x & 0x70) >> 1) | (x & 0x07);          /* Sq88To64 */
            e.score += pst[idx];
            e.egdiff += pst_eg[idx] - pst[idx];
        } else {
            e.score -= val;
            idx = (((x & 0x70) >> 1) | (x & 0x07)) ^ 0x38; /* Sq88To64Mirror */
            e.score -= pst[idx];
            e.egdiff -= pst_eg[idx] - pst[idx];
        }
    }

    /* endgame flag (matches asm branch logic) */
    if (e.nonpawn < g_w.endgame_nonpawn_limit + 1) {
        e.endgame = 1;
    } else if (e.nonpawn == g_w.endgame_nonpawn_limit + 1 && e.queens == 0) {
        e.endgame = 1;
    }

    /* tapered PST: blend accumulated EG-minus-MG toward the endgame by phase.
     * Plain C integer division truncates toward zero (matches the oracle).
     * The blend is a no-op whenever egdiff is 0 (it is 0 for every position
     * while the EG tables equal the MG tables), so the guard skips the wide
     * multiply/divide (__mulsi3/__divhi3 on 6502) in that case while staying
     * bit-exact if the EG tables ever diverge. */
    if (e.egdiff) {
        int p = e.phase;
        if (p > 24) p = 24;
        e.score += e.egdiff * (24 - p) / 24;
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
    s = (int)(e.score & 0xFFFF);
    if (s >= 0x8000) s -= 0x10000;
    return s;
}
