# Pluggable host-adaptive search — design (2026-06-20)

## Why (the strategic frame)

Caïssa is a ~1800-strength engine whose strength is fully available on fast hardware
(Ultimate 64 / REU) but throttled on a stock 1 MHz C64, where it is ~30–60× too slow to
reach the depth (d4–d6) its full-width search needs. On stock hardware it plays ~d3 and
is bounded by shallow-depth **eval quality** (its weakest term: king safety).

Colossus reached ~1750+ on the *same* 1 MHz hardware not by out-searching us but by being
a different *kind* of engine, built for the constraint: **selective search** (look at few
plausible moves, prune the rest hard, extend forcing lines deep), a **rich human-tuned
eval** (king safety) that carries shallow nodes, and a **large opening book**. Full-width
α-β + quiescence — Caïssa's architecture — is the modern, *verifiable* choice (PERFT-exact,
bit-exact host↔chip, golden) and the right one for fast hardware, but it is the wrong fit
for 1 MHz: it spends ~95% of its nodes on moves that get pruned.

Conclusion: keep full-width for fast/expanded machines; add a **selective** search for the
stock C64 — both on top of one shared, verified base. Host adapts which search runs.

We never read Colossus's source (clean-room boundary); the selective design below is from
era knowledge + observed play, not its code.

## Decisions (locked, via brainstorming)

1. **Selection = HYBRID.** Compile-time (`memcfg.h` profile) picks the search *architecture*;
   a small optional runtime probe (REU present? fast clock?) only *tunes parameters* (TT
   size, node budget) within it. Architecture is never switched at runtime — a stock C64
   cannot afford both searches in 64K.
2. **Seam = SEARCH ONLY.** Base (everywhere) = `board` + `movegen` + `eval` + make/unmake
   (the bit-exact, PERFT-verified core). The one pluggable thing is the search. Eval
   differences are handled by tuned weights (`EvalWeights` / `CAISSA_WEIGHTS`), not a
   second plugin.
3. **Selective style = plausibility forward-pruning (Colossus-style).** Top-K plausible
   moves per node, hard-prune the rest, extend forcing lines deep. Highest ceiling,
   highest risk (a quiet winning move can be pruned). Rejected: reductions-on-full-width
   (safe), forcing-line-selective (middle).

## Architecture

### Base (unchanged, shared)
`board.c`, `movegen.c`, `eval.c`, make/unmake. Stays under the existing golden/PERFT gate,
untouched. Knows nothing about which search sits on top.

### The socket
The contract already exists in `search.h` and needs no new types:

```c
Move search_bestmove(const Board *b, int depth,
                     const hash_t *hist, int hist_len, SearchInfo *out);
extern SearchConfig g_sc;            /* runtime-tuned knobs */
void  search_set_budget(long nodes); /* node/time budget */
```

Today's `search.c` is split into two TUs implementing that one contract:
- `search_fullwidth.c` — today's engine, moved **verbatim**. Plugin #1.
- `search_selective.c` — the Colossus-style plugin. Plugin #2.

Exactly one is linked per build. Callers (`caissa.h` facade, `cref`, the VICE server) hit
`search_bestmove` regardless — swapping plugins changes zero call sites.

### Selective plugin (`search_selective.c`)
Same negamax skeleton; the node-expansion *policy* changes. At each interior node:

1. **Score moves for plausibility** (cheap, no full eval) — reuse the existing
   `order_moves` ranking as a *selector*: MVV-LVA captures, checks, promotions, killers,
   piece-square delta for quiets.
2. **Search only the top-K; hard-prune the rest.** K is a **width schedule** that narrows
   with depth (illustrative, all `SearchConfig` knobs):

   ```
   ply 0 (root): all      ply 2: top 6      ply 4+: top 2–3
   ply 1: top 8           ply 3: top 4
   ```

   Pruned moves are never searched — that is what buys depth on a 1 MHz chip.
3. **Forcing moves bypass the width cap** — any check, capture/recapture, or 7th-rank push
   is always searched (doesn't count against K) and may extend depth. This is "follow the
   forcing lines deep," how tactics are seen past the nominal width.

Everything else is shared base, reused as-is: the same quiescence leaf (capture-only +
delta-pruned), the same TT, the same EGTB probe, the same eval. Selective search is *only*
a different expansion policy on the verified machinery — it does not reimplement search.

**Accepted risk:** a quiet, non-forcing winning move can be hard-pruned and never seen. The
width floor + good plausibility scoring shrink that hole; they do not close it.

## Verification contract (two plugins, two bars)

The base stays the single provable source of truth both build on.

**Full-width — unchanged, provable.** PERFT-exact movegen, golden node-exact regression,
eval bit-exact, host↔chip bit-exact. The socket extraction must preserve all of it — that
is how we prove the refactor changed nothing.

**Selective — cannot be node-exact** (it prunes heuristically) → bounded-safety + measured-
strength:

1. **Hard safety invariants** (deterministic, over a position corpus — absolute):
   never returns an illegal move; never returns *no* move when legal moves exist (width
   floor guarantees ≥1); always terminates within the node budget (never hangs); stays in
   RAM, never crashes.
2. **Strength (statistical):**
   - **Tactical suites** (WAC / ECM): % solved within the stock-C64 node budget.
   - **SPRT self-play (the decisive test):** selective must *beat full-width at the same
     1 MHz node/time budget*. If it doesn't win that match, the plugin is not worth
     shipping.
   - vs-Colossus (`match_fast.py`) + vs-Stockfish gradient for absolute placement.
3. **Targeted quiet-win suite:** positions where the win is *quiet* (non-forcing) — the
   plugin's known blind spot. Track % found; tune the width floor against it.

Most infra exists (golden, SPRT, `match_fast.py`, `native_vs_stockfish`). New: the tactical
suites + the quiet-win suite.

## Integration & data flow

Compile-time selection mirrors the EGTB conditional-link (`EGTB=1` → `egtb.c`). New
`memcfg.h` knob:

```
CREF_SEARCH = FULLWIDTH | SELECTIVE   (defaulted per profile)
```

HOST / REU / ULTIMATE / NOVA → `FULLWIDTH`; stock `C64` → `SELECTIVE`. The build links the
matching TU, never both (same one-line build-script pattern). `CREF_SEARCH` is
**independently selectable** so `C64 + FULLWIDTH` stays buildable as the SPRT baseline the
selective plugin must beat; the default flips to `SELECTIVE` only once it's proven.

**Runtime probe — minimal.** At boot, optional cheap detection sets *parameters only*:
probe `$DF00` → REU → size TT to it; detect turbo → lift node budget. Never switches
plugin; a no-op on a bare stock C64. Add a probe only when a real host needs one (YAGNI).

`SearchConfig` carries the selective tunables (width-schedule array, width floor, forcing-
extension toggles) so params sweep without recompiling — the same channel as `delta` /
`lazy_margin` today.

## Phasing (each step independently valuable; risk back-loaded)

- **Phase 0 — socket only.** Extract `search.c` → `search_fullwidth.c` behind `search.h`.
  Prove bit-exact (gate unchanged). Pure-good even if selective never lands: base and
  search are cleanly separated, zero behavior change.
- **Phase 1 — selective scaffold ≡ full-width.** `search_selective.c` with width=∞ / no
  pruning reproduces full-width's tree exactly. Bit-exact checkpoint — proves the scaffold
  before any heuristic.
- **Phase 2 — width schedule + forcing extensions on.** Diverges. Run safety invariants +
  tactical suites + the decisive SPRT (selective vs full-width @ stock-C64 budget). Tune.
- **Phase 3 — if it wins SPRT, flip the stock-C64 default to selective.** King-safety eval
  weights + opening book follow as *separate compounding layers* (they pay most at the
  shallow depth selective runs).

## Risks

- **The bet may not pay** — selective might not beat full-width at 1 MHz (the dropped
  `null_r=3` is a yellow flag, though that was on the depth-rich host). Mitigation: Phases
  1–2 measure it cheaply before committing; worst case keeps only Phase 0 (pure win).
- **Plausibility scoring is everything** — bad ranking prunes wins. Mitigation: reuse the
  proven `order_moves` (~93% first-move ordering); tune against the quiet-win suite.
- **Tuning rabbit-hole** (width per ply, floor, extensions). Mitigation: `SearchConfig`
  knobs + SPRT/oracle fast loop; start coarse.
- **RAM:** selective is *cheaper* (fewer nodes) → should ease the 64K budget, not tighten.

## Open questions

- Ship-gate = "beat full-width @ budget"? (North star = beat Colossus.)
- Opening book in scope as a later compounding layer?

## Explicitly NOT doing (YAGNI)

Runtime architecture switching; a second (eval) plugin; 5-man EGTB; the opening book (yet).
