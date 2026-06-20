# Phase 2: Selective Search Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Give the stock-C64 `search_selective` plugin real Colossus-style plausibility forward-pruning (top-K width schedule + forcing-move exemption), then measure whether it beats full-width at the stock-C64 node budget.

**Architecture:** All selective code lives in `src/search_core.inc`'s `negamax` move-loop under `#if CREF_SEARCH_SELECTIVE`, tuned by new `SearchConfig` width fields. The loop already computes `gives_check` and `is_quiet` per move (search_core.inc:586-587) — the prune slots in right there. Full-width is untouched and stays byte-identical (the macro is build-wide only for selective builds, so full-width's `SearchConfig` is unchanged).

**Tech Stack:** C (llvm-mos for 6502, host cc for measurement), the existing `cref` CLI + golden/SPRT harness.

**Key invariant:** with the width schedule set to "no prune" (huge widths), `SEARCH=selective` MUST stay byte-identical to full-width. That is the regression anchor for every mechanism task — pruning is the *only* thing that may change the tree.

**The bet (the gate):** Task 7's SPRT — selective must beat full-width at a fixed per-move node budget. If it does not after tuning, the honest outcome is to keep the scaffold and not ship selective. Phases 0/1 already delivered standalone value (clean socket, restored golden gate, fixed overflow).

---

### Task 1: Build mechanism — make `CREF_SEARCH_SELECTIVE` build-wide for selective builds

**Why:** Task 2 adds fields to `SearchConfig` (in `search.h`, a shared header). For ABI consistency every TU in a selective build must see the same struct, so the macro must come from `-D`, not just `#define` inside `search_selective.c`. Full-width builds never define it → `SearchConfig` unchanged → byte-identical preserved.

**Files:**
- Modify: `Makefile` (the `SEARCH` block)
- Modify: `tools/build_caissa_server.sh`, `tools/build_c64.sh` (their `SEARCH_SRC` lines)
- Modify: `src/search_selective.c` (drop the local `#define`, rely on `-D`)

**Step 1:** In `Makefile`, after `SEARCH ?= fullwidth`, add:
```makefile
ifeq ($(SEARCH),selective)
  SELDEF := -DCREF_SEARCH_SELECTIVE=1
endif
```
and append `$(SELDEF)` to `CFLAGS` (or the relevant compile var used by all targets).

**Step 2:** In `tools/build_caissa_server.sh` and `tools/build_c64.sh`, where `SEARCH_SRC` is set, also:
```sh
[ "${SEARCH:-fullwidth}" = "selective" ] && DEFS="$DEFS -DCREF_SEARCH_SELECTIVE=1"
```
(build_c64.sh has no `DEFS` var yet — add the `-D` to its compile line directly when selective.)

**Step 3:** In `src/search_selective.c`, replace the `#define CREF_SEARCH_SELECTIVE 1` with a comment noting the macro now comes from the build (`-DCREF_SEARCH_SELECTIVE=1`); keep `#include "search_core.inc"`.

**Step 4: Verify still bit-exact (no behavior yet).**
```
make SEARCH=selective cli && cp build/cref /tmp/sel.cref
make cli && cmp /tmp/sel.cref build/cref && echo "still byte-identical"
```
Expected: identical (no SearchConfig change yet).

**Step 5: Commit** `build: make CREF_SEARCH_SELECTIVE build-wide for selective builds`.

---

### Task 2: Add the width-schedule config (defaults = no prune → still bit-exact)

**Files:**
- Modify: `src/search.h` (SearchConfig)
- Modify: `src/search_core.inc` (`search_reset_config`, a `sel_width()` helper)

**Step 1:** In `src/search.h`, inside `SearchConfig`, add (guarded so full-width is unchanged):
```c
#if defined(CREF_SEARCH_SELECTIVE)
    /* Selective plausibility forward-pruning (search_selective only). sel_width[d] is
     * the max number of QUIET moves searched at remaining-depth d (forcing moves --
     * captures/promos/checks -- are always searched). Index clamped to the array. A
     * huge value = no prune = identical to full-width. */
    int sel_width[8];
    int sel_min_depth;   /* don't prune when depth <= this (keep shallow nodes wide) */
#endif
```

**Step 2:** In `src/search_core.inc`, add near the other helpers a clamped accessor:
```c
#if defined(CREF_SEARCH_SELECTIVE)
static int sel_width(int depth) {
    int d = depth; if (d < 0) d = 0; if (d > 7) d = 7;
    return g_sc.sel_width[d];
}
#endif
```

**Step 3:** In `search_reset_config`, initialise to NO-PRUNE (keeps the scaffold bit-exact until Task 4 sets a real schedule):
```c
#if defined(CREF_SEARCH_SELECTIVE)
    { int k; for (k = 0; k < 8; k++) g_sc.sel_width[k] = 9999; }
    g_sc.sel_min_depth = 0;
#endif
```

**Step 4: Verify bit-exact (huge widths = no change).** Same `cmp` as Task 1 Step 4. Expected: `SEARCH=selective` cref byte-identical to full-width still.

**Step 5: Commit** `feat(search): selective width-schedule config (default no-prune)`.

---

### Task 3: Implement the prune in the negamax move-loop

**Files:**
- Modify: `src/search_core.inc` (the move loop, after `is_quiet` is computed, ~line 587)

**Step 1:** Immediately after `is_quiet = !(list[i].flags & (MF_CAPTURE | MF_EP | MF_PROMO));` insert:
```c
#if defined(CREF_SEARCH_SELECTIVE)
        /* Plausibility forward-pruning: past the per-depth quiet-move cap, search only
         * forcing moves (captures/promos already excluded by is_quiet; checks kept via
         * !gives_check). Quiet non-checking moves ranked beyond the cap are hard-pruned
         * -- the narrow-and-deep trade. Never at the root (ply 0), never before at least
         * one move has been searched (best_val guard => >=1 move => always returns a
         * move), and never in shallow nodes (sel_min_depth keeps them wide). */
        if (ply > 0 && depth > g_sc.sel_min_depth && is_quiet && !gives_check &&
            i >= sel_width(depth) && best_val > -SEARCH_INF) {
            unmake_move(b, list[i], &u);
            continue;
        }
#endif
```

**Step 2: Failing/again-bit-exact test (huge widths).** With default `sel_width=9999`, the prune never fires → byte-identical to full-width. `cmp` as before. Expected: identical.

**Step 3: Behavioural test (narrow width reduces nodes, stays legal).** Add `tools/tests/selective_smoke.sh`:
```sh
#!/usr/bin/env bash
# selective with a narrow schedule must: search FEWER nodes than full-width, still
# return a LEGAL move, and never crash, over a small FEN set.
set -e
make -s SEARCH=selective cli >/dev/null
SEL=build/cref
make -s cli >/dev/null
FW=build/cref_fw; cp build/cref $FW
# (the cref CLI needs a way to set a narrow schedule -- see Step 4)
```
**Note:** `cref` must expose the schedule. Add a `CAISSA_SEL_WIDTH` env read in `apps/cli/cref.c` (only compiled meaningfully when `CREF_SEARCH_SELECTIVE`): parse e.g. `"99,8,6,4,3,2,2,2"` into `g_sc.sel_width[]` after `search_reset_config()`. Default unset = keep no-prune.

**Step 4:** Implement the `CAISSA_SEL_WIDTH` env read in `apps/cli/cref.c` (guard with `#if defined(CREF_SEARCH_SELECTIVE)`). Verify: with the narrow schedule, `cref bestmove <fen> 6` reports a legal move and **lower `nodes`** than full-width on the same FEN; with no env set, node-identical to full-width.

**Step 5: Commit** `feat(search): selective forward-pruning in the negamax move-loop`.

---

### Task 4: Set the default selective schedule + invariant suite

**Files:**
- Modify: `src/search_core.inc` (`search_reset_config` selective defaults)
- Create: `tools/selective_invariants.py`

**Step 1:** Change the `search_reset_config` selective defaults from no-prune to a coarse starting schedule (tunable later):
```c
{ static const int W[8] = {9999, 9999, 12, 8, 6, 4, 3, 3}; int k;
  for (k = 0; k < 8; k++) g_sc.sel_width[k] = W[k]; }
g_sc.sel_min_depth = 2;   /* keep depth<=2 nodes full-width */
```
(Index is remaining depth: deep nodes near the root stay wide; shallow nodes prune hard. Start conservative.)

**Step 2: Invariant test (deterministic, the safety bar).** `tools/selective_invariants.py`: over a few hundred varied FENs (reuse `data/stockfish_opening_fens.txt` + a tactical set), run `SEARCH=selective cref bestmove` at d6 and assert for every position: (a) the move is legal (validate via python-chess), (b) a move is always returned (never empty), (c) it terminates within a node cap. FAIL the build on any violation.

**Step 3:** Run it. Expected: 100% legal, 100% return-a-move, 0 hangs.

**Step 4: Commit** `feat(search): default selective width schedule + invariant suite`.

---

### Task 5: Tactical regression (WAC) — selective vs full-width

**Files:**
- Create: `data/wac.epd` (the standard 300-position Win At Chess suite, public domain)
- Create: `tools/tactical_suite.py`

**Step 1:** Add `data/wac.epd` (300 EPDs with `bm`).

**Step 2:** `tools/tactical_suite.py`: for a given cref binary + node budget, run each WAC position, parse the bestmove, count how many match `bm`. Print `solved/300`. Run for BOTH `SEARCH=selective` and `SEARCH=fullwidth` at a matched node budget (`search_set_budget` via a `--nodes` CLI flag — add if missing).

**Step 3:** Run both. Record `solved_selective` vs `solved_fullwidth` at the budget. Expected/hoped: selective solves **more** at the same node budget (deeper tactics). This is evidence, not a hard gate.

**Step 4: Commit** `test: WAC tactical suite, selective vs full-width at fixed node budget`.

---

### Task 6: The decisive SPRT — selective vs full-width at the stock-C64 node budget

**Files:**
- Create: `tools/selective_sprt.py` (or extend the existing SPRT self-play harness)

**Step 1:** Pick the node budget = what a stock 1 MHz C64 can search in a reasonable move time (derive from `cref_mos` node counts at the depth the chip reaches in ~30-60 s; document the number). Both engines get the SAME per-move node budget via `search_set_budget`.

**Step 2:** `tools/selective_sprt.py`: play `SEARCH=selective` vs `SEARCH=fullwidth` over many diverse forced openings (engines are deterministic — need opening variety), colour-balanced, at the fixed node budget. SPRT(H0: equal, H1: selective +Elo).

**Step 3:** Run it. **This is the gate.** Record the Elo delta + LOS.
- Selective clearly wins → proceed to Task 7 (ship).
- Inconclusive / loses → Task 8 (tune) or stop.

**Step 4: Commit** `test: SPRT harness, selective vs full-width at stock-C64 node budget` (+ the measured result in the commit body).

---

### Task 7 (if selective wins): make selective the stock-C64 default

**Files:**
- Modify: `tools/build_c64.sh` (default `SEARCH=selective` for the stock game)
- Modify: `docs/plans/2026-06-20-pluggable-search-design.md` (record the result)

**Step 1:** Flip `build_c64.sh` to `SEARCH=${SEARCH:-selective}` (stock game ships selective). Keep `SEARCH=fullwidth` buildable. Leave server/Ultimate/REU on full-width.

**Step 2:** Verify the selective stock game still links + fits (it did at scaffold: 619 B free; pruning only changes runtime, not statics).

**Step 3: Commit** `feat(c64): ship selective search on the stock C64 (SPRT +N Elo @ budget)`.

---

### Task 8 (if not yet winning): tune the width schedule

**Loop:** sweep `CAISSA_SEL_WIDTH` schedules (wider vs narrower, different `sel_min_depth`) via the Task 6 SPRT and the Task 5 tactical suite. Each candidate is one SPRT run. Stop when a schedule beats full-width with LOS > 95%, or conclude the bet does not pay at this budget (document it; keep the scaffold, do not ship). Consider then: forcing-move depth *extension* (currently forcing moves only bypass the cap; extending them +1 ply is the next lever) and quiet-check handling cost.

---

## Verification checklist (run before declaring Phase 2 done)
- [ ] Full-width byte-identical throughout (every mechanism task); golden unchanged; `make verify` green.
- [ ] Selective with no-prune schedule == full-width (bit-exact anchor holds).
- [ ] Invariants: 100% legal, always-returns-a-move, never hangs (Task 4).
- [ ] Tactical delta recorded (Task 5); SPRT result recorded (Task 6).
- [ ] Stock selective game links + fits (Task 7) OR documented decision not to ship (Task 8).
