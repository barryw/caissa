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

## Depth × clock sweep

The clock is a pure divisor on the cycle-exact count, so one measurement per depth
covers every clock. Full sweep (`onchip_strength_vs_tc.py bench --depths 1,2,3,4,5,6
--clocks 1,5,10,12,20,40 --fens 8`; this run is an 8-position subsample to keep d5/d6
tractable — clock ratios are exact, absolute cyc/move runs a touch high vs the
full-corpus table above because the first 8 corpus positions are complexity-heavy):

| depth | nodes/move | 1 MHz | 5 MHz | 10 MHz | 12 MHz | 20 MHz (SuperCPU) | 40 MHz (Ultimate) | strength |
|------:|-----------:|------:|------:|-------:|-------:|------:|------:|---------:|
| 1 | 461 | 25.1 s | 5.0 s | 2.5 s | 2.1 s | 1.3 s | 0.63 s | ~1256 |
| 2 | 969 | 43.7 s | 8.7 s | 4.4 s | 3.6 s | 2.2 s | 1.1 s | ~1461 |
| 3 | 4,466 | 2.6 m | 31.8 s | 15.9 s | 13.2 s | 7.9 s | 4.0 s | ~1605 |
| 4 | 7,735 | 4.6 m | 55.0 s | 27.5 s | 22.9 s | 13.8 s | 6.9 s | ~1753 |
| 5 | 27,979 | 15.9 m | 3.2 m | 1.6 m | 79.5 s | 47.7 s | 23.9 s | ~1850 |
| 6 | 76,234 | 37.2 m | 7.4 m | 3.7 m | 3.1 m | 1.9 m | 55.7 s | ~1942 |

- **Stock 1 MHz:** only depth 1-2 fits a human clock → ~1256-1461.
- **~20 MHz (SuperCPU-class):** depth 4 in ~14 s, depth 5 in ~48 s → ~1750-1850 at
  normal time controls.
- **~40 MHz (Ultimate / Novu):** depth 4 in ~7 s, depth 5 in ~24 s, depth 6 in ~56 s
  → **~1750-1942 across blitz→classical.** The d4-d5 band is the everyday sweet spot.

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

## The benchmark: Colossus 4.0 (our north star)

Colossus 4.0 is a hand-built ~1700-1800 C64 engine. Measured on the same
cycle-exact fast core (`tools/colossus_timing.py` driving `fastcolossus`), at its
default level it plays **Lookahead 3-4, ~2,000-3,800 positions, ~20M cyc/move**
(@1 MHz 20 s, **@40 MHz 0.5 s**). Head to head at comparable strength:

| Engine | depth | nodes/move | cyc/move | cyc/node | @40 MHz | strength |
|--------|-------|-----------:|---------:|---------:|--------:|----------|
| Colossus 4.0 | LA 3-4 | ~3,000 | **~20M** | ~6,700 | 0.5 s | ~1650-1750 |
| Caïssa | d4 | ~10,100 | **321M** | ~31,700 | 8.0 s | ~1753 |

**Caïssa is ~16x heavier per move** — ~3.4x more nodes AND ~4.7x more cycles per
node — at roughly equal strength. (Caïssa still *wins* the match ~72%, so it is
stronger; it just pays ~16x the cycles.) A human-built engine proved a ~1700
player fits in ~20M cyc/move on a 6502, so the efficiency headroom is enormous.
Closing this gap is the engine's reason for being; the plan is in
`docs/closing-the-colossus-gap.md`.

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
