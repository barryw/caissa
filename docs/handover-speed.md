# Handover: aggressive speed campaign (on-chip 1800 → make it fast)

**Branch:** `strength-campaign-c-reference` (pushed to origin)
**Date:** 2026-06-16

## Where we are

**Goal MET.** The native C engine, compiled to a **real 6502 via llvm-mos**, plays
**~1850-1900 Elo** — DIRECT-measured on the actual binary vs handicapped Stockfish
@ depth 6, zero forfeits. Full history in memory `onchip-1800-campaign.md` and
`reference-engine-tier3.md`.

The remaining problem is **SPEED**, not strength. Move-time on a real 1MHz C64:
- d3 ≈ 6 min/move (~1740 Elo — below 1800)
- d4 ≈ 18 min/move (~1760 Elo)
- d6 ≈ **~28 hours/move** (~1875 Elo)

Depth is a strength/speed dial: the engine is **eval-bound** (Texel-tuned eval
carries the strength; depth adds only ~100-130 Elo d3→d6). ≥1800 is confident at
d5-d6 only.

## The target: Colossus

Colossus Chess (C64, 6502, ~1MHz, ~1750 Elo) examined **~520 positions/sec** =
**~1,900 cycles/node**. Ours now ≈ **~37,000 cycles/node** (1.045B cyc/move @ d4
÷ ~28k node-evals). **We are ~20× slower per node than Colossus.** That gap is the
campaign: compiled-C + a heavy full positional eval vs Colossus's hand-asm + lean
eval. Closing even half of it makes d5-d6 practical.

## What's been done (4 commits this session, all gate-green, Elo IDENTICAL)

| commit | lever | result |
|---|---|---|
| `707ab03` | regression gate + golden corpus | (infra) |
| `bc48ab3` | PC-sampling profiler | (infra) |
| `d51f9e7` | pin/check-aware legal movegen | **1.62×** |
| `181f951` | eval_full bit-exact tweaks | +1% |
| `8d6db07` | `is_square_attacked` hand-asm (6510 agent) | +6%, **asm path proven** |

**Cumulative: ~1.74×** (1.82B → 1.045B cyc/move @ d4).

## THE REGRESSION GATE — run before/after every change

```
bash tools/llvmmos_bench/speed_gate.sh          # ~3 min; add --deep for d6 fidelity
```
Must print `== gate PASS ==`. It builds native + the mos-sim 6502 image and checks:
1. **movegen** PERFT EXACT (kiwipete/ep/castle/promo) — THE check for movegen/attack asm
2. **eval** 22157/22157 bit-exact — THE check for eval work
3. **search** 50 golden moves (cref_mos d4+d6) 0 mismatches — catches search-behavior drift
4. **6502 port** image == cref_mos move-for-move @ d4 (50/50)
5. speed metric: `cycles/move: avg=...`

A failure = real regression (fix it) OR intentional behavior change (re-bless:
`python3 tools/llvmmos_bench/gen_golden.py`, then RE-MEASURE Elo). For pure speed
work, golden + eval-bit-exact MUST stay green = moves identical = Elo preserved.

## Profiler (where the cycles go — after the 3 opts)

```
tools/llvmmos_bench/profile6502 /tmp/engine6502.sim /tmp/engine6502.map "FEN" DEPTH
```
Current hot leaves: **eval_full 30%**, gen_legal 14%, quiesce 11%, make_move 8%,
is_square_attacked 7% (already asm'd), order_moves 4%, __memset+memcpy ~6% (board copies).

## NEXT (do these, in order of expected payoff)

1. **Hand-asm `eval_full` and/or the lazy `eval_material_pst`** (6510 agent). 30% of
   cycles, the single biggest slice. eval-bit-exact gate (22157) is the perfect
   contract. Big function — may need to asm the inner per-square loop only.
2. **Hand-asm `make_move`** (8%) and the gen_legal pseudo-move loops (14%).
3. **Incremental material+PST** maintained in make/unmake (kills the lazy eval at
   most leaves). SKIPPED earlier because the A/B harness overrides `g_w` weights
   mid-game; for the SHIP config weights are fixed, so it's valid — guard/invalidate
   when g_w changes. Eval value must stay bit-exact (gate enforces).
4. **Lighter eval** (structural): the full positional eval is the heaviest single
   cost. A cheaper eval that holds ~1800 would be a big win — but this CHANGES
   behavior (golden + Elo), so it needs re-measurement, not the pure-speed gate.
5. **Lower ship depth**: d4 (~1760, ~18min/move) is close to 1800; combined with
   the speedups it gets practical. Decide the ship depth once it's fast enough.

## ASM-leaf recipe (proven, from `is_square_attacked`)

1. `~/Git/llvm-mos/build/bin/mos-sim-clang -Os -S -I native native/FILE.c -o /tmp/x.s`
   and read the target function's ABI: ptr args → `__rc2/3,4/5,...`; first i16 arg →
   `A`(lo)/`X`(hi); return i16 → `A/X`. Caller-saved: `__rc2..__rc19` (use `__rc8+`).
2. Write `native/FUNC_6502.s` defining the global with that exact ABI.
3. Guard the C body: `#ifndef CREF_ASM_FUNC ... #endif` (host build keeps C = the
   golden oracle stays correct; only the mos-sim image gets asm).
4. In `tools/llvmmos_bench/build_engine6502.sh` step 3, add `-DCREF_ASM_FUNC` and
   append `$NATIVE/FUNC_6502.s` to the **mos-sim** compile/link line ONLY.
5. Run the gate. **WATCH:** 6502 branch reach is ±127 — the integrated assembler
   SILENTLY truncates out-of-range branches; use invert-condition + `jmp` for far exits.
6. Production image is built **`-Os`** (not -O2); optimize for -Os.

## Key files
- `native/{board,movegen,eval,search}.c` — the engine (compiles to host AND 6502).
- `native/is_square_attacked_6502.s` — first asm leaf (template).
- `tools/llvmmos_bench/` — build_engine6502.sh, speed_gate.sh, profile6502.c,
  validate.c, engine6502_cli.c (the cref-compatible CLI over the real image),
  gen_golden.py, regression_fens.txt, golden_moves.txt, NOTES.md (toolchain repro).
- `tools/native_vs_stockfish.py` — Elo vs SF; `NATIVE_CREF=<bin>` overrides the
  engine binary (use `tools/llvmmos_bench/engine6502_cli` for the REAL 6502 image,
  or `native/cref_mos` for the fast host proxy of the exact 6502 config).

## Measure Elo (only when behavior intentionally changes)
```
# host proxy (fast, = 6502 moves): native/cref_mos built with -D__mos__
NATIVE_CREF=native/cref_mos python3 tools/native_vs_stockfish.py --native-depth 6 --sf-elo 1700 --games 80 --jobs 9
# the REAL 6502 binary (slow, definitive):
NATIVE_CREF=tools/llvmmos_bench/engine6502_cli python3 tools/native_vs_stockfish.py --native-depth 6 --sf-elo 1700 --games 16 --jobs 6
```
LESSON (load-bearing): only the DIRECT engine6502_cli number is the real on-chip
Elo; the cref_mos host proxy is faithful but is a proxy — confirm direct before
claiming. SF UCI_Elo at 1500-1700 is poorly calibrated (compressed); numbers ±~100.
