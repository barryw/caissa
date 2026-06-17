/* caissa.c -- the public engine<->UI API (see caissa.h).
 *
 * A thin facade over the engine: it owns the committed-game bookkeeping (position
 * history for threefold + take-back, draw-rule classification, a ponder cache) so
 * a UI can run a whole game without touching engine internals. */
#include "caissa.h"
#include "movegen.h"   /* gen_legal, in_check */
#include "eval.h"      /* eval_full, eval_reset_weights, eval_acc_init */

#define CAISSA_START_FEN "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
#define CAISSA_MAX_MOVES 256

static int move_eq(Move a, Move b) {
    return a.from == b.from && a.to == b.to && a.promo == b.promo;
}

/* No pawns/rooks/queens on either side, and either <=1 minor total or only
 * same-colored bishops -> neither side can force mate (FIDE automatic draw). */
static int insufficient_material(const Board *b) {
    int idx, knights = 0, bishops = 0, bishop_colors = 0;
    for (idx = 0; idx < 128; idx++) {
        int p = b->sq[idx];
        if (OFFBOARD(idx) || p == 0) continue;
        switch (PT(p)) {
            case PT_PAWN: case PT_ROOK: case PT_QUEEN: return 0;
            case PT_KNIGHT: knights++; break;
            case PT_BISHOP:
                bishops++;
                bishop_colors |= 1 << (((idx & 7) + (idx >> 4)) & 1);
                break;
            default: break; /* king */
        }
    }
    if (knights + bishops <= 1) return 1;          /* KvK, K+minor vs K */
    if (knights == 0 && bishop_colors != 3) return 1; /* all bishops same color */
    return 0;
}

void caissa_init(void) {
    eval_reset_weights();   /* loads baseline g_w + eval_sync_tables() */
    search_reset_config();
}

int caissa_new_game(CaissaGame *g, const char *fen) {
    if (!fen) fen = CAISSA_START_FEN;
    if (board_from_fen(&g->board, fen) != 0) return -1;
    eval_acc_init(&g->board);         /* seed acc_* so eval_full/search are valid */
    g->hist_len = 1;
    g->hist[0] = g->board.hash;
    g->ponder_valid = 0;
    return 0;
}

int caissa_side_to_move(const CaissaGame *g) { return g->board.wtm; }
const Board *caissa_board(const CaissaGame *g) { return &g->board; }
int caissa_eval(const CaissaGame *g) { return eval_full(&g->board); }
void caissa_to_fen(const CaissaGame *g, char *out) { board_to_fen(&g->board, out); }
void caissa_move_to_uci(Move m, char *out) { move_to_uci(m, out); }
int caissa_move_from_uci(const CaissaGame *g, const char *uci, Move *out) {
    return move_from_uci(&g->board, uci, out);
}

int caissa_legal_moves(const CaissaGame *g, Move *out, int max) {
    Move ml[CAISSA_MAX_MOVES];
    int n = gen_legal(&g->board, ml), i;
    for (i = 0; i < n && i < max; i++) out[i] = ml[i];
    return n;
}

int caissa_is_legal(const CaissaGame *g, Move m) {
    Move ml[CAISSA_MAX_MOVES];
    int n = gen_legal(&g->board, ml), i;
    for (i = 0; i < n; i++) if (move_eq(ml[i], m)) return 1;
    return 0;
}

CaissaState caissa_state(const CaissaGame *g) {
    Move ml[CAISSA_MAX_MOVES];
    int n = gen_legal(&g->board, ml), i, reps = 0;
    if (n == 0) return in_check(&g->board) ? CAISSA_CHECKMATE : CAISSA_STALEMATE;
    if (g->board.halfmove >= 100) return CAISSA_DRAW_50MOVE;
    for (i = 0; i < g->hist_len; i++) if (g->hist[i] == g->board.hash) reps++;
    if (reps >= 3) return CAISSA_DRAW_REPETITION;
    if (insufficient_material(&g->board)) return CAISSA_DRAW_INSUFFICIENT;
    return in_check(&g->board) ? CAISSA_CHECK : CAISSA_NORMAL;
}

Move caissa_bestmove(CaissaGame *g, int depth, SearchInfo *info) {
    SearchInfo local;
    return search_bestmove(&g->board, depth, g->hist, g->hist_len,
                           info ? info : &local);
}

int caissa_commit(CaissaGame *g, Move m) {
    int idx;
    if (g->hist_len >= MAX_PATH) return -1;     /* game history full */
    if (!caissa_is_legal(g, m)) return -1;
    idx = g->hist_len - 1;                        /* this move's slot */
    g->moves[idx] = m;
    make_move(&g->board, m, &g->undos[idx]);
    g->hist[g->hist_len++] = g->board.hash;
    /* note: committing does NOT clear the ponder cache -- the expected flow is
     * ponder(predicted) -> commit(predicted) -> ponder_hit(predicted). The cache
     * is consumed by ponder_hit and replaced by the next ponder / new_game. */
    return 0;
}

int caissa_undo(CaissaGame *g) {
    int idx;
    if (g->hist_len <= 1) return -1;             /* at the root */
    g->hist_len--;
    idx = g->hist_len - 1;
    unmake_move(&g->board, g->moves[idx], &g->undos[idx]);
    g->ponder_valid = 0;
    return 0;
}

int caissa_ponder(CaissaGame *g, Move predicted, int depth) {
    Board tmp;
    Undo u;
    hash_t th[MAX_PATH + 1];
    SearchInfo si;
    int i;
    if (!caissa_is_legal(g, predicted)) return -1;
    tmp = g->board;
    make_move(&tmp, predicted, &u);
    for (i = 0; i < g->hist_len; i++) th[i] = g->hist[i];
    th[g->hist_len] = tmp.hash;
    g->ponder_reply = search_bestmove(&tmp, depth, th, g->hist_len + 1, &si);
    g->ponder_predicted = predicted;
    g->ponder_valid = 1;
    return 0;
}

int caissa_ponder_hit(CaissaGame *g, Move actual, Move *reply) {
    if (g->ponder_valid && move_eq(actual, g->ponder_predicted)) {
        *reply = g->ponder_reply;
        g->ponder_valid = 0;   /* consume */
        return 1;
    }
    g->ponder_valid = 0;
    return 0;
}
