# King-exposure eval term — design

> **VERDICT: REJECTED — REVERTED, DID NOT SHIP (2026-06-18, data-driven).**
> The term fixes the targeted g5 Kd2 blunder (deterministic: w≥8 stops playing it) but is
> **net −Elo at every depth and against every opponent measured** — a static king-safety
> penalty makes the engine globally passive (avoids ALL king advancement); that cost exceeds
> the benefit of dodging the rare blunder.
>
> | metric | d4 | d6 |
> |---|---|---|
> | self-play vs baseline (w=16) | −72 Elo (800g, clean) | −36 Elo (300g, inconclusive) |
> | vs Stockfish (w=16) | −34 Elo (SF1700) | −56 Elo (SF1900) |
>
> Smaller w=8 still −28 Elo (significant). A "surgical" gate on `count_king_zone_attackers`
> removes the harm but also the benefit (count=0 when Kd2 is played — the danger is
> positional/future, not currently-raying pieces). Depth-gated hypothesis **refuted** (no
> crossover to +Elo by d6). Combined with prior findings (scalar tuning tapped, material+PST
> +terms MSE-tapped, −344 naive bump), **king-safety-via-static-eval is a tapped lever** for
> this engine at the depth it plays. Campaign pivots to **speed → depth** (the proven +Elo
> lever; deeper search is also what would finally let king-safety pay). Kept: the
> `tools/match_fast.py CAISSA_ENGINE=cref` harness patch (host-cref eval A/B vs Colossus).



**Date:** 2026-06-18
**Campaign:** eval quality → reliably beat Colossus (see `memory/colossus-match-harness`)
**Goal:** close the measured king-safety hole that loses g5 (1.b3), g7 (1.Nc3), g10 (1.c4)
to default Colossus (true baseline: Caïssa **8-3-1**).

## Problem (measured)

`/tmp/evaldiff.py` vs Stockfish-d18 over the g5 loss: Caïssa is systematically
optimistic, gap explodes on king-exposing moves — 5.g4 −39 vs SF −259 (+220),
10.h5 −86 vs −371 (+285), 11.Kd2 −138 vs −412 (+274). Caïssa wrecks its own king
(g4/h4, Kd2-in-center) and grades it "slightly worse" while SF says "nearly lost."

Root cause in `src/eval.c`:
- King-safety weights are all 0 (`castled`/`pawn_shield`/`king_center`/
  `king_march_base`/`open_file_penalty`/`pawn_storm`); only the literal `<<3`
  king-march shift + `king_zone_attack=5` are live.
- `king_center` is **structurally useless** — penalizes file d/e for *both* sides
  (`eval.c:985,1015`) → g5's White Kd2(file3) + Black Ke8(file4) **cancel**.
- `king_march` only triggers White `row<6` (rank 3+) → **misses Kd2** (row 6,
  rank 2), the exact failure.
- `king_march` is **not enemy-material-scaled** → can't be turned up without
  wrecking endgames (where a central king is good) → why `king_march_base=0`.

Naive scalar bump already MEASURED at **−344 Elo** (do not repeat): scalar
king-weight tuning is tapped. The fix must be a new *structural* signal.

## Design — new term `king_exposure`

Own king advanced off its home rank in the middlegame is dangerous. Penalize by
ranks advanced, file-independent, only while the enemy has attacking material.

```c
static int king_exposure_pen(const Eval *e, int king_sq, int is_white) {
    if (e->endgame) return 0;                      /* central king GOOD in EG */
    int row = king_sq >> 4;
    int advanced = is_white ? (7 - row) : row;     /* home rank => 0 */
    if (advanced <= 0) return 0;
    int pen = advanced * g_w.king_exposure;
    if (pen > 127) pen = 127;                       /* signed-byte clamp */
    return pen;
}
```
Subtracted in `single_king_safety` for each side's own king.

### Why this beats the −344 naive bump — three specific fixes
1. **Asymmetric** (own-king-only) → g5's Kd2 + safe Ke8 do NOT cancel
   (`king_center`'s fatal flaw).
2. **Catches rank 2** (`advanced = 7-row` fires at Kd2 row 6) → `king_march`
   structurally misses it.
3. **Endgame-gated** (`!e->endgame`) → vanishes when a central king is good;
   this is exactly why `king_march_base` had to stay 0. The gate unlocks the knob.

### Defaults & data-driven gate
- New weight `g_w.king_exposure = 0` → term inert → **bit-exact golden** on add
  (clears the data-driven mandate for free; ships off until SPRT-proven).
- Then SPRT-sweep the weight {8,12,16,20,24}/rank; ship the winner.

### Deliberately omitted (YAGNI)
- File weighting / center-file emphasis — pure rank signal first.
- Quadratic escalation — linear `advanced × w` first.
- Continuous `× phase/24` taper — the `endgame` gate is cheaper (no 6502 multiply/
  divide) and consistent with how the eval already tapers (rook_open_file etc.
  switch on `endgame`). Add taper only if SPRT shows the boundary discontinuity
  hurts.

## Validation chain (every step gated)
1. Add term @ weight 0 → `speed_gate.sh` golden **0-mismatch** (bit-exact).
2. `cref selfplay --weights-b king_exposure=N --sprt` vs baseline → find the
   +Elo/neutral value across {8,12,16,20,24}.
3. `/tmp/evaldiff.py` on g5 → confirm the +220-300cp optimism gap shrinks at N.
4. Colossus match (`match_fast` / `baseline_nocap`) → g5/g7/g10 losses gone,
   beat the 8-3-1 baseline.
5. Port to `native/eval_full_6502.s` asm (gate-gated), `speed_gate.sh` full PASS
   bit-exact @ the shipped weight.
6. Ship (host C + 6502 asm), re-bless golden if the nonzero weight shifts moves.

## Tools
- `bash tools/llvmmos_bench/speed_gate.sh` — golden + fidelity + eval-bit-exact.
- `cref selfplay --weights-a "" --weights-b "king_exposure=N" --sprt --depth 4
  --jobs 10 --openings data/openings_big.txt`
- `/tmp/evaldiff.py` — Caïssa search-eval vs SF-d18 over g5 positions.
- `tools/match_fast.py` — Caïssa-vs-Colossus on the fast 6502 core.
