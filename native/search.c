/* search.c -- representative reference search (mirrors tools/reference_engine.py).
 *
 * Negamax + alpha-beta + quiescence (check-aware, no stand-pat in check) +
 * a small transposition table + MVV-LVA move ordering. The eval (eval_full) is
 * the bit-exact part; this search is only "representative" per the fidelity
 * contract -- a better eval helps any reasonable search.
 *
 * All mutable engine state (TT, repetition stack) is plain file-scope static.
 * Host self-play parallelism is fork()-based (separate processes), so each
 * worker gets its own copy with no locking; on cc65 (6502) there are no threads
 * at all. g_w (eval weights) is likewise a plain global (see eval.c), set by the
 * caller before each search.
 */
#include "search.h"
#include "movegen.h"
#include "eval.h"
#include <string.h>

#define LAZY_EVAL_MARGIN 240   /* matches src/ai/search.s LAZY_EVAL_MARGIN */
#define MAX_QUIESCE_DEPTH 6    /* matches src/ai/search.s MAX_QUIESCE_DEPTH */
/* TT size differs by target: a big table on the host (strong measurement), a
 * small one on the 6502 (RAM-fit; cc65 int is 16-bit so 1<<16 would overflow). */
#ifdef __CC65__
#define TT_BITS 8
#else
#define TT_BITS 16
#endif
#define TT_SIZE (1 << TT_BITS)
#define TT_MASK (TT_SIZE - 1)

enum { TT_EXACT, TT_LOWER, TT_UPPER };

typedef struct {
    hash_t key;
    int32_t value;
    Move best;
    int16_t depth;
    int16_t flag;
} TTEntry;

/* No _Thread_local: cc65 has no threads (6502), and host parallelism is fork()-
 * based (separate processes), so plain file-scope statics are correct -- each
 * process gets its own copy. One game runs per process; no locking needed. */
static TTEntry tt[TT_SIZE];

/* repetition: game history copied in, search path pushed on top (MAX_PATH in search.h) */
static hash_t rep[MAX_PATH];
static int rep_base;     /* number of game-history hashes */
static int rep_top;      /* current stack top */

static SearchInfo g_info;

/* Per-ply move buffers, OFF the C stack. cc65's ~256-byte call frame cannot hold
 * a MAX_MOVES Move array, and recursion needs a distinct buffer per ply. Indexed
 * by search ply; negamax and quiesce never occupy the same ply simultaneously,
 * so they share g_ml[ply]. g_score is call-scoped (order_moves never recurses). */
#define MAX_PLY 48
static Move g_ml[MAX_PLY][MAX_MOVES];     /* node move list (negamax or quiesce) */
static Move g_filt[MAX_PLY][MAX_MOVES];   /* quiesce filtered list */
static int  g_score[MAX_MOVES];           /* order_moves scratch */

/* Search-feature config + node budget (the A/B knobs). */
SearchConfig g_sc;
static long g_node_budget;    /* 0 = unlimited */
static int  g_stop;           /* set when the budget is exhausted mid-iteration */

/* killer + history tables (used only when the toggles are on). */
static Move  g_killer[MAX_PLY][2];
static short g_history[2][64][64];     /* [stm][from64][to64], idx64 0..63 */

void search_reset_config(void) {
    /* Proven winners ON by default (each +Elo at fixed nodes, SPRT-confirmed as a
     * stack). Candidate features below stay off until measured. */
    g_sc.killers = 1;
    g_sc.history = 1;
    g_sc.nullmove = 1;
    g_sc.null_r = 2;
    g_sc.pvs = 0;
    g_sc.aspiration = 0;
    g_sc.asp_delta = 50;
    g_sc.check_ext = 0;
    g_sc.lmr = 0;
}

void search_set_budget(long nodes) { g_node_budget = nodes; }

/* MVV-LVA piece values (king as attacker = cheapest pinner avoidance). */
static const int MVV[7] = {0, 100, 320, 330, 500, 900, 20000};

static int eval_stm(const Board *b) {
    int e = eval_full(b);
    return b->wtm ? e : -e;
}

/* side `white` has a knight/bishop/rook/queen (null-move zugzwang guard). */
static int has_nonpawn(const Board *b, int white) {
    uint8_t cf = white ? WHITE_FLAG : 0;
    int i;
    for (i = 0; i < 128; i++) {
        uint8_t p;
        int t;
        if (i & 0x88) continue;
        p = b->sq[i];
        if (!p || (p & WHITE_FLAG) != cf) continue;
        t = PT(p);
        if (t >= PT_KNIGHT && t <= PT_QUEEN) return 1;
    }
    return 0;
}

static int is_repetition(hash_t h) {
    int i;
    for (i = 0; i < rep_top; i++)
        if (rep[i] == h) return 1;
    return 0;
}

static int mvv_lva(const Board *b, Move m) {
    int victim = PT(b->sq[m.to]);
    int attacker, s;
    if (m.flags & MF_EP) victim = PT_PAWN;
    attacker = PT(b->sq[m.from]);
    s = MVV[victim] * 16 - MVV[attacker];
    if (m.flags & MF_PROMO) s += MVV[m.promo];
    return s;
}

static int is_killer(int ply, Move m) {
    return (g_killer[ply][0].from == m.from && g_killer[ply][0].to == m.to) ? 1 :
           (g_killer[ply][1].from == m.from && g_killer[ply][1].to == m.to) ? 2 : 0;
}

/* score moves for ordering, then selection-sort descending (n is small).
 * 16-bit-safe scores (cc65 int): TT 30000 > captures 10000+MVV-LVA > killers
 * 9000/8900 > history quiets 0..8000. */
static void order_moves(const Board *b, Move *list, int n, Move tt_move, int ply) {
    int *score = g_score;
    int have_tt = (tt_move.from != tt_move.to);
    int stm = b->wtm ? 1 : 0;
    int i, j;
    for (i = 0; i < n; i++) {
        Move m;
        m = list[i];               /* cc65 rejects struct copy-init */
        if (have_tt && m.from == tt_move.from && m.to == tt_move.to &&
            m.promo == tt_move.promo) {
            score[i] = 30000;
        } else if (m.flags & (MF_CAPTURE | MF_EP | MF_PROMO)) {
            score[i] = 10000 + mvv_lva(b, m);
        } else {
            int s = 0, k;
            if (g_sc.killers && (k = is_killer(ply, m))) {
                s = (k == 1) ? 9000 : 8900;
            } else if (g_sc.history) {
                s = g_history[stm][idx64_from_0x88(m.from)][idx64_from_0x88(m.to)];
                if (s > 8000) s = 8000;
            }
            score[i] = s;
        }
    }
    for (i = 0; i < n; i++) {
        int best = i;
        for (j = i + 1; j < n; j++)
            if (score[j] > score[best]) best = j;
        if (best != i) {
            int ts = score[i];
            Move tm;
            score[i] = score[best]; score[best] = ts;
            tm = list[i]; list[i] = list[best]; list[best] = tm;
        }
    }
}

static int quiesce(Board *b, int alpha, int beta, int ply, int qd) {
    int check;
    int best = -SEARCH_INF;
    Move *list = g_ml[ply];
    Move *filt = g_filt[ply];
    int n, fn, i;
    Move none = {0, 0, 0, 0};

    g_info.qnodes++;
    if (b->halfmove >= 100) return 0;          /* 50-move draw reachable via quiescence */
    check = in_check(b);
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
    n = gen_legal(b, list);
    if (check && n == 0) return -MATE_SCORE + ply;   /* checkmate */

    /* in check: search all evasions; else only captures/promotions */
    fn = 0;
    for (i = 0; i < n; i++) {
        if (check || (list[i].flags & (MF_CAPTURE | MF_EP | MF_PROMO)))
            filt[fn++] = list[i];
    }
    /* Quiescence depth cap (matches the 6502 limiter): stop expanding captures
     * past MAX_QUIESCE_DEPTH plies, return the stand-pat (a static eval when in
     * check, since no stand-pat was taken). */
    if (qd >= MAX_QUIESCE_DEPTH)
        return check ? eval_stm(b) : best;

    order_moves(b, filt, fn, none, ply);

    for (i = 0; i < fn; i++) {
        Undo u;
        int score;
        make_move(b, filt[i], &u);
        score = -quiesce(b, -beta, -alpha, ply + 1, qd + 1);
        unmake_move(b, filt[i], &u);
        if (score >= beta) return score;
        if (score > best) best = score;
        if (score > alpha) alpha = score;
    }
    return best;
}

static int negamax(Board *b, int depth, int alpha, int beta, int ply) {
    int alpha_orig = alpha;
    TTEntry *e = &tt[b->hash & TT_MASK];
    Move tt_move = {0, 0, 0, 0};
    Move *list = g_ml[ply];
    int n, i;
    int best_val;
    Move best_move;
    int sv;

    g_info.nodes++;
    if (g_node_budget && g_info.nodes >= g_node_budget) { g_stop = 1; return 0; }
    if (g_stop) return 0;

    if (ply > 0 && (is_repetition(b->hash) || b->halfmove >= 100))
        return 0;

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

    /* null-move pruning: if passing the turn still fails high, prune. Skip at the
     * root, in check, near mate, and in likely-zugzwang (no non-pawn material). */
    if (g_sc.nullmove && ply > 0 && depth >= 3 && beta < MATE_THRESHOLD &&
        !in_check(b) && has_nonpawn(b, b->wtm)) {
        Undo nu;
        int R = g_sc.null_r, nd, nscore;
        make_null(b, &nu);
        nd = depth - 1 - R; if (nd < 0) nd = 0;
        nscore = -negamax(b, nd, -beta, -beta + 1, ply + 1);
        unmake_null(b, &nu);
        if (g_stop) return 0;
        if (nscore >= beta) return beta;
    }

    n = gen_legal(b, list);
    if (n == 0) return in_check(b) ? -MATE_SCORE + ply : 0;
    order_moves(b, list, n, tt_move, ply);

    best_val = -SEARCH_INF;
    best_move = list[0];
    rep[rep_top++] = b->hash;          /* current node is an ancestor for children */
    for (i = 0; i < n; i++) {
        Undo u;
        int val;
        make_move(b, list[i], &u);
        val = -negamax(b, depth - 1, -beta, -alpha, ply + 1);
        unmake_move(b, list[i], &u);
        if (val > best_val) { best_val = val; best_move = list[i]; }
        if (val > alpha) alpha = val;
        if (alpha >= beta) {
            /* beta cutoff on a quiet move -> reward it for ordering future nodes */
            if (!(list[i].flags & (MF_CAPTURE | MF_EP | MF_PROMO))) {
                if (g_sc.killers && ply < MAX_PLY &&
                    !(g_killer[ply][0].from == list[i].from && g_killer[ply][0].to == list[i].to)) {
                    g_killer[ply][1] = g_killer[ply][0];
                    g_killer[ply][0] = list[i];
                }
                if (g_sc.history) {
                    int st = b->wtm ? 1 : 0;   /* b is unmade: wtm == the mover */
                    int f64 = idx64_from_0x88(list[i].from), t64 = idx64_from_0x88(list[i].to);
                    int hv = g_history[st][f64][t64] + depth * depth;
                    if (hv > 16000) hv = 16000;
                    g_history[st][f64][t64] = (short)hv;
                }
            }
            break;
        }
    }
    rep_top--;

    sv = best_val;            /* store mate scores relative to THIS node's ply */
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
                     const hash_t *hist, int hist_len, SearchInfo *out) {
    Board work;
    Move best = {0, 0, 0, 0};
    int best_score = 0;
    int d;

    memset(tt, 0, sizeof(tt));
    memset(&g_info, 0, sizeof(g_info));
    g_info.depth = depth;

    rep_base = 0;
    if (hist && hist_len > 0) {
        if (hist_len > MAX_PATH) hist_len = MAX_PATH;
        memcpy(rep, hist, hist_len * sizeof(hash_t));
        rep_base = hist_len;
    }

    work = *b;
    g_stop = 0;
    if (g_sc.killers) memset(g_killer, 0, sizeof(g_killer));
    if (g_sc.history) memset(g_history, 0, sizeof(g_history));

    {   /* fallback: first legal move, in case the node budget aborts iteration 1 */
        int nn = gen_legal(&work, g_ml[0]);
        if (nn > 0) best = g_ml[0][0];
    }

    /* iterative deepening for better ordering via the TT */
    for (d = 1; d <= depth; d++) {
        int alpha = -SEARCH_INF, beta = SEARCH_INF;
        Move *list = g_ml[0];
        int n, i;
        Move prev;
        int local_best;
        Move local_move;
        rep_top = rep_base;
        n = gen_legal(&work, list);
        if (n == 0) break;
        prev = best;
        order_moves(&work, list, n, prev, 0);
        local_best = -SEARCH_INF;
        local_move = list[0];
        /* root position is already in rep[] (passed via hist); children check
         * against it directly -- do not re-push here. */
        for (i = 0; i < n; i++) {
            Undo u;
            int val;
            make_move(&work, list[i], &u);
            val = -negamax(&work, d - 1, -beta, -alpha, 1);
            unmake_move(&work, list[i], &u);
            if (val > local_best) { local_best = val; local_move = list[i]; }
            if (val > alpha) alpha = val;
        }
        if (g_stop) break;          /* budget hit mid-iteration -> discard it */
        best = local_move;
        best_score = local_best;
        if (best_score > MATE_THRESHOLD || best_score < -MATE_THRESHOLD) break;
    }

    g_info.score = best_score;
    g_info.best = best;
    if (out) *out = g_info;
    return best;
}
