/* test_see.c -- static exchange evaluation (SEE) unit tests.
 *
 * see(b, m) returns the net material swing (centipawns, SEE values
 * P=100 N=B=300 R=500 Q=900) of the capture on m.to, assuming both sides
 * recapture with their least-valuable attacker (X-rays included). Used by
 * quiescence to prune losing captures (see < 0) and to order them.
 */
#include "board.h"
#include "movegen.h"
#include <stdio.h>
#include <string.h>

static int failures = 0;
#define CHECK(got, want, msg) do { \
    if ((got) != (want)) { printf("FAIL: %s (got %d, want %d)\n", msg, (got), (want)); failures++; } \
    else { printf("ok: %s = %d\n", msg, (got)); } \
} while (0)

static int see_uci(const char *fen, const char *uci) {
    Board b; Move m;
    if (board_from_fen(&b, fen)) { printf("ERR fen %s\n", fen); failures++; return -99999; }
    if (move_from_uci(&b, uci, &m)) { printf("ERR uci %s\n", uci); failures++; return -99999; }
    return see(&b, m);
}

int main(void) {
    /* 1. PxQ, queen undefended -> win the queen (+900). */
    CHECK(see_uci("7k/8/8/3q4/2P5/8/8/7K w - - 0 1", "c4d5"), 900,
          "PxQ undefended");

    /* 2. PxN, knight undefended -> win the knight (+300). */
    CHECK(see_uci("7k/8/8/3n4/2P5/8/8/7K w - - 0 1", "c4d5"), 300,
          "PxN undefended");

    /* 3. QxP, pawn defended by a pawn -> lose the queen for a pawn (100-900). */
    CHECK(see_uci("7k/8/4p3/3p4/8/8/Q7/7K w - - 0 1", "a2d5"), -800,
          "QxP defended by pawn");

    /* 4. RxR, rook defended by a rook -> even trade (0). */
    CHECK(see_uci("7k/8/3r4/3r4/3R4/8/8/7K w - - 0 1", "d4d5"), 0,
          "RxR defended by rook");

    /* 5. X-ray battery: white doubled rooks (Rd4 front, Rd1 behind) vs a black
     * pawn d5 defended by a single Rd8. Rxd5(+100), Rxd5(-500), Rxd5 via the
     * Rd1 X-ray through the now-empty d4 (+500), black out of defenders -> the
     * battery wins the pawn: net +100. */
    CHECK(see_uci("3r3k/8/8/3p4/3R4/8/8/3R3K w - - 0 1", "d4d5"), 100,
          "X-ray battery wins a defended pawn");

    if (failures) { printf("%d SEE failure(s)\n", failures); return 1; }
    printf("all SEE tests passed\n");
    return 0;
}
