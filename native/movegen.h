/* movegen.h -- legal move generation contract (implemented in movegen.c). */
#ifndef CREF_MOVEGEN_H
#define CREF_MOVEGEN_H

#include "board.h"
#include "memcfg.h"

#define MAX_MOVES CREF_MAX_MOVES

/* Is square `sq` (0x88) attacked by side `by_white` (1=white,0=black)? */
int is_square_attacked(const Board *b, int sq, int by_white);

/* Is the side to move currently in check? */
int in_check(const Board *b);

/* Generate all LEGAL moves into list[] (capacity MAX_MOVES). Returns count. */
int gen_legal(const Board *b, Move *list);

/* perft node count to `depth` (used to verify movegen vs python-chess).
 * Returns hash_t (>=32-bit) -- wide enough for the small depths we verify. */
hash_t perft(Board *b, int depth);

#endif
