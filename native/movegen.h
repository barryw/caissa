/* movegen.h -- legal move generation contract (implemented in movegen.c). */
#ifndef CREF_MOVEGEN_H
#define CREF_MOVEGEN_H

#include "board.h"

#define MAX_MOVES 256

/* Is square `sq` (0x88) attacked by side `by_white` (1=white,0=black)? */
int is_square_attacked(const Board *b, int sq, int by_white);

/* Is the side to move currently in check? */
int in_check(const Board *b);

/* Generate all LEGAL moves into list[] (capacity MAX_MOVES). Returns count. */
int gen_legal(const Board *b, Move *list);

/* perft node count to `depth` (used to verify movegen vs python-chess). */
uint64_t perft(Board *b, int depth);

#endif
