# Architecture

Caïssa is **one chess engine**, written in portable C, that runs on the host and
compiles down to the 6502 (Commodore 64) via llvm-mos with hand-written 6502
assembly for the hot paths. This document is the canonical map of what lives
where and how the pieces fit. (Until mid-2026 the repo carried a second,
hand-written ca65 engine in `src/`; it was removed and the C engine — formerly
`native/` — became the sole `src/`.)

## The engine (`src/`)
- `board.c` / `board.h` — 0x88 board, FEN, make/unmake, Zobrist hashing, the
  incremental material+PST accumulators.
- `movegen.c` / `movegen.h` — 0x88 pseudo/legal move generation + attack detection.
- `eval.c` / `eval.h` — full positional evaluation (40+ tunable weights in `g_w`),
  Texel-tuned, **bit-exact to `test/texel_eval.py`** (the python oracle).
- `search.c` / `search.h` — alpha-beta + quiescence, transposition table, move
  ordering (TT move, MVV-LVA, killers), null-move, LMR.
- `*_6502.s` — hand-written 6502 assembly replacements for the hottest functions
  (`is_square_attacked`, `gen_pseudo`, `gen_legal`, `make_move`, `unmake_move`,
  and the monolithic `eval_full`). Each is gated by a `-DCREF_ASM_*` macro: the
  host build uses the C body (the oracle); the 6502 builds define the macro,
  `#ifdef` out the C, and link the asm. The asm is proven **bit-identical** to the
  C by the gate (move-for-move == host, eval 22157/22157).

## Public engine↔UI API (`src/caissa.h` / `src/caissa.c`)
The single header a UI uses to run a whole game: `caissa_new_game`, `caissa_state`
(mate/stalemate/draw classification), `caissa_legal_moves`, `caissa_bestmove`,
`caissa_commit`/`caissa_undo` (committed-game flow with 50-move/threefold/
insufficient-material + take-back), and `caissa_ponder`/`caissa_ponder_hit`. A thin
facade over the engine — the UI never touches internals. Full reference: `docs/API.md`;
test: `test/test_api.c`. Cross-toolchain embedding: `apps/c64/caissa_abi.c`.

## Front-ends (`apps/`)
- `apps/cli/cref.c` — host CLI: `cref bestmove "FEN" [depth]`, `cref selfplay`
  (reference-vs-reference A/B with per-side eval-weight overrides). The dev driver,
  eval oracle, and Stockfish measuring stick. Built to `build/cref`.
- `apps/c64/c64chess.c` — the playable C64 game (text UI over KERNAL stdio) →
  `chess.prg` via `tools/build_c64.sh`. Same engine, depth-limited for 1MHz.
- `apps/c64/caissa_abi.c` — fixed-address ABI blob so an external pure-asm host
  can embed and call the engine across toolchains.

## Tests + oracle (`test/`)
- `test_perft.c` / `test_eval.c` — host unit tests (built to `build/`).
- `texel_eval.py` — the python evaluation **oracle**; `eval.c` is held bit-exact to it.
- `native_perft_check.py` / `native_eval_check.py` — run the host binaries vs the
  oracle (`make verify`). `eval_corpus_check.py` — runs the 6502-compiled eval over
  the 22k corpus and diffs vs the oracle.

## Build + measurement (`tools/`)
- `tools/build_c64.sh` — build the C64 `chess.prg` (llvm-mos `mos-c64-clang` + asm).
- `tools/llvmmos_bench/` — the 6502 build + fidelity/speed rig:
  - `build_caissa.sh` — compile the C engine to a mos-sim 6502 image
    (`caissa.sim`) with the asm hot paths; validate move-for-move vs the
    matched-config host oracle (`/tmp/cref_mos`).
  - `speed_gate.sh` (`make gate`) — the regression gate: PERFT EXACT, eval
    22157/22157, golden search moves, 6502 image == host, and reports cyc/move.
  - `validate.c` / `eval_validate.c` — host runners that drive the 6502 image
    (FEN→move / FEN→eval) inside the cycle-exact core.
- `tools/fast6502_bridge/cpu6502.c` — the cycle-exact 6502 CPU core shared by all
  the host-side 6502 runners.
- Colossus match harness — drives the real Colossus 4.0 inside a **headless VICE**
  core (accurate by construction; built from `~/Git/vice-macos`, `--enable-headlessui`)
  and plays it against the engine. See `docs/colossus.md`.
- Tuning/research — `texel_tune.py`, `term_tune.py`, `run_reference_match.py`
  (python reference-engine A/B), `native_vs_stockfish.py` (host vs Stockfish Elo).

## Data (`data/`)
Static assets: `opening_repertoire.json` (book source), opening suites
(`openings_big.txt`, `selfplay_openings.txt`, `stockfish_opening_fens.txt`), and
strength corpora.

## Build outputs (`build/`)
Host binaries (`cref`, `cref_mos`, `test_*`) plus generated data. **Also holds
irreplaceable assets** (`build/colossus_extract/` — the extracted Colossus runtime).
**Never `rm -rf build/`**; `make clean` only removes the specific binaries.

## Strength + the frontier
The engine's *moves* are ~1800-grade on-chip (measured direct vs Stockfish), but
on a real 1MHz C64 it is **speed-limited** — deep search costs too much time, so
its strength at a real time control is lower. The active work: (1) make the 6502
faster (hand-asm hot paths — eval_full just landed −12.3% cyc/move) so more depth
fits in the time budget, and (2) stand up the headless-VICE Colossus harness to
measure + tune the engine against Colossus at a fair per-move cycle budget.
