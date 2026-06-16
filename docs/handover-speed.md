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

## What's been done

Earlier session (all gate-green, Elo IDENTICAL):

| commit | lever | result |
|---|---|---|
| `707ab03` | regression gate + golden corpus | (infra) |
| `bc48ab3` | PC-sampling profiler | (infra) |
| `d51f9e7` | pin/check-aware legal movegen | **1.62×** |
| `181f951` | eval_full bit-exact tweaks | +1% |
| `8d6db07` | `is_square_attacked` hand-asm (6510 agent) | +6%, **asm path proven** |

Latest session — **clean-C tier, all gate-green (incl. deep d6), Elo IDENTICAL** (baseline 1.0447B → **871.4M cyc/move @ d4, -16.6%**):

| commit | lever | result |
|---|---|---|
| `7403660` | cache g_w-derived eval tables (no per-call rebuild) | eval_full -9%, -1.0% |
| `1441772` | gen_legal probes in-place (drops `tmp=*b` board copy) | **-3.8%** |
| `4fcda38` | sparse-clear the pin table (was a 128B memset/node) | -2.3% |
| `1388d59` | incremental material+PST accumulator (Step A+B) | eval_full -20%, **-4.3%** |
| `94b86be` | skip egdiff term while EG PST == MG | -2.3% |
| `64564b4` | skip zobrist in quiescence make_move (86% of nodes) | **-4.2%** |

**Cumulative overall: ~2.1×** (1.82B → 871.4M cyc/move @ d4).

### KEY LEARNINGS (read before re-attempting)
- **Incremental accumulator only pays WITH eval_full using it (Step B).** make_move
  runs on every node; the lazy eval only fires in quiescence. Maintaining the
  accumulator just for `eval_material_pst` (Step A alone) is ~neutral (-0.4%). The
  win comes from `eval_full` ALSO seeding from the accumulators and dropping its
  per-square material/PST/phase math (-20% on eval_full) — that's pure gain on
  already-paid make_move cost. A v1 that used `sign*v` per term was a **+16.6%
  LOSS** (llvm-mos lowered it to ~12 `__mulhi3`/make_move); the multiply-free
  conditional-negate version is what works. acc must be re-seeded (`eval_acc_init`)
  at every search root + any direct-eval site that changes g_w after board setup.
- **The `tmp = *b` board-copy trick generalizes:** make/unmake is an exact
  round-trip, so any "copy board to mutate" can often run in place + unmake.
- **Per-node memset/memcpy is a smell** — gen_legal had both; both gone now.
- **Quiescence (86% of nodes) doesn't read `b->hash`** (no TT, no repetition) — so
  make_move skips the whole zobrist update there (a flag + the hash factored into
  one end-of-function block). Same idea may extend to other per-node work that
  quiescence computes but never reads. ALWAYS verify "unused in quiescence" against
  the actual quiesce() body; the golden gate (TT-key-dependent) catches mistakes.

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

## Profiler (where the cycles go — CURRENT, after the latest 5 opts)

```
tools/llvmmos_bench/profile6502 /tmp/engine6502.sim /tmp/engine6502.map "FEN" DEPTH
```
Current hot leaves (kiwipete d4): **eval_full 21%**, gen_legal 21%, make_move 16%,
is_square_attacked 10% (already asm'd), order_moves 8%, acc_piece 7% (the new
accumulator maintenance), unmake_move 5%, quiesce 3% (was 17% — the lazy eval is
O(1) now), count_sliding_mobility 2%. memcpy is GONE; __memset down to 1%.

The clean-C tier is largely harvested. What remains is structural — the big three
(eval_full, gen_legal, make_move) need hand-asm or behavior-changing algorithm
work, not C micro-opts.

## NEXT (do these, in order of expected payoff)

1. **Hand-asm the eval_full per-square loop** (6510 agent). Still the biggest slice
   (21%). After the accumulator change it no longer accumulates material/PST — it's
   the 6 positional helpers + counters per piece. eval-bit-exact gate (22157) is the
   contract. Likely asm the loop body / hottest helpers (count_sliding_mobility,
   king_zone_pressure), not the whole sprawling function.
2. **Hand-asm `make_move`** (16%, zobrist-heavy) + **`acc_piece`** (7%, called ~4×/
   make — candidate to inline into make_move asm) + the gen_legal pseudo loops (21%).
3. **order_moves** (8%): lazy/partial selection sort would skip the O(n²) tail on
   beta cutoffs (bit-exact, same order). BLOCKED on 6502 by per-ply score storage
   (g_score is a single shared scratch; recursion clobbers it). Needs g_score[ply]
   (~3.5KB) — check RAM headroom before attempting.
4. **Lighter eval** (structural): a cheaper positional eval that holds ~1800 — but
   this CHANGES behavior (golden + Elo), so it needs re-measurement, not the
   pure-speed gate.
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
