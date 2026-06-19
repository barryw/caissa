# Eval Positional-Layer Rewrite — Design

**Date:** 2026-06-18
**Status:** ACCEPTED (design pass). Implementation not started.
**Context:** resumes `docs/handover-eval-rewrite.md`. The engine's foundation
(movegen/search/board/speed) is verified solid; the binding strength constraint is
the shallow-depth positional eval. This document specifies an incremental,
measurement-gated rebuild of the positional layer.

---

## 0. Decision summary

| Axis | Decision |
|------|----------|
| **Scope** | Full positional rebuild, **incremental + SF-gated per term**. |
| **Order** | (1) king-danger, (2) pawn structure, (3) mobility, (4) outposts/rook, (5) tapered-phase where it pays. |
| **Phase model** | Phase-scale **king-danger only** (cheap enemy-heavy-material gate); everything else flat single-score. Full (mg,eg) tapering rejected on 6502 cost. |
| **King-danger** | Symmetric both-kings, **attack-based** (reward pressure on enemy king), ring-lite detection, attacker-units → nonlinear SAFETY_TABLE off-byte, phase-gated. |
| **Calibration** | **Supervise to Stockfish-d18 eval** on a king-danger-filtered dataset; close the measured +220–300cp optimism gap. |
| **Ship bar (every term)** | Moves the needle (SF-d4 ≥ neutral AND/OR evaldiff gap-closure AND SPRT not-worse), else **revert**. |

---

## 1. Why this, and why these constraints

On-chip the engine is speed-capped to ~d3–d4 (~344M cyc/move @ d4 ≈ 344s/move @1MHz).
Depth pays +~100 Elo/ply but is unreachable on-chip, so **strength is bounded by
shallow-depth eval quality**. The current eval = material + PST (solid) + a thin,
scalar-tuned-to-exhaustion positional layer with king-safety effectively absent.

Hard constraints carried from the handover:
- **Data-driven:** every change measured; meaningless or negative → reverted.
- **Shallow-depth focus:** the eval must help at **d3–d4**, not only d6. Test at d4.
- **6502 size + asm monolith:** `src/eval_full_6502.s` (3498-line hand-asm) is what the
  6502 image runs. Any eval change is C-first in `src/eval.c`, then re-derived in asm,
  gated by `tools/llvmmos_bench/speed_gate.sh`. Image bytes + cyc/move are tracked needles.
- **Realistic payoff:** ~+50–150 Elo at shallow depth (competing with Colossus 4.0's
  mature eval). This won't 2× the engine.

## 2. Structural findings about the current eval (the real problem)

Beyond "king weights are 0":

1. **King-safety is a single signed-byte accumulator.** `single_king_safety`
   (`src/eval.c:957-1027`) builds `s` via `add8s`/`sub8s` (saturate ±127), then
   `byte_x10(s)` folds into score (`king_safety`, eval.c:1029). Every king component
   clamps in **one byte before ×10** → can't express "3 attackers = catastrophe".
   `king_zone_attack=5` is **linear, no escalation**, and the term saturates.
2. **A quadratic escalation scaffold already exists** — `king_attack_escalation`
   (eval.c:1084, off-byte, direct cp) — but ships **weight 0**, never tuned to a win.
   The 4th failed attempt used its `count_king_zone_attackers`.
3. **"King zone" is misnamed.** It counts sliders **raying the king's own square** +
   knight-adjacency (`king_zone_pressure`, eval.c:915), **not** the 3×3 ring. Misses
   classic ring-pressure accumulation.
4. **Tapered `phase` var exists** (N/B=1,R=2,Q=4, clamp 24; eval.c:307) but the eval
   gates on a **binary `endgame` flag** → discontinuity.
5. **The decisive reframe:** all 4 prior killed king-safety attempts were **DEFENSIVE
   penalties on the own king** (−344 naive; −72/−34/−56 structural `king_exposure`).
   They made the engine **globally passive** — the cost of dodging a rare blunder
   exceeded its benefit. **The attack-side lever — reward escalating pressure on the
   ENEMY king — was never tried.** That is the core hypothesis of this rewrite.

## 3. Term #1 — attack-based king-danger

**Replace** `single_king_safety`/`byte_x10` with a symmetric term computed on the
16-bit score (no byte clamp):

```
for each king K in {white, black}:
    units = 0
    for each enemy attacker A found by RING-LITE detector:     # reuse cheap ray+knight scan
        units += ATTACKER_WEIGHT[type(A)]                       # Q > R > B ~= N
        if A also attacks a square ADJACENT to K:
            units += RING_BONUS[type(A)]                        # 1 extra test per found attacker
    units += shield_open_file_modifiers(K)                     # fold existing file-exposure in
    danger = SAFETY_TABLE[min(units, TABLE_MAX)]               # nonlinear ramp, precomputed
    danger = phase_scale(danger, enemy_heavy_material)         # *0 once enemy heavy material < threshold

white_score -= white_king_danger
white_score += black_king_danger                              # <-- attack-side reward (the new lever)
```

**Rationale per piece:**
- **Symmetric both-kings** → rewards attacking, not only penalizing own king. Un-tried lever.
- **SAFETY_TABLE** (units→cp, nonlinear) supplies the escalation the linear byte-clamped
  term structurally couldn't. Lookup = 1 cheap 6502 instruction (`LDA table,X`).
- **Off the byte accumulator** → no ±127 saturation. Reuses the dormant
  `king_attack_escalation` "direct cp" idea.
- **Phase gate** = enemy heavy-material count < threshold ⇒ `danger × 0`. Kills the
  endgame false-positives that made earlier king-march penalties globally passive.

**Ring-lite detection (cost-bounded):** reuse the existing cheap ray+knight scan
(`king_zone_pressure` / `count_king_zone_attackers`) and add **one** king-neighbor test
per found attacker. Do **not** do the textbook "is each of the 8 ring squares attacked?"
— that is 8× `is_square_attacked` per king, and that function is already **22% of the
profile**; 16 extra probes/eval would fail the speed gate.

**6502 cost:** small weight tables + a SAFETY_TABLE lookup + 1 ring test/attacker +
16-bit score adds. Re-derived into `eval_full_6502.s`, gated by `speed_gate.sh`.

## 4. Calibration — supervise to Stockfish-d18 eval

The documented failure is Caïssa being **+220–300cp optimistic vs Stockfish-d18 on
king-exposing moves**. Fit the king-danger params to **close that gap directly** rather
than to noisy game-result labels (Texel's quiet-position assumption is invalid in the
sharp positions where king-danger matters).

1. **Dataset:** source positions from self-play / match corpus + sharp openings,
   **filter to king-danger** (king off home rank, or ≥1 enemy attacker in the king zone,
   or recently-castled-into-attack). Label each with **Stockfish-d18 eval** (cp,
   white-POV) — reuse `/tmp/evaldiff.py` (already invokes SF18) → emit a TSV.
2. **Fit (seconds loop):** minimize `Σ |caissa_eval(pos) − sf18_eval(pos)|` over the
   king-danger params (~15: ATTACKER_WEIGHT[], RING_BONUS[], SAFETY_TABLE[], phase
   threshold) with **all other terms frozen**. Driver: extend `cref mse` (bit-exact
   full-eval oracle) to read the SF-labeled TSV; coordinate-descent via
   `tools/texel_tune.py`.
3. **Confirm on the real objective (don't ship on gap alone):**
   - `NATIVE_CREF=build/cref python3 tools/native_vs_stockfish.py --native-depth 4
     --sf-elo 1800 --games N --jobs 10` → **≥ neutral at d4** (the depth the chip plays).
   - `cref selfplay --sprt` vs baseline → guards the passivity regression that killed
     attempts 1–4.
   - Re-run evaldiff on a held-out king set → confirm the +220–300cp optimism closed.

**Ship bar:** gap closed **AND** d4-vs-SF ≥ neutral **AND** SPRT not-worse. Any one
fails → revert.

## 5. Terms #2–#5 — sequence and gates

Each ships through the same gate (C-first → measure → asm re-derive → `speed_gate.sh`),
and must move the needle or be reverted. Terms are independent; reorder if one stalls.

2. **Pawn structure** (mostly weight-0 today): `isolated_pawn`, **`backward_pawn`** (new),
   `connected_passer`, `protected_passer`; fix `advanced_pawn`/`deep_advanced_pawn`.
   Calibration = **classic Texel on quiet positions** (valid here — pawn structure is
   slow/structural). Cheap on 6502 (`wpf[]`/`bpf[]` file-occupancy arrays already exist).
   Likely the 2nd-biggest win.
3. **Mobility** — re-examine the earlier halving (+41 Elo). Test per-piece mobility
   weights, knight vs bishop separated, tuned jointly via Texel. Cost-watch: mobility
   counting adds movegen-like scans on 6502.
4. **Outposts / rook activity** — `knight_outpost` (weight-0), `rook_open_file`
   (weight-0, while `rook_semi_open_file=30` is live — asymmetric, suspicious). Small,
   cheap, Texel-tuned.
5. **Tapered-phase where it pays** — revisit only **after** 1–4; promote a term to
   (mg,eg) only if flat-weight measurably costs Elo. Deferred by the Section 0 phase
   decision.

**Workflow:** king-danger first (hardest + biggest gap). If it ships, the SF-supervision
dataset + `cref mse` extension are reusable for 2–4. Mobility/outposts last (smallest).

## 6. Toolkit pointers

- SF gradient: `tools/native_vs_stockfish.py --sf-elo 1800` (yardstick; Colossus saturated).
- Self-play + SPRT: `cref selfplay --weights-a "" --weights-b "spec" --sprt`.
- Texel oracle: `cref mse TSV [weights]`, `tools/texel_tune.py`, `tools/build_texel_dataset.py`.
- evaldiff vs SF-d18: `/tmp/evaldiff.py` (re-create for each hypothesis).
- Speed/size gate: `bash tools/llvmmos_bench/speed_gate.sh`; profiler
  `tools/llvmmos_bench/caissa_prof "FEN" DEPTH [SYMBOL]`.
- C→6502 port: `src/eval.c` → `src/eval_full_6502.s` (validator
  `tools/eval_corpus_check.py`; method in `docs/eval-asm-scope.md`).
