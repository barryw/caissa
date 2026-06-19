# Handover — closing the Colossus gap (resume point)

**Date:** 2026-06-19
**Goal (the north star):** Caïssa costs **~321M cyc/move at d4 (~1753 Elo)**; Colossus
4.0 plays the same strength at **~20M cyc/move** — Caïssa is **~16x heavier**. Close
that gap and still beat Colossus. Full plan: `docs/closing-the-colossus-gap.md`.
Benchmark + comparison: `docs/performance.md`.

## The state of the world (measured, not assumed)

- **The 16x = 3.4x too many nodes × 4.7x too many cycles/node.** Both attackable.
- **Eval is NOT the main lever** (P0/P1a measured): cutting king_safety = only
  −5.2% of eval / ~−1% of total on the 6502, and king_safety contributes ZERO eval
  value (MSE identical when zeroed). Whole realistic eval-strip ≈ 8-10% of total.
- **Quiescence node explosion IS the lever:** q/main = **3.20** (29k qnodes vs 9k
  main at d4). delta_margin tightening is Elo-tapped (margin=100 = −29 Elo).
- **The positional eval is tapped at d4** (3 terms king-danger/pawn/mobility all
  neutral; Texel-MSE stopped predicting d4 Elo). So depth, not eval, buys strength —
  and depth is bought with cycles. See `docs/eval-rewrite-conclusion-and-goal-reframe.md`.
- **40 MHz hardware (C64 Ultimate / Novu) is the platform:** at 40 MHz the engine
  already plays ~1753 in ~8 s/move, ~1850 (d5) in ~24 s. Cycle wins push the depth
  reachable at a given clock.

## What just shipped (committed + pushed to origin/main)

Last commits (newest first): `6b9f192` SEE, `c2bbd70` P0/P1a correction, `d7ba963`
P0 cost map, `3700427` Colossus benchmark + plan, plus the docs/perf/speed work.

**SEE is the live work.** `6b9f192`:
- `see(b, m)` in `src/movegen.c` — classic swap-list SEE, X-ray reveal (used[]-
  skipping ray rescans), values P100/N300/B300/R500/Q900, least-valuable-attacker.
- `test/test_see.c` (in `make verify`) — 5 hand-traced cases incl. X-ray battery, pass.
- Quiescence SEE-pruning behind `SearchConfig.see` (**default 0 = bit-exact**;
  PERFT exact, eval 22157/22157, all tests green). CLI/selfplay flag: `see=1`.
- **Measured (rep midgame d4, see=1 vs 0): qnodes 29088 → 15895 (−45%), total nodes
  38181 → 25001 (−34.5%), SAME best move + score (+115cp).** Precise, no quality
  change on that position.

## RESUME HERE — next steps, in order

1. **Elo-confirm `see=1` is neutral-or-up** (the one-position no-change is promising,
   not proof). Two yardsticks:
   - `NATIVE_CREF=build/cref python3 tools/native_vs_stockfish.py --native-depth 4
     --sf-elo 1800 --games 800 --jobs 8 --native-search "see=1"` vs a baseline run.
     (`--native-search` passes search-config overrides; confirm cref/native_vs_stockfish
     plumb it — `cmd_bestmove` takes a searchcfg arg.) Run SEQUENTIALLY, jobs<=cores
     (parallel SF runs get CPU-starved → inflate native Elo — learned this the hard way).
   - Colossus harness: `tools/colossus_timing.py` / `tools/match_fast.py` (drives the
     real Colossus 4.0 on the cycle-exact fast core).
   - Watch for over-pruning: SEE in qsearch can miss a few deep tactical recaptures.
     If d4 vs SF drops, the fix is to only prune captures with see < a small negative
     threshold, or skip SEE when in/near check (already gated on !check).
2. **Measure the on-chip cyc/move win.** SEE is currently C-only; the 6502 image
   needs `see` linked into the movegen build (it's in movegen.c, so the asm-movegen
   build should pick it up — verify the `caissa_cli`/image build compiles `see` and
   that `g_sc.see` is reachable there). Then `bash tools/llvmmos_bench/speed_gate.sh`
   with see=1 to get the real cyc/move (expect a big drop from the −34% nodes, but
   measure — qnodes are cheaper than main nodes).
3. **If both hold → ship default-on** (`g_sc.see = 1` in `search_reset_config`),
   re-bless the golden corpus (search behavior changes → golden moves change; that's
   expected, re-generate them), and confirm the gate.
4. **Then continue the lever list** (`docs/closing-the-colossus-gap.md`): SEE move
   ordering (use see as the capture sort key, fewer main nodes); eval-strip batch
   (king_safety free + king_pins + dead weight-0 terms, ONE asm re-derive); forward
   pruning (futility/razor/LMP). Near-term target 321M → ~150-200M cyc/move (d5 at
   the old d4 clock, +~100 Elo).

## Tooling / gotchas

- Gate (bit-exact + cyc/move): `bash tools/llvmmos_bench/speed_gate.sh` (slow ~5-30
  min under load — VICE/x64sc contends; it IS progressing, not hung). The arbiter.
- Profiler (per-fn + PC histogram of the 6502 image): `tools/llvmmos_bench/caissa_prof
  "FEN" DEPTH [symbol]`.
- Strength: `tools/native_vs_stockfish.py` (use `cref_mos` = the 6502 image's config
  for on-chip numbers; `cref` for full-config). cref_mos d-ladder: d1=1256, d2=1461,
  d3=1605, d4=1753.
- Bench: `python3 tools/onchip_strength_vs_tc.py bench --depths 1-6 --clocks 1,5,10,12,20,40`.
- 6510-assembly agent works well for asm micro-opts but VERIFY every change with the
  gate before committing (it rate-limited twice; gate is the judge of bit-exactness).
- Rep midgame FEN for quick node/cyc checks: `r1bq1rk1/pp2bppp/2n1pn2/2pp4/3P1B2/2PBPN2/PP1N1PPP/R2Q1RK1 w - - 0 9`.

## Memory

Full campaign detail in the auto-memory `eval-rewrite-design.md` (the ★★★ SEE entry
is the resume marker). This handover is the short form.
