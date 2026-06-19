# Eval Rewrite — Conclusion & Goal Reframe

**Date:** 2026-06-18
**Status:** decision record. Closes the eval-rewrite thread; reframes the campaign.

## 1. What we set out to do, and what the data said

The handover (`docs/handover-eval-rewrite.md`) asserted the engine is **eval-bound
at the shallow depth the chip plays**, and prescribed rebuilding the positional
eval for +50-150 Elo. This session implemented and **measured** three terms, each
the standard data-driven loop (Texel-MSE shape/scale → SF d4 confirmation → SPRT):

| Term | Texel MSE vs Stockfish | d4 vs SF (high-volume) | Verdict |
|------|------------------------|------------------------|---------|
| #1 king-danger (ring, attack-based) | −2% (king-danger subset) | 49.4% / 2300 games | neutral |
| #2 pawn structure (isolated/doubled) | −0.4% (full quiet set) | 45.6% / 600 games | neutral→neg |
| #3 mobility (per-piece, knight-heavy) | **−1.25%** (full quiet set) | 48.6% / 800 games | neutral→neg |

Baseline (no changes) = 49.5% vs Stockfish-1800 over ~2300 games ≈ **~1800 Elo at
depth 4.**

**Every term improved eval accuracy; none improved play.** The deep finding:

> **Texel MSE no longer predicts d4 Elo.** MSE measures absolute-eval accuracy;
> Elo measures move *ordering*. The baseline eval's move-ordering is already
> saturated for depth-4 search — a more accurate static eval does not change which
> move depth-4 picks. This is a deeper "tapped" than scalar-weight saturation: the
> primary eval-tuning instrument (Texel) has lost its grip on strength.

The handover's premise is **refuted by measurement.** The eval is not the binding
constraint at d4 — it is already ~1800-capable there and cannot be pushed higher.

## 2. The real binding constraint: SPEED → DEPTH

The facts that ARE solid and consistent:

- The native algorithm scores **~1800 at d4, ~1833 at d5, ~1942 at d6** vs a fixed
  Stockfish-1800 — clean **+~100 Elo/ply** (the signature of a correct search).
- Eval at d4 is tapped (this session, 3 terms).
- On-chip the *same* algorithm is **~30-60× too slow** (≈344M cycles/move at d4 ≈
  ~344s/move at 1 MHz). At any practical time control the chip reaches only ~d3,
  so it plays well below its d4 ceiling.

**Strength now comes only from depth; depth comes only from speed.** The lever is
speed, full stop. Prior speed work bought ~2.39× (old campaign) + ~1.5× (this
session's −34% cyc) ≈ **~3.6× cumulative** — against a **~30-60×** requirement to
reach d4 in seconds. ~10-20× more is needed and is not on the table from
incremental C-level micro-optimization.

## 2b. MEASURED — on-chip strength vs time control (2026-06-18)

Measured directly (`tools/onchip_strength_vs_tc.py`), replacing the campaign's
stale "~800-1000" inference. Time→depth from the cycle-accurate 6502 image
(caissa_prof, 49-FEN corpus); depth→Elo from `cref_mos` (the reduced config the
image runs, golden-identical to it) vs Stockfish.

| Depth | cyc/move | wall @1 MHz | on-chip Elo (cref_mos vs SF) |
|-------|----------|-------------|------------------------------|
| d1 | 11.5M | ~11.5s | **1256** (240 g vs SF-1320) |
| d2 | 33.8M | ~34s | **1461** (160 g vs SF-1400) |
| d3 | 111.8M | ~112s (~2 min) | **1605** (160 g vs SF-1550) |
| d4 | 350.9M | ~351s (~6 min) | **1753** (160 g vs SF-1700; full-cref d4 ≈ 1800) |

**Strength vs clock** (the chip plays fixed depth — the deepest that fits):

| Time control | Depth | On-chip strength |
|--------------|-------|------------------|
| 10 s/move (blitz) | d1 | **~1256** |
| 1 min/move | d2 | **~1461** |
| ~2 min/move | d3 | **~1605** |
| ~6 min/move | d4 | **~1753** |

Ladder measured at **+205 / +144 / +148 Elo per ply** (d1→d4) — ~+150/ply, steeper
than the +100/ply seen d4→d6. The reduced on-chip config (TT8 / no history) costs
only ~45 Elo vs full-cref at d4 (1753 vs ~1800).

**The chip is a ~d4-ceiling engine.** It plays ~1250 at blitz and needs ~6
minutes/move to reach ~1800. The ladder is ~+150-200 Elo/ply at the low end
(steeper than the +100/ply seen d4→d6), so EARLY depth is the cheapest Elo — and
early depth is bought with SPEED.

## 3. Honest feasibility of "on-chip ~1800"

"On-chip 1800" conflates two different things:

- **The algorithm is ~1800 at d4** — already true, on the host.
- **The chip reaching d4 in practical time** — NOT true; needs ~10-20× more speed.

So "1800 on the real C64 at human time controls" is **not reachable** with the
current architecture. What IS reachable:

- **1800 at long/correspondence time controls** — let the chip think minutes/move
  until it reaches d4. Essentially already true; the asterisk is the clock.
- **Maximize strength at the practical operating point (~d3, ~10-30s/move)** — an
  honest target is likely ~1200-1400, not 1800.
- **A speed moonshot** (llvm-mos native-on-chip, or a fundamental rewrite) to close
  the 10-20× gap — high risk, the only path to 1800 at practical time controls.

## 4. Reframed goal (proposed)

**Stop measuring the goal as a single Elo number; measure it as depth reached at a
declared time control, and report the strength that follows.**

1. **Ground the numbers first (next action).** Measure the REAL 6502 image vs
   Stockfish at a *declared, practical* time control (e.g. 10s and 60s/move) to get
   the honest on-chip strength-vs-time curve. The campaign has been arguing inferred
   numbers (memory: "~800-1000" is stale/disputed); a clean measurement settles it.
2. **Pick the goal honestly from that curve**, e.g. one of:
   - "**~1800 at ≥N s/move**" (correspondence-class) — verify N, publish it.
   - "**maximize Elo at 10s/move**" — accept ~d3 and target the best achievable there.
   - "**commit to the speed moonshot**" — make d4 run in seconds (llvm-mos / rewrite),
     the only route to 1800 at fast TC.
3. **Eval is done** for now: it is ~1800-capable at d4 and tapped. Leave the
   king-danger + mobility scaffolding in tree (default-inert / identity, zero harm);
   revisit ONLY if speed ever makes d5+ reachable on-chip (where king-safety and the
   richer terms finally pay — they need the depth they currently can't get).

## 5. What shipped this session (all committed, no strength regression)

- Design + results: `docs/plans/2026-06-18-eval-rewrite-design.md`.
- Term #1 king-danger (ring-based, attack-side, phase-gated) — default-inert.
- Term #3 mobility — parametrized per-piece (bit-exact refactor), default-identity.
- Tooling: `tools/filter_king_danger.py`, `tools/kd_tune.py`, `build/kd_tune.tsv`.
- Calibration rule banked: **tune eval SHAPE via Texel-MSE, SCALE via SF games; and
  at d4, Texel MSE gains no longer imply Elo gains — always SF-confirm at volume.**
