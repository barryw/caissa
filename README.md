# Caïssa

A 6502 chess engine for the Commodore 64 (and other 6502 hosts). The repo holds
**two engine codebases** that share the same chess logic and a bit-exact
evaluation, plus the harnesses that build, test, and strength-measure them.

## The two engines

### `native/` — C reference engine (the active line)

Portable C (`board.c`, `movegen.c`, `eval.c`, `search.c`) that is both the
evaluation source-of-truth and the engine shipped to the C64:

- **`cref`** — native CLI: `cref bestmove "FEN" [depth]` and `cref selfplay`
  (reference-vs-reference A/B). Built with `make` in `native/`. Used as the eval
  oracle and the measuring stick against Stockfish.
- **`chess.prg`** — a playable C64 game (text UI in `native/c64chess.c`),
  compiled with **llvm-mos** plus hand-written 6502 overrides for the hot paths
  (`is_square_attacked`, `make_move`, `unmake_move`). Build it with
  `./tools/build_c64.sh`, then `x64sc chess.prg` and type moves like `e2e4`.
- **`caissa_abi.c`** — fixed-address ABI blob so the pure-assembly C64 game in
  `~/Git/Chess` can embed and call this engine across toolchains.

```sh
cd native && make            # build cref
cd native && make verify     # perft vs python-chess + eval bit-exact vs texel
./tools/build_c64.sh         # build the playable chess.prg
```

### `src/` — ca65 hand-assembled 6502 engine (reusable library)

The original hand-written ca65 engine, structured as a reusable, host-portable
library with a documented import API (see **Import Pattern** / **Public API**
below). It builds a headless `engine_harness.prg` that the deterministic sim
tests and the Stockfish/Elo harness drive.

```sh
make engine-build
make test
make benchmark
make size
```

`make test` uses the latest Sim6502 Docker image by default
(`ghcr.io/barryw/sim6502:latest`, `SIM6502_PULL=always`). Override `CA65` and
`LD65` if cc65 lives somewhere other than `/Users/barry/Git/cc65/bin`.

## Strength harness

The Stockfish strength/game/Elo harness lives in `tools/` and runs against the
headless ca65 binary (`build/engine_harness.prg` + `build/engine_harness.sym`):

```sh
make stockfish-strength
make stockfish-games
make stockfish-elo
```

The default backend is the persistent sim6502 bridge (avoids restarting a
simulator per move). It needs `dotnet`, `python-chess`, Stockfish on `PATH` or
`STOCKFISH_PATH`, and a built Sim6502 runner; override `SIM6502_OUTPUT_DIR` when
it is not at `~/Git/sim6502/sim6502/bin/Release/net10.0`. Generated JSON/PGN goes
under `build/`.

Useful knobs:

- `STRENGTH_JOBS=4` parallelizes corpus probes.
- `STOCKFISH_JOBS=4` parallelizes Elo ladder games.
- `STOCKFISH_DEPTH=10` raises strength-probe analysis depth.
- `STOCKFISH_ELOS=1320,1520,1720` chooses Elo ladder anchors.
- `STOCKFISH_BACKEND=docker` uses the Docker simulator instead of the bridge.

The `colossus-*` Makefile targets drive a clean-room study of the Colossus C64
engine (ideas only, never code) and are documented in `docs/colossus.md`.

## Repo layout

| Path      | What |
|-----------|------|
| `native/` | C reference engine, C64 game, ABI blob, hand-asm 6502 overrides |
| `src/`    | ca65 hand-assembled reusable 6502 engine + platform adapters |
| `tests/`  | sim6502 deterministic test harnesses (`*.6502`, `*.s`) |
| `tools/`  | build, opening-book, Texel tuning, Stockfish/Elo, and research scripts |
| `docs/`   | performance, opening-book, fast-iteration, and relocation notes |
| `cfg/`    | ca65 linker config |

Performance tracking is documented in `docs/performance.md`.

---

## (ca65 engine) Import Pattern

Host programs define placement knobs, include shared constants, include a
platform adapter that provides the required hooks, then include the engine:

```asm
ENGINE_FIXED_PST = 0
ENGINE_TT_BASE = $C800  ; choose host RAM for the transposition table
; TT_SIZE = 256         ; optional: override entry count (power of two,
                        ; multiple of 256). Default 256 entries (2KB).
.include "constants.s"
.include "engine/platform_test.s"  ; replace with your platform adapter
.include "engine/engine.s"
```

For ca65, code and data placement belongs in linker configs. The shared engine
emits normal `CODE` by default and emits a separate `PST` segment when
`ENGINE_FIXED_PST` is nonzero; host linker configs can place that segment
wherever they need it. The transposition table is not emitted into the PRG, so
hosts provide `TT_SIZE * TT_ENTRY_SIZE` bytes (TT_ENTRY_SIZE is 8) of writable
RAM through `ENGINE_TT_BASE`. **Both `TT_SIZE` and `ENGINE_TT_BASE` are
host-overridable.** The default is 256 entries (2KB) to fit C64-era hosts
unchanged; a host with more RAM (the headless build uses 2048 entries / 16KB)
gets a stronger search by enlarging it. A bigger table never changes
correctness — it only raises the transposition hit rate; if you grow it, grow
the RAM region you reserve at `ENGINE_TT_BASE` to match.

The current engine still has a zero-page ABI for speed. Reserve `$02-$37` and
`$e0-$fe` for the engine unless you do a coordinated zero-page remap pass.

## (ca65 engine) Required Platform Hooks

`EngineStartSearchTimer` — called once by `FindBestMove` after `TimeBudgetLo`,
`TimeBudgetHi`, and `MaxSearchDepth` are initialized. Initialize the host's
deadline/timer source and return without mutating board, move-list, castling,
king-square, or search-result state.

`EngineCheckTime` — called before each iterative-deepening pass. Return carry
clear to continue, or carry set to stop and use the best completed move. Set
`TimeUp` to `$01` when returning carry set. A host without timing can always
`clc`/`rts`.

`EngineOnSearchIteration` — called after each completed root search depth.
Inputs include `IterDepth`, `IterScore`, `BestMoveFrom`, and `BestMoveTo`. Use
it for UI/progress updates or just `rts` in a headless host.

`EngineLookupOpeningMove` — called after `ComputeZobristHash` when search may use
an opening book. Return carry set with `A = from-square` and `Y = to-square` in
0x88 coordinates, or carry clear when no book move exists.

`EngineBookMoveAvoidsPawnAttack` — called after a book candidate is copied to
`BestMoveFrom/BestMoveTo` and verified as legal. Return carry set to accept it or
carry clear to reject it and fall back to search.

## (ca65 engine) Public API

External hosts should prefer these labels from `src/engine/api.s`. The
rules-only build entry point is `src/engine/rules_engine.s`; the full engine
entry point remains `src/engine/engine.s`.

- `ChessInitPieceLists`
- `ChessGenerateLegalMoves`
- `ChessMakeMove`
- `ChessBeginGame`
- `ChessCommitMove`
- `ChessUnmakeMove`
- `ChessIsSquareAttacked`
- `ChessCheckKingInCheck`
- `ChessCheckGameState`
- `ChessRecordPosition`
- `ChessClearPositionHistory`
- `ChessCheckRepetition`

The full engine build also exports the local AI/search API:

- `ChessFindBestMove`
- `ChessPonderClear`
- `ChessPonderSearch`
- `ChessPonderUse`

`src/engine/state.s` owns board and rule state such as `Board88`,
`currentplayer`, `difficulty`, king squares, castling rights, en passant state,
draw/repetition state, and piece lists. Renderers should read `Board88` and map
piece IDs to their own graphics; display state should stay out of the engine.

Hosts should call `ChessBeginGame` after setting up `Board88`, `currentplayer`,
castling rights, en passant state, and king squares for a new game. It
initializes the piece lists, clears draw clocks/history, resets the fullmove
number, and records the initial position. Hosts should then use `ChessCommitMove`
for real game moves. It applies the move, advances `currentplayer`, updates the
halfmove clock and fullmove number, records the new position, and returns the
latest `EngineGameState`.

`ChessMakeMove` and `ChessUnmakeMove` remain low-level board/search primitives.
They do not update committed-game draw clocks or repetition history.
`ChessRecordPosition`, `ChessClearPositionHistory`, and `ChessCheckRepetition`
are exposed for low-level harnesses and unusual host workflows, but normal
clients should not need them. These APIs initialize the Zobrist tables on
demand, so repetition detection does not depend on platform startup order. The
search also remembers the last returned engine move so it can avoid immediate
quiet reversals even before a host wires full position history.

Hosts that have idle time while the opponent is thinking can use the ponder
cache. Call `ChessPonderSearch` with `A = predicted-from` and `X = predicted-to`
for a legal opponent move in 0x88 coordinates. The routine temporarily makes
that move, searches a reply, restores the board, side to move, search depth,
game state, and previously published best move, and returns carry set if
`PonderReplyFrom/PonderReplyTo` are valid. After the opponent actually moves,
call `ChessPonderUse` with the actual from/to. Carry set means
`BestMoveFrom/BestMoveTo` now contain the cached reply; carry clear means the
prediction missed and the host should run `ChessFindBestMove` normally.
`ChessPonderClear` invalidates any cached prediction.

`ChessCheckGameState` returns one of the `GAME_*` constants and stores the same
value in `EngineGameState`: normal, check, checkmate, stalemate, 50-move claim
available, threefold-repetition claim available, insufficient-material draw,
75-move automatic draw, or fivefold-repetition automatic draw.
`ChessFindBestMove` updates `EngineGameState` before searching and returns no
move (`$ff/$ff`) for terminal checkmate, stalemate, or draw states.
