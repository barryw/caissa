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
#if defined(__CC65__) || defined(__mos__)
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
/* MAX_PLY sizes the per-NEGAMAX-ply tables (g_ml, g_killer). Negamax recurses at
 * most `depth` plies deep (check extensions off by default; measured: depth 6 ->
 * negamax ply 6 over 400 corpus positions), so MAX_PLY only needs depth+1.
 * Quiescence does NOT consume a g_ml slot per ply: its raw move list (g_qml) is
 * consumed before it recurses, so all quiesce frames share one buffer. The host
 * keeps a generous 48; the 6502 (__mos__/__CC65__) shrinks to 7 (supports depth
 * <= 6) so the move buffers fit alongside code+history+stack in ~64K. */
#if defined(__CC65__) || defined(__mos__)
#define MAX_PLY 7
#else
#define MAX_PLY 48
#endif
static Move g_ml[MAX_PLY][MAX_MOVES];     /* negamax per-ply node move list */
static Move g_qml[MAX_MOVES];             /* quiesce raw list (shared: consumed before recursion) */
/* g_filt holds the quiescence filtered list. It is indexed by quiescence depth
 * (qd 0..MAX_QUIESCE_DEPTH), NOT absolute ply: each live quiesce frame has a
 * unique qd along any root-to-leaf path, so one buffer per qd is collision-free
 * and far smaller than [MAX_PLY][MAX_MOVES]. Behavior-identical on every target. */
static Move g_filt[MAX_QUIESCE_DEPTH + 1][MAX_MOVES];
static int  g_score[MAX_MOVES];           /* order_moves scratch */

/* Search-feature config + node budget (the A/B knobs). */
SearchConfig g_sc;
static long g_node_budget;    /* 0 = unlimited */
static int  g_stop;           /* set when the budget is exhausted mid-iteration */

/* killer + history tables (used only when the toggles are on).
 *
 * The full butterfly-history table is short[2][64][64] = 16 KB. On the 6502
 * (__mos__/__CC65__) that 16 KB does not coexist with the full eval's code, the
 * per-ply move banks, and the TT inside 64 KB, so the history HEURISTIC is
 * disabled there (search_reset_config sets g_sc.history=0) and the table shrinks
 * to a 1-entry stub. The 6502 search keeps every other ordering term (TT move,
 * MVV-LVA captures, killers) plus null-move + LMR; only butterfly history is off.
 * The HOST keeps the full table and the heuristic ON (its gates are unchanged). */
#if defined(__CC65__) || defined(__mos__)
#define HISTORY_DIM 1
#else
#define HISTORY_DIM 64
#endif
static Move  g_killer[MAX_PLY][2];
static short g_history[2][HISTORY_DIM][HISTORY_DIM]; /* [stm][from64][to64], idx64 0..63 */

void search_reset_config(void) {
    /* Proven winners ON by default (each +Elo at fixed nodes, SPRT-confirmed as a
     * stack). Candidate features below stay off until measured. */
    g_sc.killers = 1;
#if defined(__CC65__) || defined(__mos__)
    g_sc.history = 0;     /* 16 KB butterfly table does not fit in 64 KB; see above */
#else
    g_sc.history = 1;
#endif
    g_sc.nullmove = 1;
    g_sc.null_r = 2;
    g_sc.lmr = 1;          /* +78 Elo @ fixed nodes (SPRT H1) */
    g_sc.pvs = 0;          /* tested -26: re-search overhead doesn't pay here */
    g_sc.check_ext = 0;    /* tested -69: unconditional extension wastes the budget */
    g_sc.aspiration = 0;
    g_sc.asp_delta = 50;
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
            /* Killers are only ever STORED for negamax plies (ply < MAX_PLY,
             * guarded at the cutoff). Quiescence can reach plies >= MAX_PLY where
             * g_killer would be out of bounds -- but those slots are always empty,
             * so skipping the lookup there is behavior-identical and lets MAX_PLY
             * size g_killer/g_ml to the negamax depth only (RAM diet on 6502). */
            if (g_sc.killers && ply < MAX_PLY && (k = is_killer(ply, m))) {
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
    Move *list = g_qml;           /* shared: the raw list is consumed (filtered into
                                   * `filt`) before this frame recurses, so all
                                   * quiesce frames can reuse one buffer. */
    Move *filt = g_filt[qd];      /* qd is unique per live quiesce frame */
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

    /* check extension: a node in check searches one ply deeper (don't let a
     * forcing line fall into quiescence early). */
    if (g_sc.check_ext && ply > 0 && ply < MAX_PLY - 4 && in_check(b)) depth++;

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
        int val, nd, gives_check, is_quiet;
        make_move(b, list[i], &u);
        gives_check = in_check(b);
        is_quiet = !(list[i].flags & (MF_CAPTURE | MF_EP | MF_PROMO));
        nd = depth - 1;
        if (g_sc.lmr && depth >= 3 && i >= 3 && is_quiet && !gives_check &&
            best_val > -SEARCH_INF) {
            val = -negamax(b, nd - 1, -alpha - 1, -alpha, ply + 1);   /* reduced null-window */
            if (val > alpha)
                val = -negamax(b, nd, -beta, -alpha, ply + 1);        /* fail-high -> full re-search */
        } else if (g_sc.pvs && i > 0 && best_val > -SEARCH_INF) {
            val = -negamax(b, nd, -alpha - 1, -alpha, ply + 1);       /* null window */
            if (val > alpha && val < beta)
                val = -negamax(b, nd, -beta, -alpha, ply + 1);        /* re-search full */
        } else {
            val = -negamax(b, nd, -beta, -alpha, ply + 1);
        }
        unmake_move(b, list[i], &u);
        if (g_stop) break;
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
