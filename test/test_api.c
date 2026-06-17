/* test_api.c -- exercises the public engine<->UI API (src/caissa.h). */
#include <stdio.h>
#include <string.h>
#include "caissa.h"
#include "movegen.h"

static int fails = 0;
#define CHECK(cond, msg) do { \
    if (cond) { printf("  [ok ] %s\n", msg); } \
    else { printf("  [FAIL] %s\n", msg); fails++; } } while (0)

/* commit a move given as uci; returns 0 on success */
static int play(CaissaGame *g, const char *uci) {
    Move m;
    if (caissa_move_from_uci(g, uci, &m) != 0) return -1;
    return caissa_commit(g, m);
}

int main(void) {
    CaissaGame g;
    Move ml[256];
    SearchInfo si;
    caissa_init();

    /* --- start position --- */
    CHECK(caissa_new_game(&g, NULL) == 0, "new_game(startpos)");
    CHECK(caissa_side_to_move(&g) == 1, "white to move at start");
    CHECK(caissa_legal_moves(&g, ml, 256) == 20, "20 legal moves at start");
    CHECK(caissa_state(&g) == CAISSA_NORMAL, "start state NORMAL");

    /* --- checkmate (fool's mate, white is mated) --- */
    CHECK(caissa_new_game(&g, "rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3") == 0, "new_game(fools-mate)");
    CHECK(caissa_state(&g) == CAISSA_CHECKMATE, "fool's mate -> CHECKMATE");

    /* --- stalemate (black to move, no legal move, not in check) --- */
    CHECK(caissa_new_game(&g, "k7/8/1Q6/8/8/8/8/K7 b - - 0 1") == 0, "new_game(stalemate)");
    CHECK(caissa_state(&g) == CAISSA_STALEMATE, "stalemate -> STALEMATE");

    /* --- insufficient material (K vs K) --- */
    CHECK(caissa_new_game(&g, "8/8/8/4k3/8/8/3K4/8 w - - 0 1") == 0, "new_game(KvK)");
    CHECK(caissa_state(&g) == CAISSA_DRAW_INSUFFICIENT, "KvK -> DRAW_INSUFFICIENT");

    /* --- commit + undo round-trip (board restored byte-for-byte) --- */
    caissa_new_game(&g, NULL);
    {
        Board before = g.board;
        CHECK(play(&g, "e2e4") == 0, "commit e2e4");
        CHECK(caissa_side_to_move(&g) == 0, "black to move after e4");
        CHECK(caissa_undo(&g) == 0, "undo e2e4");
        CHECK(memcmp(&before, &g.board, sizeof(Board)) == 0, "undo restores board exactly");
        CHECK(g.hist_len == 1, "undo restores history length");
    }

    /* --- illegal move rejected --- */
    caissa_new_game(&g, NULL);
    {
        Move m; m.from = 0x10; m.to = 0x40; m.promo = 0; m.flags = 0; /* a2a5: illegal */
        CHECK(caissa_commit(&g, m) == -1, "illegal move rejected by commit");
    }

    /* --- threefold repetition (shuffle knights back to the start position 3x) --- */
    caissa_new_game(&g, NULL);
    {
        const char *cyc[] = {"g1f3","g8f6","f3g1","f6g8"};
        int i, ok = 1;
        for (i = 0; i < 8; i++) if (play(&g, cyc[i % 4]) != 0) ok = 0;  /* two cycles */
        CHECK(ok, "play two knight-shuffle cycles");
        CHECK(caissa_state(&g) == CAISSA_DRAW_REPETITION, "start position 3x -> DRAW_REPETITION");
    }

    /* --- bestmove returns a legal move --- */
    caissa_new_game(&g, NULL);
    {
        Move best = caissa_bestmove(&g, 4, &si);
        CHECK(caissa_is_legal(&g, best), "bestmove(d4) is legal");
    }

    /* --- ponder: predict the engine reply, then confirm the hit --- */
    caissa_new_game(&g, NULL);
    {
        Move our, oppGuess, reply;
        char uci[6];
        our = caissa_bestmove(&g, 4, &si);
        caissa_commit(&g, our);
        /* guess the opponent's reply = what the engine would play, then ponder it */
        oppGuess = caissa_bestmove(&g, 4, &si);
        CHECK(caissa_ponder(&g, oppGuess, 4) == 0, "ponder(predicted) cached");
        /* opponent actually plays the guessed move */
        caissa_commit(&g, oppGuess);
        CHECK(caissa_ponder_hit(&g, oppGuess, &reply) == 1, "ponder hit on matching move");
        caissa_move_to_uci(reply, uci);
        CHECK(caissa_is_legal(&g, reply), "pondered reply is legal for the new position");
        (void)uci;
    }

    printf(fails ? "\nAPI TESTS: %d FAILED\n" : "\nAPI TESTS: all passed\n", fails);
    return fails ? 1 : 0;
}
