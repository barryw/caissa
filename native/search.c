/* search.c -- representative reference search (mirrors tools/reference_engine.py).
 *
 * Negamax + alpha-beta + quiescence (check-aware, no stand-pat in check) +
 * a small thread-local transposition table + MVV-LVA move ordering. The eval
 * (eval_full) is the bit-exact part; this search is only "representative" per
 * the fidelity contract -- a better eval helps any reasonable search.
 *
 * All mutable engine state (TT, repetition stack) is _Thread_local so self-play
 * can run one game per thread with no locking. g_w (eval weights) is also
 * thread-local (see eval.c), set by the caller before each search.
 */
#include "search.h"
#include "movegen.h"
#include "eval.h"
#include <string.h>

#define LAZY_EVAL_MARGIN 240   /* matches src/ai/search.s LAZY_EVAL_MARGIN */
#define MAX_QUIESCE_DEPTH 6    /* matches src/ai/search.s MAX_QUIESCE_DEPTH */
#define TT_BITS 16
#define TT_SIZE (1 << TT_BITS)
#define TT_MASK (TT_SIZE - 1)

enum { TT_EXACT, TT_LOWER, TT_UPPER };

typedef struct {
    uint64_t key;
    int32_t value;
    Move best;
    int16_t depth;
    int16_t flag;
} TTEntry;

static _Thread_local TTEntry tt[TT_SIZE];

/* repetition: game history copied in, search path pushed on top (MAX_PATH in search.h) */
static _Thread_local uint64_t rep[MAX_PATH];
static _Thread_local int rep_base;     /* number of game-history hashes */
static _Thread_local int rep_top;      /* current stack top */

static _Thread_local SearchInfo g_info;

/* MVV-LVA piece values (king as attacker = cheapest pinner avoidance). */
static const int MVV[7] = {0, 100, 320, 330, 500, 900, 20000};

static inline int eval_stm(const Board *b) {
    int e = eval_full(b);
    return b->wtm ? e : -e;
}

static int is_repetition(uint64_t h) {
    for (int i = 0; i < rep_top; i++)
        if (rep[i] == h) return 1;
    return 0;
}

static int mvv_lva(const Board *b, Move m) {
    int victim = PT(b->sq[m.to]);
    if (m.flags & MF_EP) victim = PT_PAWN;
    int attacker = PT(b->sq[m.from]);
    int s = MVV[victim] * 16 - MVV[attacker];
    if (m.flags & MF_PROMO) s += MVV[m.promo];
    return s;
}

/* score moves for ordering, then selection-sort descending (n is small). */
static void order_moves(const Board *b, Move *list, int n, Move tt_move) {
    int score[MAX_MOVES];
    int have_tt = (tt_move.from != tt_move.to);
    for (int i = 0; i < n; i++) {
        Move m = list[i];
        if (have_tt && m.from == tt_move.from && m.to == tt_move.to &&
            m.promo == tt_move.promo)
            score[i] = 1 << 24;
        else if (m.flags & (MF_CAPTURE | MF_EP | MF_PROMO))
            score[i] = 1000 + mvv_lva(b, m);
        else
            score[i] = 0;
    }
    for (int i = 0; i < n; i++) {
        int best = i;
        for (int j = i + 1; j < n; j++)
            if (score[j] > score[best]) best = j;
        if (best != i) {
            int ts = score[i]; score[i] = score[best]; score[best] = ts;
            Move tm = list[i]; list[i] = list[best]; list[best] = tm;
        }
    }
}

static int quiesce(Board *b, int alpha, int beta, int ply, int qd) {
    g_info.qnodes++;
    if (b->halfmove >= 100) return 0;          /* 50-move draw reachable via quiescence */
    int check = in_check(b);
    int best = -SEARCH_INF;
    if (!check) {
        /* Lazy stand-pat with margin, mirroring the 6502 EvaluateLazy: the full
         * positional terms are paid for only when the cheap material+PST score is
         * within LAZY_EVAL_MARGIN of the window. Without this the native search
         * over-credits full-eval-only terms vs the real engine (see the d3
         * native +192 / 6502 ~0 transfer gap). */
        int lazy_w = eval_material_pst(b);
        int lazy = b->wtm ? lazy_w : -lazy_w;
        int stand;
        if (lazy >= beta + LAZY_EVAL_MARGIN) stand = lazy;
        else if (lazy <= alpha - LAZY_EVAL_MARGIN) stand = lazy;
        else stand = eval_stm(b);
        if (stand >= beta) return stand;
        if (stand > alpha) alpha = stand;
        best = stand;
    }
    Move list[MAX_MOVES];
    int n = gen_legal(b, list);
    if (check && n == 0) return -MATE_SCORE + ply;   /* checkmate */

    /* in check: search all evasions; else only captures/promotions */
    Move filt[MAX_MOVES];
    int fn = 0;
    for (int i = 0; i < n; i++) {
        if (check || (list[i].flags & (MF_CAPTURE | MF_EP | MF_PROMO)))
            filt[fn++] = list[i];
    }
    /* Quiescence depth cap (matches the 6502 limiter): stop expanding captures
     * past MAX_QUIESCE_DEPTH plies, return the stand-pat (a static eval when in
     * check, since no stand-pat was taken). */
    if (qd >= MAX_QUIESCE_DEPTH)
        return check ? eval_stm(b) : best;

    Move none = {0, 0, 0, 0};
    order_moves(b, filt, fn, none);

    for (int i = 0; i < fn; i++) {
        Undo u;
        make_move(b, filt[i], &u);
        int score = -quiesce(b, -beta, -alpha, ply + 1, qd + 1);
        unmake_move(b, filt[i], &u);
        if (score >= beta) return score;
        if (score > best) best = score;
        if (score > alpha) alpha = score;
    }
    return best;
}

static int negamax(Board *b, int depth, int alpha, int beta, int ply) {
    g_info.nodes++;

    if (ply > 0 && (is_repetition(b->hash) || b->halfmove >= 100))
        return 0;

    int alpha_orig = alpha;
    TTEntry *e = &tt[b->hash & TT_MASK];
    Move tt_move = {0, 0, 0, 0};
    if (e->key == b->hash) {
        tt_move = e->best;
        if (e->depth >= depth) {
            /* mate scores are stored relative to the storing node's ply;
             * re-anchor to this node's ply before using them. */
            int tv = e->value;
            if (tv > MATE_THRESHOLD) tv -= ply;
            else if (tv < -MATE_THRESHOLD) tv += ply;
            g_info.tt_hits++;
            if (e->flag == TT_EXACT) return tv;
            if (e->flag == TT_LOWER && tv >= beta) return tv;   /* fail-high bound */
            if (e->flag == TT_UPPER && tv <= alpha) return tv;  /* fail-low bound */
        }
    }

    if (depth <= 0) return quiesce(b, alpha, beta, ply, 0);

    Move list[MAX_MOVES];
    int n = gen_legal(b, list);
    if (n == 0) return in_check(b) ? -MATE_SCORE + ply : 0;
    order_moves(b, list, n, tt_move);

    int best_val = -SEARCH_INF;
    Move best_move = list[0];
    rep[rep_top++] = b->hash;          /* current node is an ancestor for children */
    for (int i = 0; i < n; i++) {
        Undo u;
        make_move(b, list[i], &u);
        int val = -negamax(b, depth - 1, -beta, -alpha, ply + 1);
        unmake_move(b, list[i], &u);
        if (val > best_val) { best_val = val; best_move = list[i]; }
        if (val > alpha) alpha = val;
        if (alpha >= beta) break;
    }
    rep_top--;

    int sv = best_val;            /* store mate scores relative to THIS node's ply */
    if (sv > MATE_THRESHOLD) sv += ply;
    else if (sv < -MATE_THRESHOLD) sv -= ply;
    e->key = b->hash;
    e->value = sv;
    e->best = best_move;
    e->depth = depth;
    e->flag = (best_val <= alpha_orig) ? TT_UPPER :
              (best_val >= beta)       ? TT_LOWER : TT_EXACT;
    return best_val;
}

Move search_bestmove(const Board *b, int depth,
                     const uint64_t *hist, int hist_len, SearchInfo *out) {
    memset(tt, 0, sizeof(tt));
    memset(&g_info, 0, sizeof(g_info));
    g_info.depth = depth;

    rep_base = 0;
    if (hist && hist_len > 0) {
        if (hist_len > MAX_PATH) hist_len = MAX_PATH;
        memcpy(rep, hist, hist_len * sizeof(uint64_t));
        rep_base = hist_len;
    }

    Board work = *b;
    Move best = {0, 0, 0, 0};
    int best_score = 0;

    /* iterative deepening for better ordering via the TT */
    for (int d = 1; d <= depth; d++) {
        rep_top = rep_base;
        int alpha = -SEARCH_INF, beta = SEARCH_INF;
        Move list[MAX_MOVES];
        int n = gen_legal(&work, list);
        if (n == 0) break;
        Move prev = best;
        order_moves(&work, list, n, prev);
        int local_best = -SEARCH_INF;
        Move local_move = list[0];
        /* root position is already in rep[] (passed via hist); children check
         * against it directly -- do not re-push here. */
        for (int i = 0; i < n; i++) {
            Undo u;
            make_move(&work, list[i], &u);
            int val = -negamax(&work, d - 1, -beta, -alpha, 1);
            unmake_move(&work, list[i], &u);
            if (val > local_best) { local_best = val; local_move = list[i]; }
            if (val > alpha) alpha = val;
        }
        best = local_move;
        best_score = local_best;
        if (best_score > MATE_THRESHOLD || best_score < -MATE_THRESHOLD) break;
    }

    g_info.score = best_score;
    g_info.best = best;
    if (out) *out = g_info;
    return best;
}
