# Closing the Colossus gap

**The benchmark.** Colossus 4.0 — hand-built, ~1700-1800 — plays at **~20M
cyc/move** (Lookahead 3-4, ~3,000 nodes). Caïssa at d4 (~1753) costs **321M
cyc/move** (~10,100 nodes). Caïssa is **~16x heavier** at equal strength. A human
proved a ~1700 player fits in ~20M cycles on a 6502. So can we — and better.

## 1. Decompose the 16x

```
16x  =  3.4x  more nodes        x   4.7x  more cycles per node
        (10,100 vs ~3,000)          (31,700 vs ~6,700)
```

Both factors are attackable, and the data says where (profile of a midgame d4
search, ~38k nodes, ~1.2B cyc):

| slice | % cyc | what it is | lever |
|---|---:|---|---|
| quiesce (own) | 26% | the q-search move loop + recursion | **node count** (tame q-search) |
| eval_full | 20% | full static eval, paid by **22.7% of nodes** | **cyc/node** (strip/cheapen) |
| make+unmake | 16% | board state save/restore | at the 6502 floor |
| is_square_attacked | 12% | check + legality scans | mined (-23% already) |
| eval_acc_apply | 5% | incremental material+PST | cheap, keep |

Quiescence generates ~2x the main-search nodes; full eval is paid by ~23% of
nodes at ~28k cyc each.

## 2. The synthesis insight (why this is winnable, not just hard)

Two findings from this campaign **point the same way**:

1. **The rich positional eval is TAPPED at d4.** King-safety, pawn-structure, and
   mobility terms each improved Texel-MSE but were all neutral-to-negative in d4
   play — Texel-MSE stopped predicting Elo (the eval's move-ordering is saturated
   for shallow search). See `eval-rewrite-conclusion-and-goal-reframe.md`.
2. **That same rich eval is ~20% of the cycle cost** (the 4.7x cyc/node driver).

So the expensive positional terms are **pure dead weight: cost without strength**
at the depth the chip plays. The eval-rewrite and the speed campaign converge on a
single move:

> **Strip the eval to a lean core (material + PST + the few cheap terms that pay),
> make what remains incremental, and tame quiescence — so cyc/move falls, the chip
> searches DEEPER in the same clock, and depth (+150 Elo/ply) buys back more than
> the stripped terms ever did.**

We are not trying to out-evaluate Colossus (eval is tapped). We win by being
**Colossus-lean + sound-deep**: a PERFT-exact, mate-finding, +150/ply search that
Colossus's selective search can't match tactically — but running at Colossus's
cycle budget.

## 3. The plan (phased, each measurement-gated)

Ground rules: every change gated bit-exact where it can be (`speed_gate.sh`), and
every strength claim confirmed on BOTH yardsticks — `native_vs_stockfish` at d4 AND
the Colossus harness (`tools/colossus_timing.py` / `match_fast.py`). A cycle win
that loses Elo is reverted; a cycle win that lets us search +1 ply is the goal.

**Phase 0 — per-term eval cost map.** Measure cyc-per-term in `eval_full` (the PC
histogram already localizes warm spots) and cross with the per-term Elo from the
tuning history. Output: a ranked "cost vs Elo" table. Cut candidates = expensive +
low/zero Elo.

### P0 RESULTS (measured 2026-06-19)

Per-term eval cost (host toggle-timing, 4000 positions; host *under*-weights the
ray-scan terms, which are worse on the 6502) crossed with value (Texel-MSE delta
when the term's weights are zeroed, on the 375k quiet set):

| term | % of eval cost | MSE when zeroed | verdict |
|---|---:|---|---|
| pawn_structure | 25.5% | — (mixed: passed real, conn/prot/iso rejected) | split: keep passed, cut rest |
| mobility | 17.9% | real (+41 Elo historically) | keep, cheapen |
| **king_safety** | **12.9%** | **0.01467532 → 0.01467532 (IDENTICAL)** | **CUT — zero value, pure dead weight** |
| king_pins | 13.1% | 0.01467532 → 0.01472589 (small +value) | test-then-cut (search handles pins) |
| minor_pressure | 6.8% | small +value | test |
| pawn/queen_pressure, knight_outpost, seventh_rank, bishop_pair, advanced_pawn | <2% each | mostly weight-0 (bishop_pair real) | cut dead ones (low priority, cheap) |
| **all positional** | **78.2%** | | material+PST is only 22% of eval |

Headline: **king_safety is ~13% of eval cost for exactly zero eval value** (MSE
identical when zeroed — it both tested neutral in games AND contributes nothing to
static accuracy). It is the immediate free cut. king_pins is another ~13% for
trivial static value that the tactical search likely makes redundant at d4.
Cutting both ≈ a quarter of eval cost (more on the 6502, ray-heavy) for ~zero Elo.

### P0/P1a CORRECTION (measured 2026-06-19) — the plan was eval-heavy; the lever is quiescence

Two measurements re-ranked the levers:

- **Eval-strip is modest, not the main event.** On the 6502 (llvm-mos -O2) cutting
  king_safety moved eval_full **52,432 → 49,691 cyc/eval (−5.2% of eval, ~−1% of
  total cyc/move)** — far less than host-timing's 12.9%. eval is ~20% of cyc/move,
  and the valuable terms (mobility +41, passed pawns) can't be cut, so the whole
  realistic eval-strip is **~8-10% of total** — real, worth doing as a batch, but
  not the 16x closer.
- **Quiescence is the dominant lever — and delta-pruning is Elo-tapped.** Measured
  q/main = **3.20** (29,088 qnodes vs 9,093 main at d4). Tightening delta_margin
  200→100 cuts qnodes ~12% but was already measured at **−29 Elo** (too blunt). So
  the lever is **SEE (static exchange evaluation)**: prune/early-out captures that
  lose material *precisely*, where delta's victim+margin heuristic can't. SEE also
  sharpens move ordering (fewer main nodes). This is the highest-value remaining
  move and it does NOT cost the eval's quality.

**Revised lever order:** (1) **SEE in quiescence + ordering** (the 3.2x node
explosion — biggest, Elo-safe); (2) eval-strip batch (king_safety free, then
king_pins + dead weight-0 terms + pawn_structure trim, ~−8-10%, one asm re-derive);
(3) incremental survivors; (4) forward pruning. Honest near-term target: 321M →
**~150-200M cyc/move** (= d5 at the old d4 clock, +~100 Elo). Colossus's 20M is a
sustained program, not one phase.

**Phase 1 — strip the eval.** Remove the dead-weight terms (Phase 0's cut list),
keeping material + PST + whatever survives a cost/Elo test. Target: full eval 28k →
~10-12k cyc; widen the lazy-eval margin so fewer nodes pay full eval at all.
Gate: cyc/move down, strength vs SF d4 + Colossus **neutral or up** (depth bought
back the terms). Expect the chip to reach d5 at the old d4 clock.

**Phase 2 — incremental-ize the survivors.** Whatever positional terms stay,
update them on make/unmake (like material+PST already are via `eval_acc`) instead
of recomputing from scratch. Kills most of the remaining full-eval cost.

**Phase 3 — tame quiescence (the 26% + the 2x node explosion).** SEE-based capture
pruning (don't search losing captures), tighter/auto delta margin, a hard q-depth
cap. Target: qnodes 2x → ~1x main nodes. This cuts the single biggest cycle slice
AND the node count together.

**Phase 4 — forward pruning to match Colossus's selectivity.** Futility pruning,
razoring, late-move pruning beyond the current LMR. Fewer main nodes per ply.
Gate hardest here — over-pruning loses tactics (the thing we beat Colossus on).

## 4. Targets

| | now (d4) | after strip+incr (Phase 1-2) | after q-tame+prune (Phase 3-4) |
|---|---:|---:|---:|
| cyc/node | 31,700 | ~12-15k | ~12-15k |
| nodes/move | 10,100 | 10,100 | ~4-5k |
| cyc/move | 321M | ~130-150M | **~50-70M** |
| depth @ old clock | d4 | d5 | d5-6 |

~50-70M cyc/move is still ~3x Colossus — but at **d5-6 (~1850-1942)**, clearly
stronger, and well within playable time on a 40 MHz Ultimate (~1.5-2 s/move). The
last 3x to true parity is the long tail (incremental check, leaner movegen, asm).

## 5. Why a "human-built engine" beat us — and why that's temporary

Colossus was designed **on** the 6502: every term, every node, cycle-conscious from
day one. Caïssa was designed in C for correctness/strength and compiled down — so
it carries a rich-eval, full-recompute design that's expensive on an 8-bit CPU. The
fix isn't cleverness Colossus lacked; it's adopting the same discipline (lean,
incremental, selective) **on top of** a verified-sound search and a full measurement
rig Colossus's authors never had. That's how we don't just match 20M cyc/move — we
get there at a strength Colossus can't reach.
