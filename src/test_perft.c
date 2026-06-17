/* test_perft.c -- isolated movegen verification driver.
 *   ./test_perft "<FEN>" <depth>   ->  prints the perft node count.
 * Compared against python-chess by tools/native_perft_check.py.
 */
#include "board.h"
#include "movegen.h"
#include <stdio.h>
#include <stdlib.h>

/* Host-only perft (verification). Uses a stack-local move list per frame -- fine
 * on the host; the cc65 engine never compiles this file. */
hash_t perft(Board *b, int depth) {
    Move list[MAX_MOVES];
    int n, i;
    hash_t total = 0;
    if (depth == 0) return 1;
    n = gen_legal(b, list);
    if (depth == 1) return (hash_t)n;
    for (i = 0; i < n; i++) {
        Undo u;
        make_move(b, list[i], &u);
        total += perft(b, depth - 1);
        unmake_move(b, list[i], &u);
    }
    return total;
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s FEN depth\n", argv[0]); return 2; }
    Board b;
    if (board_from_fen(&b, argv[1])) { fprintf(stderr, "bad fen\n"); return 2; }
    int depth = atoi(argv[2]);
    printf("%llu\n", (unsigned long long)perft(&b, depth));
    return 0;
}
