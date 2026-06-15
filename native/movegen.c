/* movegen.c -- 0x88 legal move generation for the native reference engine.
 *
 * Clean-room port of standard 0x88 chess move-generation logic against this
 * project's OWN board representation (board.h). Pseudo-legal moves are emitted
 * with the exact flag/from/to/promo encoding that board.c's make_move expects,
 * then filtered to legal by make_move + king-safety check + unmake_move.
 *
 * Geometry recap (from board.h):
 *   index = (7 - rank)*16 + file   (a8 = 0, h1 = 119)
 *   offboard test: (idx & 0x88) != 0
 *   white pawns push toward LOWER indices (-16); black toward higher (+16).
 */
#include "board.h"
#include "movegen.h"

/* ---- attack offset tables ---------------------------------------------- */
/* Stored as signed deltas. The 0x88 hex literals from the brief are the same
 * values modulo 256; using the signed form keeps index arithmetic clean. */
static const int KNIGHT_OFF[8] = { -33, -31, -18, -14, 14, 18, 31, 33 };
/* 0xDF=-33 0xE1=-31 0xEE=-18 0xF2=-14 0x0E=14 0x12=18 0x1F=31 0x21=33       */
static const int BISHOP_OFF[4] = { -17, -15, 15, 17 };
/* 0xEF=-17 0xF1=-15 0x0F=15 0x11=17                                         */
static const int ROOK_OFF[4]   = { -16, 16, -1, 1 };
/* 0xF0=-16 0x10=16 0xFF=-1 0x01=1                                           */
static const int KING_OFF[8]   = { -17, -16, -15, -1, 1, 15, 16, 17 };

/* ---- is_square_attacked ------------------------------------------------- */
/* Is square `sq` (0x88) attacked by side `by_white` (1=white, 0=black)? */
int is_square_attacked(const Board *b, int sq, int by_white) {
    uint8_t color_match = by_white ? WHITE_FLAG : 0;
    int i;

    /* Pawn attacks. A white pawn pushes toward lower indices, so a white pawn
     * on square s attacks s-15 and s-17; hence sq is attacked by a white pawn
     * sitting on sq+15 or sq+17. Black mirrors (pawn on sq-15 / sq-17). */
    if (by_white) {
        int a = sq + 15, c = sq + 17;
        if (!OFFBOARD(a)) {
            uint8_t p = b->sq[a];
            if (p && PT(p) == PT_PAWN && IS_WHITE(p)) return 1;
        }
        if (!OFFBOARD(c)) {
            uint8_t p = b->sq[c];
            if (p && PT(p) == PT_PAWN && IS_WHITE(p)) return 1;
        }
    } else {
        int a = sq - 15, c = sq - 17;
        if (!OFFBOARD(a)) {
            uint8_t p = b->sq[a];
            if (p && PT(p) == PT_PAWN && !IS_WHITE(p)) return 1;
        }
        if (!OFFBOARD(c)) {
            uint8_t p = b->sq[c];
            if (p && PT(p) == PT_PAWN && !IS_WHITE(p)) return 1;
        }
    }

    /* Knight attacks. */
    for (i = 0; i < 8; i++) {
        int t = sq + KNIGHT_OFF[i];
        uint8_t p;
        if (OFFBOARD(t)) continue;
        p = b->sq[t];
        if (p && PT(p) == PT_KNIGHT && (IS_WHITE(p) ? WHITE_FLAG : 0) == color_match)
            return 1;
    }

    /* King attacks (adjacency). */
    for (i = 0; i < 8; i++) {
        int t = sq + KING_OFF[i];
        uint8_t p;
        if (OFFBOARD(t)) continue;
        p = b->sq[t];
        if (p && PT(p) == PT_KING && (IS_WHITE(p) ? WHITE_FLAG : 0) == color_match)
            return 1;
    }

    /* Sliding diagonal attacks: bishop or queen. */
    for (i = 0; i < 4; i++) {
        int off = BISHOP_OFF[i];
        int t = sq + off;
        while (!OFFBOARD(t)) {
            uint8_t p = b->sq[t];
            if (p) {
                if ((PT(p) == PT_BISHOP || PT(p) == PT_QUEEN) &&
                    (IS_WHITE(p) ? WHITE_FLAG : 0) == color_match)
                    return 1;
                break;  /* blocked by any piece */
            }
            t += off;
        }
    }

    /* Sliding orthogonal attacks: rook or queen. */
    for (i = 0; i < 4; i++) {
        int off = ROOK_OFF[i];
        int t = sq + off;
        while (!OFFBOARD(t)) {
            uint8_t p = b->sq[t];
            if (p) {
                if ((PT(p) == PT_ROOK || PT(p) == PT_QUEEN) &&
                    (IS_WHITE(p) ? WHITE_FLAG : 0) == color_match)
                    return 1;
                break;
            }
            t += off;
        }
    }

    return 0;
}

/* ---- in_check ----------------------------------------------------------- */
int in_check(const Board *b) {
    /* Side to move's king is attacked by the opponent. */
    int ksq = b->wtm ? b->wk : b->bk;
    return is_square_attacked(b, ksq, b->wtm ? 0 : 1);
}

/* ---- pseudo-legal generation helpers ------------------------------------ */
static void add_move(Move *list, int *n, int from, int to,
                     int promo, int flags) {
    Move *m = &list[*n];
    m->from = (uint8_t)from;
    m->to = (uint8_t)to;
    m->promo = (uint8_t)promo;
    m->flags = (uint8_t)flags;
    (*n)++;
}

/* Emit promotion captures/quiets as four moves (N,B,R,Q). */
static void add_promotions(Move *list, int *n, int from, int to, int base_flags) {
    add_move(list, n, from, to, PT_KNIGHT, base_flags | MF_PROMO);
    add_move(list, n, from, to, PT_BISHOP, base_flags | MF_PROMO);
    add_move(list, n, from, to, PT_ROOK,   base_flags | MF_PROMO);
    add_move(list, n, from, to, PT_QUEEN,  base_flags | MF_PROMO);
}

static int gen_pseudo(const Board *b, Move *list) {
    int n = 0;
    int white = b->wtm;
    uint8_t my_color = white ? WHITE_FLAG : 0;
    int push = white ? -16 : 16;
    /* Pawn rank geometry: promotion lands on rank-8 row for the mover. White
     * promotes onto indices 0..15 (rank 8), black onto 112..127 (rank 1).
     * Double-push start rank: white indices 96..111 (rank 2), black 16..31. */
    int promo_row_hi = white ? 0x00 : 0x70;   /* high nibble of promo target */
    int start_row_hi = white ? 0x60 : 0x10;   /* high nibble of pawn start   */
    int sq, i;
    int opp_white;

    for (sq = 0; sq < 128; sq++) {
        uint8_t pc;
        int type;
        if (sq & 0x88) continue;
        pc = b->sq[sq];
        if (!pc) continue;
        if ((IS_WHITE(pc) ? WHITE_FLAG : 0) != my_color) continue;
        type = PT(pc);

        switch (type) {
        case PT_PAWN: {
            int one = sq + push;
            int caps[2];
            int ci;
            /* single push */
            if (!OFFBOARD(one) && b->sq[one] == 0) {
                if ((one & 0xF0) == promo_row_hi) {
                    add_promotions(list, &n, sq, one, 0);
                } else {
                    add_move(list, &n, sq, one, 0, 0);
                    /* double push from start rank */
                    if ((sq & 0xF0) == start_row_hi) {
                        int two = one + push;
                        if (!OFFBOARD(two) && b->sq[two] == 0)
                            add_move(list, &n, sq, two, 0, MF_DOUBLE);
                    }
                }
            }
            /* captures (incl. promotion captures + en passant) */
            caps[0] = sq + push - 1;
            caps[1] = sq + push + 1;
            for (ci = 0; ci < 2; ci++) {
                int t = caps[ci];
                uint8_t target;
                if (OFFBOARD(t)) continue;
                target = b->sq[t];
                if (target && (IS_WHITE(target) ? WHITE_FLAG : 0) != my_color) {
                    if ((t & 0xF0) == promo_row_hi)
                        add_promotions(list, &n, sq, t, MF_CAPTURE);
                    else
                        add_move(list, &n, sq, t, 0, MF_CAPTURE);
                } else if (target == 0 && b->ep >= 0 && t == b->ep) {
                    /* en passant: target square empty, equals ep square */
                    add_move(list, &n, sq, t, 0, MF_EP | MF_CAPTURE);
                }
            }
            break;
        }
        case PT_KNIGHT:
            for (i = 0; i < 8; i++) {
                int t = sq + KNIGHT_OFF[i];
                uint8_t target;
                if (OFFBOARD(t)) continue;
                target = b->sq[t];
                if (target == 0)
                    add_move(list, &n, sq, t, 0, 0);
                else if ((IS_WHITE(target) ? WHITE_FLAG : 0) != my_color)
                    add_move(list, &n, sq, t, 0, MF_CAPTURE);
            }
            break;
        case PT_KING:
            for (i = 0; i < 8; i++) {
                int t = sq + KING_OFF[i];
                uint8_t target;
                if (OFFBOARD(t)) continue;
                target = b->sq[t];
                if (target == 0)
                    add_move(list, &n, sq, t, 0, 0);
                else if ((IS_WHITE(target) ? WHITE_FLAG : 0) != my_color)
                    add_move(list, &n, sq, t, 0, MF_CAPTURE);
            }
            break;
        case PT_BISHOP:
        case PT_ROOK:
        case PT_QUEEN: {
            const int *off;
            int noff;
            if (type == PT_BISHOP) { off = BISHOP_OFF; noff = 4; }
            else if (type == PT_ROOK) { off = ROOK_OFF; noff = 4; }
            else { off = KING_OFF; noff = 8; }  /* queen = all 8 ray directions */
            for (i = 0; i < noff; i++) {
                int t = sq + off[i];
                while (!OFFBOARD(t)) {
                    uint8_t target = b->sq[t];
                    if (target == 0) {
                        add_move(list, &n, sq, t, 0, 0);
                    } else {
                        if ((IS_WHITE(target) ? WHITE_FLAG : 0) != my_color)
                            add_move(list, &n, sq, t, 0, MF_CAPTURE);
                        break;
                    }
                    t += off[i];
                }
            }
            break;
        }
        default:
            break;
        }
    }

    /* ---- castling ------------------------------------------------------- */
    /* King home/targets: white e1=116 -> g1=118 (K), c1=114 (Q);
     *                     black e8=4   -> g8=6   (K), c8=2   (Q).
     * make_move relocates the rook with: K rook from to+1 to to-1,
     * Q rook from to-2 to to+1, which matches the standard squares below. */
    opp_white = white ? 0 : 1;
    if (white) {
        if ((b->castle & CASTLE_WK) &&
            b->sq[117] == 0 && b->sq[118] == 0 &&             /* f1,g1 empty */
            !is_square_attacked(b, 116, opp_white) &&         /* e1 not in chk */
            !is_square_attacked(b, 117, opp_white) &&         /* f1 safe       */
            !is_square_attacked(b, 118, opp_white))           /* g1 safe       */
            add_move(list, &n, 116, 118, 0, MF_CASTLE_K);
        if ((b->castle & CASTLE_WQ) &&
            b->sq[115] == 0 && b->sq[114] == 0 && b->sq[113] == 0 && /* d1,c1,b1 */
            !is_square_attacked(b, 116, opp_white) &&         /* e1 not in chk */
            !is_square_attacked(b, 115, opp_white) &&         /* d1 safe       */
            !is_square_attacked(b, 114, opp_white))           /* c1 safe       */
            add_move(list, &n, 116, 114, 0, MF_CASTLE_Q);
    } else {
        if ((b->castle & CASTLE_BK) &&
            b->sq[5] == 0 && b->sq[6] == 0 &&                 /* f8,g8 empty */
            !is_square_attacked(b, 4, opp_white) &&           /* e8 not in chk */
            !is_square_attacked(b, 5, opp_white) &&            /* f8 safe       */
            !is_square_attacked(b, 6, opp_white))              /* g8 safe       */
            add_move(list, &n, 4, 6, 0, MF_CASTLE_K);
        if ((b->castle & CASTLE_BQ) &&
            b->sq[3] == 0 && b->sq[2] == 0 && b->sq[1] == 0 &&/* d8,c8,b8 */
            !is_square_attacked(b, 4, opp_white) &&           /* e8 not in chk */
            !is_square_attacked(b, 3, opp_white) &&            /* d8 safe       */
            !is_square_attacked(b, 2, opp_white))              /* c8 safe       */
            add_move(list, &n, 4, 2, 0, MF_CASTLE_Q);
    }

    return n;
}

/* ---- gen_legal ---------------------------------------------------------- */
/* pseudo[] off the C stack (cc65 frame limit). Call-scoped: gen_legal never
 * recurses into itself, so a single file-scope buffer is safe. */
static Move g_pseudo[MAX_MOVES];

int gen_legal(const Board *b, Move *list) {
    Move *pseudo = g_pseudo;
    int np = gen_pseudo(b, pseudo);
    int n = 0;
    Board tmp;       /* make/unmake mutates; work on a local copy */
    int i;
    tmp = *b;        /* struct assignment (cc65 rejects struct copy-INIT) */

    for (i = 0; i < np; i++) {
        Move m;
        int mover_white = tmp.wtm;
        Undo u;
        int ksq;
        m = pseudo[i];
        make_move(&tmp, m, &u);
        /* After make_move, the side to move flipped; the mover's king must not
         * be attacked by the now-side-to-move (the opponent). */
        ksq = mover_white ? tmp.wk : tmp.bk;
        if (!is_square_attacked(&tmp, ksq, mover_white ? 0 : 1))
            list[n++] = m;
        unmake_move(&tmp, m, &u);
    }
    return n;
}

/* perft lives in the host-only test_perft.c (verification, not the engine): it
 * needs a per-depth stack of move lists, which we keep off the cc65 engine. */
