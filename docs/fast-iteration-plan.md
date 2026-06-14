# Fast iteration plan — "bad news in seconds"

The 6502 self-play loop is the rate-limiter on engine strength work. A depth-6
move costs ~2.5B cycles ≈ 25s under sim6502 (~100 MIPS); a game ~20 min; an A/B
~1 hr. With the campaign pivoting to eval quality (many experiments), that loop
is the bottleneck. This is the staged plan to shrink the feedback loop from
hours to seconds.

## Tier 0 — measurement hygiene (DONE)
- `--difficulty-a/-b`: per-side search depth (test "does depth → wins").
- `--adjudicate-streak`: cut decided games short (depth-6 viable at all).
- `--sprt`: GSPRT early-stop — kill an A/B the instant the result is decisive
  either way, instead of grinding fixed N. Clear win/loss resolves in ~20-40
  games instead of 200.

## Tier 1 — two-tier self-play (DONE, methodology)
Most eval knowledge (material, PST, pawn structure, king safety, mobility,
outposts) changes the *static* eval and shows at shallow depth. So:
1. **Screen at d3** (`--difficulty hard`, ~28s/game) + `--sprt` → minutes.
2. **Confirm finalists at d6** (`--difficulty beast`) → hours, rare.
Only genuinely depth-dependent terms (king-attack dynamics) need d6 screening.

## Tier 2 — the Texel oracle (IN PROGRESS)
`tools/texel_eval.py` is a Python reimplementation of the engine's eval,
verified bit-exact via the bridge `eval` command. Extending it to the FULL eval
(all terms) gives **seconds-level feedback with zero games**: tune weights / test
a new term by minimizing MSE against the Stockfish-labeled dataset
(`build/texel_data.json`, 22k positions). MSE-vs-Stockfish is a *proxy* for
strength, so it is a fast FILTER; self-play (Tier 1) confirms game-Elo.

Loop: oracle (seconds) → d3+SPRT self-play (minutes) → d6 confirm (rare).

## Tier 3 — the native reference engine ("nuclear option")
The eval oracle proves engine logic can be reproduced at native speed. Extend it
to a full **reference engine** = ported eval + a search (negamax + alpha-beta +
quiescence + TT + move ordering) on a fast board (python-chess first, C if
needed). Run **reference-vs-reference self-play at native speed** (python-chess
move gen is microseconds; a depth-4 game is seconds, not 20 minutes). That gives
**game-Elo feedback in seconds/minutes**, not just the MSE proxy.

Fidelity contract:
- **Eval: bit-exact** to the 6502 (so eval experiments transfer). This is the
  hard requirement and the Tier-2 work delivers it.
- **Search: representative, not bit-exact.** A clean alpha-beta with the same
  eval is enough to screen eval changes; the 6502 confirms winners. (A better
  eval helps most reasonable searches, so the screen transfers.)

Staging:
1. Eval oracle exact (Tier 2). ← current
2. Python reference search using the oracle eval; sanity-check it picks
   reasonable moves vs the 6502 at matched depth.
3. Reference self-play harness (reuse the SPRT/adjudication logic) at native
   speed → the primary eval-iteration surface.
4. Port verified winners to the 6502; re-confirm on 6502 self-play.
5. If python search is too slow for deep screening, move the hot path to C.

Risk: two engines to keep in sync. Mitigation: the reference is the *iteration*
surface; the 6502 is the *ship* target. Every change is verified on both before
it counts (the verifiers — `verify_eval_rescale`, `verify_moves_identical` —
are the bridge).

## Priority
1. Tier 0/1 are done → use them now for the eval pivot.
2. Finish Tier 2 (full eval oracle) → seconds-level eval screening.
3. Build Tier 3 incrementally once Tier 2 proves the eval stays in sync.
