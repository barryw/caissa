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

## Engine ↔ UI API
A chess UI drives the engine through one header, **`src/caissa.h`** — set up a
position, query state + legal moves, ask for a move, commit real moves (with
50-move / threefold / insufficient-material rules tracked), take back, and ponder.
Full reference + examples in **`docs/API.md`**; working example in `test/test_api.c`
(`make verify` runs it). A cross-toolchain / non-C UI can embed the fixed-address
blob in `apps/c64/caissa_abi.c`.

## Strength — measured
Strength is **depth-bound, hence speed-bound**: the static eval is tapped at the
depths the chip reaches, so cycle wins (not eval terms) are the lever. Measured by
playing `cref_mos` — the reduced config the 6502 image runs, golden-verified
move-for-move identical to it — vs Stockfish (`tools/onchip_strength_vs_tc.py`):

| Depth | on-chip Elo | cyc/move | @1 MHz | @40 MHz (Ultimate) |
|------:|------------:|---------:|-------:|-------------------:|
| 1 | ~1256 | 11.0M | 11 s/move | 0.27 s/move |
| 2 | ~1461 | 31.7M | 32 s/move | 0.79 s/move |
| 3 | ~1605 | 102M | 102 s/move | 2.6 s/move |
| 4 | ~1753 | 321M | 321 s/move | 8.0 s/move |

- **Stock 1 MHz C64:** correspondence-class — depth 4 (~1753) ≈ 5 min/move; at human
  clocks it plays ~depth 1-2 (~1256-1461).
- **40 MHz C64 Ultimate / Ultimate 64 / Novu:** the same binary plays **depth 4
  (~1753) in ~8 s/move** — i.e. **~1750-1850 at normal time controls**, competitive
  with the strongest 8-bit engines (Colossus). The 40× hardware closes the gap that
  made 1800 correspondence-only on stock silicon.
- **Host (PC):** the full-config engine is ~1800 @ d4, ~1942 @ d6 vs Stockfish.

See `docs/performance.md` for the full speed/clock benchmark and
`docs/eval-rewrite-conclusion-and-goal-reframe.md` for why eval is tapped and speed
is the lever.

## Measurement harness
The 6502 build + cycle-exact fidelity/speed gate live in `tools/llvmmos_bench/`
(`build_caissa.sh`, `speed_gate.sh`, the `validate` FEN→move runner, the `caissa_prof`
profiler). Strength + clock benchmarks: `tools/onchip_strength_vs_tc.py`. A headless-VICE
Colossus 4.0 match harness (`docs/colossus.md`) plays the real Colossus against the engine.

See `docs/ARCHITECTURE.md` for the full picture and `docs/performance.md` for the speed campaign.
