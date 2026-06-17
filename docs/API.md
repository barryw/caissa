# Engine ↔ UI API

A chess UI talks to the engine through **one header, `src/caissa.h`** (implemented
in `src/caissa.c`). It is a thin facade over `board`/`movegen`/`search`/`eval`: the
UI sets up a position, queries state + legal moves, asks the engine to move,
commits real moves (with draw rules tracked), takes moves back, and ponders — all
without touching engine internals or maintaining its own bookkeeping.

Link it by compiling `src/caissa.c` together with the engine
(`board.c movegen.c eval.c search.c`) and `-Isrc`. Working example: `test/test_api.c`
(run via `make verify`). A non-C / cross-toolchain UI can instead embed the
fixed-address blob in `apps/c64/caissa_abi.c`.

## Lifecycle
```c
#include "caissa.h"

caissa_init();                       /* once at startup: baseline weights + tables */

CaissaGame g;
caissa_new_game(&g, NULL);           /* NULL = standard start; or pass a FEN */

/* game loop */
for (;;) {
    CaissaState st = caissa_state(&g);
    if (st >= CAISSA_CHECKMATE) break;   /* mate or any draw -> game over */

    Move ml[256];
    int n = caissa_legal_moves(&g, ml, 256);   /* show/validate the side's moves */

    Move m;
    if (caissa_side_to_move(&g) == /*human*/ 1) {
        caissa_move_from_uci(&g, "e2e4", &m);  /* or pick from ml[] */
    } else {
        m = caissa_bestmove(&g, /*depth*/ 4, NULL);
    }
    caissa_commit(&g, m);                /* applies move + clocks + history */
}
```

## States — `caissa_state(&g)` → `CaissaState`
| value | meaning |
|---|---|
| `CAISSA_NORMAL` | game continues, side to move not in check |
| `CAISSA_CHECK` | game continues, side to move in check |
| `CAISSA_CHECKMATE` | side to move is mated (it **lost**) |
| `CAISSA_STALEMATE` | draw — no legal move, not in check |
| `CAISSA_DRAW_50MOVE` | draw — 100 half-moves without a pawn move/capture |
| `CAISSA_DRAW_REPETITION` | draw — current position occurred 3 times |
| `CAISSA_DRAW_INSUFFICIENT` | draw — neither side has mating material |

## Functions
| function | purpose |
|---|---|
| `caissa_init()` | one-time: load baseline eval weights + tables + default search config |
| `caissa_new_game(&g, fen)` | start a game (`fen` NULL = start position); 0 ok, −1 bad FEN |
| `caissa_side_to_move(&g)` | 1 = white, 0 = black |
| `caissa_legal_moves(&g, out, max)` | fill `out` with legal moves, return the count |
| `caissa_is_legal(&g, m)` | 1 / 0 |
| `caissa_state(&g)` | classify the position (table above) |
| `caissa_eval(&g)` | static eval, white-POV centipawns |
| `caissa_board(&g)` | `const Board*` — read `.sq[]` (0x88) to render |
| `caissa_to_fen(&g, out)` | write FEN (`out` ≥ 90 bytes) |
| `caissa_move_from_uci(&g, "e2e4", &m)` | parse a UCI move for the current position; 0 ok |
| `caissa_move_to_uci(m, out)` | write a move as UCI (`out` ≥ 6) |
| `caissa_bestmove(&g, depth, info)` | the engine's move (repetition-aware); `info` may be NULL |
| `caissa_commit(&g, m)` | apply a real move + advance clocks/history; 0 ok, −1 illegal/full |
| `caissa_undo(&g)` | take back the last committed move; 0 ok, −1 at root |
| `caissa_ponder(&g, predicted, depth)` | cache our reply assuming the opponent plays `predicted`; 0 ok, −1 illegal |
| `caissa_ponder_hit(&g, actual, &reply)` | if `actual` == prediction, set `reply` (legal for the new position) and return 1; else 0 → run `caissa_bestmove` |

## Pondering (think on the opponent's clock)
After you move, while the opponent thinks, guess their reply and pre-compute yours:
```c
caissa_commit(&g, my_move);
caissa_ponder(&g, predicted_opponent_move, depth);   /* cached in the background */
/* ... opponent actually plays `actual` ... */
caissa_commit(&g, actual);
Move reply;
if (caissa_ponder_hit(&g, actual, &reply))   m = reply;          /* cache hit: instant */
else                                          m = caissa_bestmove(&g, depth, NULL);
caissa_commit(&g, m);
```

## Tuning the eval
`eval.c`'s weights live in the global `EvalWeights g_w`. Override fields then call
`eval_sync_tables()` to rebuild derived tables; `eval_reset_weights()` restores the
baseline. The A/B self-play harness (`apps/cli/cref selfplay`) uses this to compare
weight sets. See `src/eval.h`.
