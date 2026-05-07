# chess6502-engine

Reusable 6502 chess engine extracted from the C64 Chess project and ported to ca65.
The repo builds a headless C64-style PRG for simulator tests without requiring the
original application UI.

## Build And Test

```sh
make engine-build
make test
```

`make test` uses the latest Sim6502 Docker image by default:
`ghcr.io/barryw/sim6502:latest` with `SIM6502_PULL=always`.
Override `CA65` and `LD65` if cc65 is installed somewhere other than
`/Users/barry/Git/cc65/bin`.

## Import Pattern

Host programs should define placement knobs, include shared constants, include
a platform adapter that provides the required hooks, then include the engine:

```asm
ENGINE_FIXED_PST = 0
ENGINE_TT_BASE = $C800  ; choose host RAM for the 2KB transposition table
.include "constants.s"
.include "engine/platform_test.s"  ; replace with your platform adapter
.include "engine/engine.s"
```

For ca65, code and data placement belongs in linker configs. The shared engine emits normal `CODE` by default and emits a separate `PST` segment when `ENGINE_FIXED_PST` is nonzero; host linker configs can place that segment wherever they need it. The transposition table is not emitted into the PRG, so hosts provide 2KB of writable RAM through `ENGINE_TT_BASE`.

The current engine still has a zero-page ABI for speed. Reserve `$02-$37` and `$e0-$fe` for the engine unless you do a coordinated zero-page remap pass.

## Required Platform Hooks

`EngineStartSearchTimer`

Called once by `FindBestMove` after `TimeBudgetLo`, `TimeBudgetHi`, and
`MaxSearchDepth` are initialized. Initialize the host's deadline/timer source and
return without mutating board, move-list, castling, king-square, or search-result
state.

`EngineCheckTime`

Called before each iterative-deepening pass. Return carry clear to continue, or
carry set to stop and use the best completed move. Set `TimeUp` to `$01` when
returning carry set. A host without timing can always `clc`/`rts`.

`EngineOnSearchIteration`

Called after each completed root search depth. Inputs include `IterDepth`,
`IterScore`, `BestMoveFrom`, and `BestMoveTo`. Use it for UI/progress updates or
just `rts` in a headless host.

`EngineLookupOpeningMove`

Called after `ComputeZobristHash` when search may use an opening book. Return
carry set with `A = from-square` and `Y = to-square` in 0x88 coordinates, or carry
clear when no book move exists.

`EngineBookMoveAvoidsPawnAttack`

Called after a book candidate is copied to `BestMoveFrom/BestMoveTo` and verified
as legal. Return carry set to accept it or carry clear to reject it and fall back
to search.

## Public API

External hosts should prefer these labels from `src/engine/api.s`:

- `ChessInitPieceLists`
- `ChessGenerateLegalMoves`
- `ChessFindBestMove`
- `ChessMakeMove`
- `ChessUnmakeMove`
- `ChessIsSquareAttacked`
- `ChessCheckKingInCheck`

`src/engine/state.s` owns board and rule state such as `Board88`, `currentplayer`,
`difficulty`, king squares, castling rights, en passant state, draw/repetition
state, move indexes, promotion state, and piece lists. Renderers should read
`Board88` and map piece IDs to their own graphics; display state should stay out
of the engine.
