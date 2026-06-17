# Caïssa

A chess engine for the Commodore 64 (and other 6502 hosts). It is **one engine**:
portable C that runs on the host (development, eval oracle, measuring stick) and
compiles down to the 6502 with **llvm-mos**, with hand-written 6502 assembly for
the hot paths. The same C is the shipped C64 program.

> Historical note: this repo used to carry **two** engines (a hand-written ca65
> asm engine in `src/` and a C engine in `native/`). They were converged in 2026:
> the C engine is now the sole `src/`; the old ca65 engine was removed. If you see
> stale references to `native/` or `engine_harness`, they predate the merge.

## Layout
| Path | What |
|---|---|
| `src/` | **THE engine** — `board/movegen/eval/search` (C) + 6502 hand-asm hot-path overrides (`*_6502.s`, incl. the monolithic `eval_full_6502.s`), gated by `-DCREF_ASM_*` |
| `apps/cli/` | `cref` host CLI — `bestmove`, `selfplay` (reference-vs-reference A/B) |
| `apps/c64/` | the playable C64 game (`c64chess.c` → `chess.prg`) + `caissa_abi.c` (ABI blob for embedding) |
| `test/` | host unit tests (`test_perft`, `test_eval`) + the python eval oracle (`texel_eval.py`) + bit-exact checkers |
| `tools/` | build scripts, the cycle-exact 6502 sim (`fast6502_bridge/cpu6502.c`), the speed gate, and the Colossus/Stockfish measurement harnesses |
| `data/` | static assets: opening repertoire, opening suites, texel/strength corpora |
| `docs/` | architecture (`ARCHITECTURE.md`) + campaign notes |
| `build/` | build outputs **and irreplaceable assets** (`build/colossus_extract`) — never `rm -rf build/` |

## Build & test
```sh
make            # build/cref  (host engine CLI)
make verify     # perft vs python-chess + eval bit-exact vs texel_eval (22157/22157)
make c64        # the playable chess.prg (llvm-mos + 6502 hand-asm); run: x64sc chess.prg
make gate       # full 6502 gate: fidelity (6502 moves == host) + speed (cyc/move)
```
Quick play: `build/cref bestmove "FEN" [depth]`.

## How it works
- **One C engine** (`src/`): 0x88 board, alpha-beta + quiescence search (transposition
  table, killers, null-move, LMR), and a Texel-tuned evaluation that is **bit-exact**
  to the python oracle (`test/texel_eval.py`), verified over a 22,157-position corpus.
- **6502 / C64**: compiled via llvm-mos; the hottest functions have hand-written 6502
  asm replacements (`src/*_6502.s`), gated by `-DCREF_ASM_*` and proven **bit-identical**
  to the C by the gate (move-for-move == the host engine).

## Strength — what is and isn't measured
- **Host (PC):** ~1785–1874 vs Stockfish at depth 6.
- **On-chip move quality:** ~1850 (direct, the real 6502 binary vs Stockfish, zero
  forfeits) — i.e. the *moves* are ~1800-grade.
- **On-chip at a real time control:** **speed-capped.** Depth 6 ≈ hours/move on a real
  1MHz C64, so the reachable depth (hence strength) at a sane clock is lower. Closing
  this is the open frontier — hence the ongoing speed work on the 6502 hot paths.
- **vs Colossus:** not yet measured. A headless-VICE Colossus match harness (see
  `docs/colossus.md`) is being built to get the at-time-control, vs-Colossus number,
  then tune the engine against it.

## Measurement harness
The 6502 build + fidelity/speed gate live in `tools/llvmmos_bench/` (`build_engine6502.sh`,
`speed_gate.sh`, the `validate` FEN→move runner). The Colossus match harness drives the
real Colossus 4.0 inside a **headless VICE** core (accurate by construction) and plays it
against the engine; `docs/colossus.md` has the details. (The legacy Stockfish strength/Elo
ladder tooling measured the old ca65 engine and is being repointed onto this engine.)

See `docs/ARCHITECTURE.md` for the full picture and `docs/performance.md` for the speed campaign.
