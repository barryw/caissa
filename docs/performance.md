# Performance & on-chip benchmark

How fast the engine searches on a 6502, and how that converts to playing
strength at a given clock. All numbers are from the **cycle-exact 6502 image**
(the same binary `make c64` ships), so they project to real hardware to within
clock accuracy.

> Note: this supersedes the old ca65 `make benchmark` / `engine_harness` numbers —
> that engine was removed when the project converged on the single C+llvm-mos
> engine. The harness here measures the shipping 6502 image.

## Tools

```sh
# cycles + nodes/sec per depth, at any clock (1 MHz stock, 40 MHz Ultimate, ...)
python3 tools/onchip_strength_vs_tc.py cycles --depths 1,2,3,4 --mhz 40
# strength per depth (cref_mos == the 6502 image's config, vs Stockfish)
python3 tools/onchip_strength_vs_tc.py elo --games 240
# per-function + in-function PC-histogram cycle profile of the 6502 image
tools/llvmmos_bench/caissa_prof "FEN" DEPTH [symbol]
# full fidelity + speed gate (bit-exact vs host oracle + cyc/move)
bash tools/llvmmos_bench/speed_gate.sh
```

## Search speed (cycle-exact 6502 image, 49-position corpus)

| Depth | cyc/move | nodes/move | cyc/node |
|------:|---------:|-----------:|---------:|
| 1 | 11.0M | 174 | 63,183 |
| 2 | 31.7M | 732 | 43,341 |
| 3 | 102.3M | 3,611 | 28,332 |
| 4 | 321.3M | 10,131 | 31,719 |

cyc/node is dominated by the static eval (~20%) + check/legality scans + make/unmake.

## Performance vs clock

cyc/move == seconds/move at 1 MHz; divide by the clock. The C64 Ultimate /
Ultimate 64 (and Gideon's newer hardware) run the 6502 core at ~40 MHz.

| Depth | @1 MHz (stock C64) | @40 MHz (Ultimate) | nodes/sec @40 MHz | strength |
|------:|-------------------:|-------------------:|------------------:|---------:|
| 1 | 11.0 s/move | **0.27 s/move** | ~630 | ~1256 |
| 2 | 31.7 s/move | **0.79 s/move** | ~920 | ~1461 |
| 3 | 102 s/move | **2.6 s/move** | ~1,410 | ~1605 |
| 4 | 321 s/move | **8.0 s/move** | ~1,260 | ~1753 |

(Strength = `cref_mos`, the reduced config the 6502 image runs, vs Stockfish;
golden-verified move-for-move identical to the image. Ladder ≈ +150 Elo/ply.)

## What it means

- **On a stock 1 MHz C64** the engine is a correspondence-class player: depth 4
  (~1753) costs ~5 minutes/move; at human clocks it plays ~depth 1-2 (~1256-1461).
- **On a 40 MHz Ultimate** the same binary plays **depth 4 (~1753) in ~8 s/move**,
  depth 5 (~1850, extrapolated) in ~26 s — i.e. **~1750-1850 at normal time
  controls.** The 40x hardware closes the gap that made 1800 correspondence-only
  on stock silicon.
- Strength is **depth-bound, hence speed-bound**: the static eval is tapped at the
  depths the chip reaches (Texel-MSE no longer predicts d4 Elo — see
  `docs/eval-rewrite-conclusion-and-goal-reframe.md`), so cycle wins are the lever.

## Speed campaign

The hot path is hand-written 6502 asm (`src/*_6502.s`), each change gated
bit-exact (`speed_gate.sh`: 6502 image == host oracle 50/50, PERFT, eval
22157/22157, golden 0-mismatch). Recent corpus cyc/move: **343.9M → 321.3M
(-6.6%)** via attacker-test collapse + scan unrolling + make_move fast-paths.
Per the asm audit the hot path is now near the 6502 addressing floor; the largest
remaining lever (incremental check-detection in quiescence) was measured at a
~1% ceiling for high risk and not pursued.

## On real hardware

`make c64` builds `chess.prg`. It runs unmodified on a stock C64 (`x64sc
chess.prg`) and on a C64 Ultimate / Ultimate 64 / Novu, where the 40 MHz core
yields the @40 MHz column above. The cycle-exact sim means measured-here ==
on-hardware to within clock accuracy.
