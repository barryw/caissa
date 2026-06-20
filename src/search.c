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
#include "egtb.h"
#include <string.h>

#define LAZY_EVAL_MARGIN 240   /* matches src/ai/search.s LAZY_EVAL_MARGIN */
#define MAX_QUIESCE_DEPTH CREF_MAX_QUIESCE_DEPTH  /* matches src/ai/search.s */
/* TT size is per memory profile (memcfg.h): a big table on the host (strong
 * measurement), a small one on a bare 6502 (RAM-fit; cc65 int is 16-bit so
 * 1<<16 would overflow). */
#define TT_BITS CREF_TT_BITS
#define TT_SIZE (1 << TT_BITS)
#define TT_MASK (TT_SIZE - 1)

enum { TT_EXACT, TT_LOWER, TT_UPPER };

/* Packed to 12 bytes (was 16): `value` fits int16 (scores are within
 * +-SEARCH_INF=32000, mate +-30013), depth (<= search depth) and flag (0..2) fit
 * int8. The stored numeric values are unchanged, so the search reads identical
 * entries -> bit-exact. Saves 4 bytes/entry (1 KB at TT_BITS=8). */
typedef struct {
    hash_t key;
    Move best;
    int16_t value;
    int8_t depth;
    int8_t flag;
} TTEntry;

#if defined(CREF_TT_REU) && CREF_TT_REU
/* egtb.c places the EGTB table at REU offset (1<<CREF_TT_BITS)*12, i.e. it hard-codes
 * sizeof(TTEntry)==12 as the TT stride. If this struct ever grows, that base would
 * land INSIDE the TT and corrupt every probe -- catch it at compile time here. */
typedef char tt_entry_is_exactly_12_bytes[sizeof(TTEntry) == 12 ? 1 : -1];
#endif

/* No _Thread_local: cc65 has no threads (6502), and host parallelism is fork()-
 * based (separate processes), so plain file-scope statics are correct -- each
 * process gets its own copy. One game runs per process; no locking needed.
 *
 * CREF_TT_XRAM: a >64K transposition table lives off the 6502's 16-bit address
 * space (Nova 512K windowed XRAM / C64 REU DMA), accessed by copying one entry
 * in/out of a scratch via the platform's tt_xram_load/store/clear. Measured win:
 * a TT14 (16K entries) cuts ~25% of nodes at d6; the per-access window/DMA penalty
 * (~30 cyc x ~48K accesses/move = ~1.4M cyc) is ~0.15% of cyc/move -- negligible
 * vs the ~311M cyc the node cut saves. The DEFAULT (flat) path below keeps direct
 * entry pointers: zero-copy, byte-identical to the original. The copy-through
 * backing here is the VALIDATION shim (proves the in/out logic is bit-exact on the
 * flat mos-sim core); the real REU/Nova accessors swap memcpy for DMA/window. */
#if CREF_TT_XRAM
#  if CREF_TT_REU
/* C64 REU (1764/1750) DMA backing: the TT lives in the RAM Expansion Unit; each
 * probe/store copies one entry between a C64 scratch and REU[idx*sizeof] via the
 * $DF00 DMA controller (CPU halts ~sizeof cycles per transfer). $DF01 commands:
 * $91 = fetch REU->C64, $90 = stash C64->REU (bit7 execute, bit4 immediate). */
#define REU_REG ((volatile unsigned char *)0xDF00)
/* The eight $DF02-$DF0A registers are programmed one at a time and only the final
 * $DF01 write triggers the DMA, so the whole sequence MUST be atomic. The live
 * 60 Hz KERNAL IRQ otherwise preempts it mid-setup and clobbers the zero-page temps
 * holding the address/length parameters, sending the transfer to the wrong place --
 * a real, search-only corruption (the isolated micro-tests never tripped it; only a
 * full search did). SEI/CLI brackets the window: the engine always runs with IRQs
 * enabled during search (KERNAL is banked in), and reu_xfer is only ever called from
 * the search, so re-enabling unconditionally is correct here. (PHP/PLP to preserve
 * the caller's flag was measured LESS reliable -- it left an off-by-one node count
 * on one position -- so the simple, bit-exact SEI/CLI stays.) */
static void reu_xfer(const void *c64, unsigned long reu, unsigned len, unsigned char cmd) {
    unsigned a = (unsigned)c64;
    /* "memory" clobber is load-bearing: without it the compiler may hoist/sink the
     * volatile $DF02-$DF01 stores across the bare sei/cli, leaving part of the
     * non-atomic setup exposed to the IRQ again (passed d4 but corrupted d5/d6). */
    __asm__ volatile ("sei" ::: "memory");
    REU_REG[0x02] = (unsigned char)a;          REU_REG[0x03] = (unsigned char)(a >> 8);
    REU_REG[0x04] = (unsigned char)reu;        REU_REG[0x05] = (unsigned char)(reu >> 8);
    REU_REG[0x06] = (unsigned char)(reu >> 16);
    REU_REG[0x07] = (unsigned char)len;        REU_REG[0x08] = (unsigned char)(len >> 8);
    REU_REG[0x0A] = 0;                          /* increment both C64 and REU addrs */
    REU_REG[0x01] = cmd;                        /* execute (DMA runs before the next insn) */
    __asm__ volatile ("cli" ::: "memory");
}
#ifdef CREF_TT_REU_DEBUG
/* Dual REU+RAM-shadow self-check (small TT only): every store goes to BOTH the REU
 * and a flat shadow; every load reads from REU and compares vs the shadow, latching
 * the FIRST divergence (g_reu_err=count, g_reu_erridx/g_reu_errbyte/g_reu_got/_want
 * = first bad cell). Peek these symbols after a real search to localise the bug. */
volatile unsigned       g_reu_err     = 0;
volatile unsigned       g_reu_erridx  = 0xFFFF;
volatile unsigned char  g_reu_errbyte = 0xFF;
volatile unsigned char  g_reu_got     = 0;
volatile unsigned char  g_reu_want    = 0;
static TTEntry tt_shadow[TT_SIZE];
static inline void tt_xram_load(unsigned i, TTEntry *d) {
    const unsigned char *want = (const unsigned char *)&tt_shadow[i];
    unsigned char *got = (unsigned char *)d;
    unsigned k;
    reu_xfer(d, (unsigned long)i * sizeof(TTEntry), sizeof(TTEntry), 0x91);
    for (k = 0; k < sizeof(TTEntry); k++)
        if (got[k] != want[k]) {
            if (!g_reu_err) { g_reu_erridx = i; g_reu_errbyte = (unsigned char)k;
                              g_reu_got = got[k]; g_reu_want = want[k]; }
            g_reu_err++; break;
        }
}
static inline void tt_xram_store(unsigned i, const TTEntry *s) {
    reu_xfer(s, (unsigned long)i * sizeof(TTEntry), sizeof(TTEntry), 0x90);
    tt_shadow[i] = *s;
}
static void tt_xram_clear(void) {
    static const TTEntry zero = {0, {0,0,0,0}, 0, 0, 0};
    unsigned i;
    g_reu_err = 0; g_reu_erridx = 0xFFFF;
    for (i = 0; i < TT_SIZE; i++) tt_xram_store(i, &zero);
}
#else
static inline void tt_xram_load(unsigned i, TTEntry *d)
    { reu_xfer(d, (unsigned long)i * sizeof(TTEntry), sizeof(TTEntry), 0x91); }
static inline void tt_xram_store(unsigned i, const TTEntry *s)
    { reu_xfer(s, (unsigned long)i * sizeof(TTEntry), sizeof(TTEntry), 0x90); }
static void tt_xram_clear(void) {                 /* zero all entries (REU has no fill) */
    static const TTEntry zero = {0, {0,0,0,0}, 0, 0, 0};
    unsigned i;
    for (i = 0; i < TT_SIZE; i++) tt_xram_store(i, &zero);
}
#endif
#  else
static TTEntry tt_x[TT_SIZE];   /* validation backing (flat); real build = REU/XRAM */
static inline void tt_xram_load(unsigned i, TTEntry *d)        { *d = tt_x[i]; }
static inline void tt_xram_store(unsigned i, const TTEntry *s) { tt_x[i] = *s; }
static inline void tt_xram_clear(void) { memset(tt_x, 0, sizeof(tt_x)); }
#  endif
#else
static TTEntry tt[TT_SIZE];
#endif

/* repetition: game history copied in, search path pushed on top (MAX_PATH in search.h) */
static hash_t rep[MAX_PATH];
static int rep_base;     /* number of game-history hashes */
static int rep_top;      /* current stack top */

static SearchInfo g_info;

/* Move buffers live in a single shared POOL (g_pool below), OFF the C stack:
 * cc65's ~256-byte call frame cannot hold a MAX_MOVES Move array, and each frame
 * needs its own list across recursion. The pool packs the actual per-node move
 * counts along the live path, which replaced the old [MAX_PLY][256] +
 * [Q+1][256] fixed banks (~15 KB) -- see the g_pool comment.
 *
 * MAX_PLY now sizes only g_killer + the `ply < MAX_PLY` killer bound. Negamax
 * recurses at most `depth` plies deep (check extensions off by default; measured:
 * depth 6 -> negamax ply 6 over 400 corpus positions), so MAX_PLY needs depth+1.
 * The host keeps a generous 48; a bare 6502 uses 7 (supports depth <= 6). Sized
 * per profile (memcfg.h). */
#define MAX_PLY CREF_MAX_PLY

/* Shared move pool (replaces the per-ply [MAX_PLY][256] negamax banks and the
 * per-qd quiescence banks). Each search frame takes its move list at g_pool_top,
 * RESERVES only the actual move count it will iterate (g_pool_top += count) for
 * the lifetime of its loop, and restores g_pool_top on exit -- so the pool packs
 * the real per-node counts along the live path instead of reserving 256 slots
 * per ply. A frame whose generate would not leave MAX_MOVES of headroom returns a
 * static-eval leaf rather than overflow (safe; CREF_POOL_SIZE is sized so this
 * never fires in normal play -- see g_pool_hw). gen_legal writes <= MAX_MOVES at
 * the top, so the MAX_MOVES headroom check makes the generate itself safe. */
static Move g_pool[CREF_POOL_SIZE];
static int  g_pool_top;
static int  g_pool_hw;                    /* high-water mark (instrumentation) */
static int  g_score[MAX_MOVES];           /* order_moves scratch (quiescence, transient) */
/* Per-node ordering scores for negamax LAZY selection: mirrors g_pool exactly
 * (same offset as a node's move list), so scores persist across the node's move
 * loop even though children recurse. Lets negamax pick the next-best move on
 * demand and skip sorting the tail it never searches (beta cutoff). */
#if CREF_LAZY_SELECT
static int  g_score_pool[CREF_POOL_SIZE];
#else
static int  g_score_pool[1];   /* eager ordering sorts list[] in place -- no parallel
                                * score array needed; stub keeps the slice math valid. */
#endif
#define POOL_ROOM (CREF_POOL_SIZE - g_pool_top >= MAX_MOVES)

/* Search-feature config + node budget (the A/B knobs). */
SearchConfig g_sc;
static long g_node_budget;    /* 0 = unlimited */
static int  g_stop;           /* set when the budget is exhausted mid-iteration */

/* killer + history tables (used only when the toggles are on).
 *
 * The full butterfly-history table is short[2][64][64] = 16 KB. On a bare 6502
 * that 16 KB does not coexist with the full eval's code, the per-ply move banks,
 * and the TT inside 64 KB, so the history HEURISTIC is disabled there
 * (search_reset_config sets g_sc.history=0) and the table shrinks to a 1-entry
 * stub (HISTORY_DIM from memcfg.h). The 6502 search keeps every other ordering
 * term (TT move, MVV-LVA captures, killers) plus null-move + LMR; only butterfly
 * history is off. The HOST keeps the full table and the heuristic ON. */
#define HISTORY_DIM CREF_HISTORY_DIM
static Move  g_killer[MAX_PLY][2];
static short g_history[2][HISTORY_DIM][HISTORY_DIM]; /* [stm][from64][to64], idx64 0..63 */

void search_reset_config(void) {
    /* Proven winners ON by default (each +Elo at fixed nodes, SPRT-confirmed as a
     * stack). Candidate features below stay off until measured. */
    g_sc.killers = 1;
    /* history needs the full butterfly table; only enable it when the profile
     * actually allocates one (HISTORY_DIM > 1). The stub profiles keep it off. */
#if CREF_HISTORY_DIM > 1
    g_sc.history = 1;
#else
    g_sc.history = 0;     /* 16 KB butterfly table does not fit; table is a stub */
#endif
    g_sc.nullmove = 1;
    g_sc.null_r = 2;
    g_sc.lmr = 1;          /* +78 Elo @ fixed nodes (SPRT H1) */
    g_sc.pvs = 0;          /* tested -26: re-search overhead doesn't pay here */
    g_sc.check_ext = 0;    /* tested -69: unconditional extension wastes the budget */
    g_sc.aspiration = 0;
    g_sc.asp_delta = 50;
    g_sc.delta = 1;          /* quiescence delta pruning: −10% cycles/move on-chip
                              * (same-corpus 6502 measure), fixed-depth strength-neutral
                              * (1000-game self-play 50.6%, noise). The cycle win is
                              * depth headroom at the chip's 1 MHz time control. */
    g_sc.delta_margin = 200;
    g_sc.lazy_margin = 80;   /* was 240. eval_full dominates (56% of cycles in the
                              * opening); paying the full positional eval only within
                              * 80cp of the window cuts −18% cyc/move and is strength
                              * neutral-or-better (1400-game self-play ~+12 Elo for 80,
                              * within noise). Coarser quiescence stand-pat, not the
                              * root/PV eval, so eval QUALITY where it matters is intact. */
    g_sc.see = 1;            /* quiescence SEE pruning: on (Elo-neutral @800g d4). */
    g_sc.see_order = 1;      /* main-search SEE move ordering: on (Elo-neutral @800g d4). */
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

/* Compute ordering scores (no sort) into score[0..n).
 * 16-bit-safe scores (cc65 int): TT 30000 > captures 10000+MVV-LVA > killers
 * 9000/8900 > history quiets 0..8000. */
static void score_moves(const Board *b, Move *list, int *score, int n, Move tt_move,
                        int ply, int see_ord) {
    int have_tt = (tt_move.from != tt_move.to);
    int stm = b->wtm ? 1 : 0;
    int i;
    for (i = 0; i < n; i++) {
        Move m;
        m = list[i];               /* cc65 rejects struct copy-init */
        if (have_tt && m.from == tt_move.from && m.to == tt_move.to &&
            m.promo == tt_move.promo) {
            score[i] = 30000;
        } else if (m.flags & (MF_CAPTURE | MF_EP | MF_PROMO)) {
            score[i] = 10000 + mvv_lva(b, m);
            /* SEE-demote losing captures below all quiets/killers so they are
             * searched last. Only captures that COULD lose need the costly see()
             * call: capturing a piece of value >= the attacker's is always SEE>=0.
             * Promotions add material -> treated as winning (never demoted). */
            if (see_ord && !(m.flags & MF_PROMO)) {
                int victim = (m.flags & MF_EP) ? PT_PAWN : PT(b->sq[m.to]);
                int attacker = PT(b->sq[m.from]);
                if (MVV[attacker] > MVV[victim]) {
                    int sv = see(b, m);
                    if (sv < 0) score[i] = sv;   /* < 0 -> below quiets (0..9000) */
                }
            }
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
}

/* One selection pass: swap the highest-scored move in [i,n) (first on ties) to
 * position i, keeping list[] and score[] in lockstep. Calling this for i=0..n-1
 * == a full selection sort; calling it on demand inside the move loop is LAZY
 * selection -- a node that beta-cuts after k moves pays O(n*k), not O(n^2). */
static void pick_best(Move *list, int *score, int n, int i) {
    int best = i, bestval = score[i], j;
    for (j = i + 1; j < n; j++)
        if (score[j] > bestval) { bestval = score[j]; best = j; }
    if (best != i) {
        Move tm;
        score[best] = score[i]; score[i] = bestval;
        tm = list[i]; list[i] = list[best]; list[best] = tm;
    }
}

/* Eager score + full sort (used by quiescence, where n is small). */
static void order_moves(const Board *b, Move *list, int n, Move tt_move, int ply,
                        int see_ord) {
    int i;
    score_moves(b, list, g_score, n, tt_move, ply, see_ord);
    for (i = 0; i < n; i++) pick_best(list, g_score, n, i);
}

static int quiesce(Board *b, int alpha, int beta, int ply, int qd) {
    int check;
    int best = -SEARCH_INF;
    Move *list;                   /* allocated from the shared pool below */
    int n, fn, i, pool_base;
    Move none = {0, 0, 0, 0};

    g_info.qnodes++;
    if (b->halfmove >= 100) return 0;          /* 50-move draw reachable via quiescence */
#if CREF_EGTB
    if (b->acc_phase <= 4) {                    /* exact TB value for covered 3-man */
        int eg_sc;
        if (egtb_probe(b, ply, &eg_sc)) return eg_sc;
    }
#endif
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
        if (lazy >= beta + g_sc.lazy_margin) stand = lazy;
        else if (lazy <= alpha - g_sc.lazy_margin) stand = lazy;
        else stand = eval_stm(b);
        if (stand >= beta) return stand;
        if (stand > alpha) alpha = stand;
        best = stand;
    }
    /* Pool full -> treat as a leaf (cannot generate safely). Vanishingly rare. */
    if (!POOL_ROOM) return check ? eval_stm(b) : best;
    list = g_pool + g_pool_top;
    /* In check: all evasions (gen_legal). Else: ONLY legal captures, generated
     * directly -- gen_legal_captures never builds the quiet moves quiescence
     * would discard (89-97% of gen_legal's output). Same kept set, bit-exact. */
    if (check) {
        n = gen_legal(b, list);
        if (n == 0) return -MATE_SCORE + ply;        /* checkmate (pool not reserved) */
        fn = n;
    } else {
        fn = gen_legal_captures(b, list);
    }
    /* Quiescence depth cap (matches the 6502 limiter): stop expanding captures
     * past MAX_QUIESCE_DEPTH plies, return the stand-pat (a static eval when in
     * check, since no stand-pat was taken). */
    if (qd >= MAX_QUIESCE_DEPTH)
        return check ? eval_stm(b) : best;

    order_moves(b, list, fn, none, ply, 0);   /* quiescence: no SEE ordering (qsearch
                                                * already see-prunes; demote-below-quiets
                                                * is moot when there are no quiets) */

    pool_base = g_pool_top;
    g_pool_top += fn;                          /* reserve only the kept moves */
    if (g_pool_top > g_pool_hw) g_pool_hw = g_pool_top;

    for (i = 0; i < fn; i++) {
        Undo u;
        int score;
        /* Delta pruning: out of check, skip a capture whose best-case material
         * gain (victim value + safety margin) still cannot lift the stand-pat to
         * alpha -- it is futile. Promotions are never pruned (huge swing). This
         * is what reins in the qsearch explosion (qnodes were ~81% of effort). */
        if (g_sc.delta && !check && !(list[i].flags & MF_PROMO)) {
            int victim = (list[i].flags & MF_EP) ? PT_PAWN : PT(b->sq[list[i].to]);
            if (best + MVV[victim] + g_sc.delta_margin <= alpha)
                continue;
        }
        /* SEE pruning: out of check, skip a capture that loses material outright
         * (the recapture sequence nets negative). More precise than delta's
         * victim+margin heuristic -- kills losing captures delta keeps. Only
         * captures that COULD lose need the see() call: capturing a piece of value
         * >= the attacker's is always SEE >= 0, so it can never be pruned. The
         * MVV[attacker] > MVV[victim] guard skips see() for those -- behavior-
         * identical (never skips a prune) and cuts see() calls (see ~12% of cyc). */
        if (g_sc.see && !check && !(list[i].flags & MF_PROMO)) {
            int sv = (list[i].flags & MF_EP) ? PT_PAWN : PT(b->sq[list[i].to]);
            int sa = PT(b->sq[list[i].from]);
            if (MVV[sa] > MVV[sv] && see(b, list[i]) < 0)
                continue;
        }
        make_move(b, list[i], &u);
        score = -quiesce(b, -beta, -alpha, ply + 1, qd + 1);
        unmake_move(b, list[i], &u);
        if (score > best) best = score;
        if (score > alpha) alpha = score;
        if (alpha >= beta) break;              /* fail-high (== old score>=beta return) */
    }
    g_pool_top = pool_base;
    return best;
}

static int negamax(Board *b, int depth, int alpha, int beta, int ply) {
    int alpha_orig = alpha;
    unsigned tt_idx = (unsigned)(b->hash & TT_MASK);
#if CREF_TT_XRAM
    TTEntry te;                 /* this node's entry: copied in below, flushed at store */
    TTEntry *e = &te;
    tt_xram_load(tt_idx, e);
#else
    TTEntry *e = &tt[tt_idx];
#endif
    Move tt_move = {0, 0, 0, 0};
    Move *list;                  /* allocated from the shared pool below */
    int *scores;                 /* parallel slice of g_score_pool (lazy order) */
    int n, i, pool_base;
    int best_val;
    Move best_move;
    int sv;

    g_info.nodes++;
    if (g_node_budget && g_info.nodes >= g_node_budget) { g_stop = 1; return 0; }
    if (g_stop) return 0;

    if (ply > 0 && (is_repetition(b->hash) || b->halfmove >= 100))
        return 0;

#if CREF_EGTB
    /* Endgame tablebase: exact value for covered 3-man positions. acc_phase<=4 is the
     * cheap gate (covered combos: Q=4,R=2,P=0); the root (ply 0) is searched normally
     * so it returns a move -- its children's TB scores guide the choice. */
    if (ply > 0 && b->acc_phase <= 4) {
        int eg_sc;
        if (egtb_probe(b, ply, &eg_sc)) return eg_sc;
    }
#endif

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

    if (depth <= 0) {
        /* Quiescence never reads b->hash (no TT probe, no repetition check), so
         * make_move can skip the zobrist update for the whole quiescence subtree.
         * The board is net-restored on return, leaving b->hash == this node's
         * hash. Save/restore the flag so nested calls stay correct. */
        int qv, saved = g_make_hash;
        g_make_hash = 0;
        qv = quiesce(b, alpha, beta, ply, 0);
        g_make_hash = saved;
        return qv;
    }

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

    /* Pool full -> static-eval leaf rather than overflow. Vanishingly rare. */
    if (!POOL_ROOM) return eval_stm(b);
    list = g_pool + g_pool_top;
    n = gen_legal(b, list);
    if (n == 0) return in_check(b) ? -MATE_SCORE + ply : 0;   /* nothing reserved */
#if CREF_LAZY_SELECT
    scores = g_score_pool + g_pool_top;        /* parallel slice, same base as list */
    score_moves(b, list, scores, n, tt_move, ply, g_sc.see_order);   /* score only; sort lazily below */
#else
    /* Eager: sort the whole list in place now (uses the transient g_score scratch).
     * Bit-exact with lazy selection -- same first-on-ties selection order -- it just
     * does all the picks up front instead of on demand, trading a little speed for
     * the ~POOL_SIZE*2 bytes the parallel score pool would cost. */
    scores = g_score_pool;
    order_moves(b, list, n, tt_move, ply, g_sc.see_order);
#endif

    best_val = -SEARCH_INF;
    best_move = list[0];
    pool_base = g_pool_top;
    g_pool_top += n;                   /* reserve this node's list for its loop */
    if (g_pool_top > g_pool_hw) g_pool_hw = g_pool_top;
    rep[rep_top++] = b->hash;          /* current node is an ancestor for children */
    for (i = 0; i < n; i++) {
        Undo u;
        int val, nd, gives_check, is_quiet;
        /* Lazy selection: bring the next-best move to position i on demand. A
         * node that beta-cuts early never sorts the moves it won't search.
         * (Eager profiles already fully sorted list[] above -- skip per-move pick.) */
#if CREF_LAZY_SELECT
        pick_best(list, scores, n, i);
#endif
        if (i == 0) best_move = list[0];   /* match eager sort's default best */
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
    g_pool_top = pool_base;            /* free this node's move list */

    sv = best_val;            /* store mate scores relative to THIS node's ply */
    if (sv > MATE_THRESHOLD) sv += ply;
    else if (sv < -MATE_THRESHOLD) sv -= ply;
    e->key = b->hash;
    e->value = sv;
    e->best = best_move;
    e->depth = depth;
    e->flag = (best_val <= alpha_orig) ? TT_UPPER :
              (best_val >= beta)       ? TT_LOWER : TT_EXACT;
#if CREF_TT_XRAM
    tt_xram_store(tt_idx, e);   /* flush this node's entry back to XRAM */
#endif
    return best_val;
}

Move search_bestmove(const Board *b, int depth,
                     const hash_t *hist, int hist_len, SearchInfo *out) {
    Board work;
    Move best = {0, 0, 0, 0};
    int best_score = 0;
    int d;

#if CREF_TT_XRAM
    tt_xram_clear();
#else
    memset(tt, 0, sizeof(tt));
#endif
    memset(&g_info, 0, sizeof(g_info));
    g_info.depth = depth;

    rep_base = 0;
    if (hist && hist_len > 0) {
        if (hist_len > MAX_PATH) hist_len = MAX_PATH;
        memcpy(rep, hist, hist_len * sizeof(hash_t));
        rep_base = hist_len;
    }

    work = *b;
    eval_acc_init(&work);   /* seed incremental material+PST under the live g_w */
    g_stop = 0;
    g_pool_top = 0; g_pool_hw = 0;
    if (g_sc.killers) memset(g_killer, 0, sizeof(g_killer));
    if (g_sc.history) memset(g_history, 0, sizeof(g_history));

    {   /* fallback: first legal move, in case the node budget aborts iteration 1 */
        int nn = gen_legal(&work, g_pool);   /* transient; top still 0 */
        if (nn > 0) best = g_pool[0];
    }

    /* iterative deepening for better ordering via the TT */
    for (d = 1; d <= depth; d++) {
        int alpha = -SEARCH_INF, beta = SEARCH_INF;
        Move *list = g_pool;          /* root list at the pool base */
        int n, i;
        Move prev;
        int local_best;
        Move local_move;
        rep_top = rep_base;
        g_pool_top = 0;
        n = gen_legal(&work, list);
        if (n == 0) break;
        prev = best;
        order_moves(&work, list, n, prev, 0, g_sc.see_order);
        g_pool_top = n;               /* reserve the root list for the root loop */
        if (g_pool_top > g_pool_hw) g_pool_hw = g_pool_top;
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
    g_info.pool_hw = g_pool_hw;
    if (out) *out = g_info;
    return best;
}
