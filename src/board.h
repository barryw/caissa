/* board.h -- 0x88 board core for the native reference engine.
 *
 * Layout is BIT-IDENTICAL to tools/texel_eval.py so the eval port stays exact:
 *   index = (7 - rank)*16 + file   (a8 = 0, h1 = 119)
 *   offboard test: (idx & 0x88) != 0
 *   piece byte = type | (0x80 if white); empty = 0
 *   type: 1=P 2=N 3=B 4=R 5=Q 6=K   (matches PAWN_T..KING_T)
 *
 * This header is the FROZEN shared contract: movegen.c and eval.c code against
 * it and must NOT modify it. Search/selfplay use make/unmake + zobrist here.
 */
#ifndef CREF_BOARD_H
#define CREF_BOARD_H

#include <stdint.h>

/* Zobrist/repetition key type. FIXED at exactly 32 bits (uint32_t) on EVERY
 * target. This matters for bit-exact move agreement between the host and the
 * 6502 (llvm-mos) port: the splitmix zobrist mixer folds high bits down with
 * shifts, so a 64-bit `unsigned long` host and a 32-bit 6502 would compute
 * DIFFERENT keys -> different TT collisions and repetition hits -> occasionally
 * different best moves. Pinning to uint32_t makes the keys identical on both, so
 * the 6502 reproduces the host search exactly. 32 bits is ample to key the TT
 * (<=64K entries) and the repetition table. (perft counts at the depths we verify
 * stay < 2^32, so the `hash_t perft()` return is unaffected.) */
typedef uint32_t hash_t;

#define WHITE_FLAG 0x80
#define PT(p)       ((p) & 7)          /* piece type 1..6, 0 if empty */
#define IS_WHITE(p) ((p) & WHITE_FLAG) /* nonzero if white piece */
#define OFFBOARD(i) ((i) & 0x88)

enum { PT_PAWN = 1, PT_KNIGHT, PT_BISHOP, PT_ROOK, PT_QUEEN, PT_KING };

/* castling-right bits */
enum { CASTLE_WK = 1, CASTLE_WQ = 2, CASTLE_BK = 4, CASTLE_BQ = 8 };

/* move flags */
enum {
    MF_CAPTURE    = 1,
    MF_DOUBLE     = 2,   /* pawn double push (sets ep) */
    MF_EP         = 4,   /* en-passant capture */
    MF_CASTLE_K   = 8,   /* kingside castle */
    MF_CASTLE_Q   = 16,  /* queenside castle */
    MF_PROMO      = 32
};

typedef struct {
    uint8_t from;    /* 0x88 square */
    uint8_t to;      /* 0x88 square */
    uint8_t promo;   /* promoted piece TYPE (PT_KNIGHT..PT_QUEEN), 0 if none */
    uint8_t flags;   /* MF_* bitmask */
} Move;

typedef struct {
    uint8_t sq[128];   /* 0x88 board, piece bytes */
    int wtm;           /* 1 = white to move, 0 = black */
    int wk, bk;        /* king 0x88 squares */
    int castle;        /* CASTLE_* bitmask */
    int ep;            /* ep target 0x88 square, or -1 */
    int halfmove;      /* halfmove clock (50-move rule) */
    int fullmove;
    hash_t hash;       /* incremental zobrist */
    /* Incremental material+PST accumulators (white-POV), maintained by
     * make/unmake so the lazy eval (eval_material_pst) is O(1) instead of a full
     * board scan. APPENDED at the end: the FROZEN 0x88 layout above keeps its
     * exact offsets, so sq[]-indexing code is unaffected. Seeded by
     * eval_acc_init() at each search root (reflects the live g_w); rebuilt
     * bit-exact to eval_material_pst's old loop -- gate-verified. */
    int acc_mat;       /* sum matv[t]+pst_mg[idx], white +, black - (pre-taper) */
    int acc_egdiff;    /* sum (pst_eg-pst_mg)[idx], white +, black -            */
    int acc_phase;     /* raw game phase: N/B=1,R=2,Q=4 both colors (unclamped) */
} Board;

typedef struct {
    uint8_t captured;  /* piece byte captured (0 if none); for ep this is the pawn */
    int cap_sq;        /* 0x88 square the captured piece sat on (differs for ep) */
    int castle;        /* prior castling rights */
    int ep;            /* prior ep square */
    int halfmove;      /* prior halfmove clock */
    int wk, bk;        /* prior king squares */
    hash_t hash;       /* prior hash */
    int acc_mat, acc_egdiff, acc_phase;  /* prior accumulators (restored on unmake) */
} Undo;

/* 0x88 <-> 0..63 helpers (0..63 is python-chess square: a1=0, h8=63).
 * Macros (cc65 has no `inline`). Arguments are used more than once, so callers
 * must pass side-effect-free expressions (all current call sites do). */
#define sq0x88_from_idx64(s64) ((7 - ((s64) >> 3)) * 16 + ((s64) & 7))
#define idx64_from_0x88(i)     ((7 - ((i) >> 4)) * 8 + ((i) & 7))

/* Returns 0 on success, -1 on parse error. Initializes hash. */
int board_from_fen(Board *b, const char *fen);
/* Writes the FEN into out (>= 100 bytes). */
void board_to_fen(const Board *b, char *out);

extern int g_make_hash;   /* 0 -> make_move skips the zobrist update (quiescence) */
void make_move(Board *b, Move m, Undo *u);
void unmake_move(Board *b, Move m, const Undo *u);
void make_null(Board *b, Undo *u);            /* pass the turn (null-move pruning) */
void unmake_null(Board *b, const Undo *u);

hash_t board_zobrist(const Board *b);   /* full recompute (for verify) */

/* "e2e4", "e7e8q" -> Move resolved against the current board. Returns 0 on
 * success (writes *out), -1 if not a legal-shaped move on this board. */
int move_from_uci(const Board *b, const char *uci, Move *out);
void move_to_uci(Move m, char *out);      /* out >= 6 bytes */

/* 1 if the side to move has at least one legal move (else mate/stalemate -- use
 * in_check() to disambiguate). Reuses the engine's internal move scratch, so the
 * caller needs no MAX_MOVES buffer of its own. */
int board_any_legal_move(const Board *b);

#endif
