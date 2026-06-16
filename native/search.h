/* search.h -- negamax/alpha-beta/quiescence/TT/MVV-LVA reference search. */
#ifndef CREF_SEARCH_H
#define CREF_SEARCH_H

#include "board.h"
#include "memcfg.h"

/* repetition stack: game history + search depth. Sized per memory profile
 * (memcfg.h): the host keeps a generous 1024 (full game history); a bare 6502
 * build only ever searches from a single position with no game history
 * (hist=NULL), so the stack just holds the search path (<= MAX_PLY) -- 64 is
 * ample and saves ~3.8KB of bss. */
#define MAX_PATH       CREF_MAX_PATH
#define MATE_SCORE     30000
#define MATE_THRESHOLD 29000
#define SEARCH_INF     32000

typedef struct {
    hash_t nodes, qnodes, tt_hits;
    int depth, score;
    int pool_hw;            /* peak shared-move-pool occupancy (Move entries) */
    Move best;
} SearchInfo;

/* Search-feature toggles (the A/B knobs, analogous to EvalWeights). Defaults
 * (search_reset_config) reproduce the baseline search exactly, so an all-default
 * A vs B self-play is 50%. Each feature is measured by flipping one toggle. */
typedef struct {
    int killers;     /* killer-move ordering */
    int history;     /* history-heuristic ordering */
    int nullmove;    /* null-move pruning */
    int null_r;      /* null-move reduction (default 2) */
    int pvs;         /* principal variation search */
    int aspiration;  /* aspiration windows at the root */
    int asp_delta;   /* aspiration half-window (default 50) */
    int check_ext;   /* extend search by 1 ply when in check */
    int lmr;         /* late-move reductions */
} SearchConfig;

extern SearchConfig g_sc;
void search_reset_config(void);     /* baseline defaults */
void search_set_budget(long nodes); /* node budget for iterative deepening; 0 = unlimited */

/* Repetition/50-move context: `hist` holds the zobrist hashes of every position
 * already played in the game (root included), length `hist_len`. The search adds
 * its own path on top so a position repeated within the search or vs the game
 * counts as a draw. Pass hist=NULL,hist_len=0 for a context-free search. */
Move search_bestmove(const Board *b, int depth,
                     const hash_t *hist, int hist_len, SearchInfo *out);

#endif
