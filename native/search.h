/* search.h -- negamax/alpha-beta/quiescence/TT/MVV-LVA reference search. */
#ifndef CREF_SEARCH_H
#define CREF_SEARCH_H

#include "board.h"

#define MAX_PATH       1024   /* repetition stack: game history + search depth */
#define MATE_SCORE     30000
#define MATE_THRESHOLD 29000
#define SEARCH_INF     32000

typedef struct {
    uint64_t nodes, qnodes, tt_hits;
    int depth, score;
    Move best;
} SearchInfo;

/* Repetition/50-move context: `hist` holds the zobrist hashes of every position
 * already played in the game (root included), length `hist_len`. The search adds
 * its own path on top so a position repeated within the search or vs the game
 * counts as a draw. Pass hist=NULL,hist_len=0 for a context-free search. */
Move search_bestmove(const Board *b, int depth,
                     const uint64_t *hist, int hist_len, SearchInfo *out);

#endif
