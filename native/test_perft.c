/* test_perft.c -- isolated movegen verification driver.
 *   ./test_perft "<FEN>" <depth>   ->  prints the perft node count.
 * Compared against python-chess by tools/native_perft_check.py.
 */
#include "board.h"
#include "movegen.h"
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s FEN depth\n", argv[0]); return 2; }
    Board b;
    if (board_from_fen(&b, argv[1])) { fprintf(stderr, "bad fen\n"); return 2; }
    int depth = atoi(argv[2]);
    printf("%llu\n", (unsigned long long)perft(&b, depth));
    return 0;
}
