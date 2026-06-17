# Wholesale `eval_full` Hand-Asm — Scope

Scoping doc (2026-06-16) for hand-asm'ing the full positional eval. The last big
6502 speed lever: `eval_full` is **~34%** of cycles and resists every incremental
approach (see below). This is the only remaining way to cut it.

## Why monolithic is the ONLY viable strategy

Two failed experiments proved the constraint:
- **Asm a sub-function, jsr it from C** → net **−4.8%** (regression). `count_piece_mobility`
  is inlined into `eval_full`; forcing an extern boundary lost more (inlining of the
  knight path + `mobility` wrapper fusion) than the asm saved.
- **Algorithmic micro-restructure** (passed-pawn frontier O(1)) → **−0.22%** + size cost.
  `eval_full`'s 34% is *diffuse*: no single sub-term dominates in the real (inlined)
  build. The `-fno-inline` profile's apparent hotspots are call-overhead artifacts.

So the asm must be **one monolithic function** = `eval_full` + ALL ~35 positional
sub-terms inlined into it, with **no `jsr` to C sub-terms** (every such boundary
re-introduces the regression). It is a ground-up re-implementation of the entire
positional eval in 6502 asm.

## In scope (the asm implements, inlined)
Main board pass (per-piece dispatch P/N/B/R/Q/K):
- pawn/queen/minor pressure, knight_outpost, mobility (knight + sliding ray counts),
  seventh_rank, advanced_pawn, per-file pawn counts (wpf/bpf) + frontier.

Tail:
- bishop_pair; pawn_structure (doubled/isolated/passed/connected/protected/blockaded/
  rook_behind + rook open/semi-open file); king_pins → pins_from_king; king_safety
  (single_king_safety, king_zone_pressure, file_exposure, count_king_zone_attackers);
  endgame branch (king_activity, rook_activity); A/B terms (king_attack_escalation,
  pawn_storm, queen_attacks_minor) — all guarded by weight!=0; tempo.
- Tapered-PST egdiff blend (`score += egdiff*(24-phase)/24`, guarded by egdiff!=0 —
  the one wide mul/div spot); final 16-bit two's-complement wrap.

Reads (data the asm references): `acc_mat`/`acc_phase`/`acc_egdiff` (from Board,
already maintained), `g_w` weights, the derived `ET_*` tables, `passed_pawn_bonus[8]`,
the offset tables. `ET_*` are currently `static` → must be externalized (or the asm
reads `g_w` directly where ET_ mirrors it).

## OUT of scope (stays C / already handled)
- **Material + PST**: incremental via `acc_*` (eval_acc_apply/acc_piece on make/unmake).
  `eval_full` does NOT recompute them — it seeds `score = acc_mat` and adds positional
  terms only. The asm reads the seeded `acc_mat`. **No PST table walks in eval_full.**
- `eval_material_pst` (lazy eval), `eval_sync_tables`, `eval_reset_weights`, the
  `acc_*` accumulator maintainers — all stay C.
- The `is_*_attacked` / `count_*_mobility` / `*_passed` helpers — inlined INTO the asm,
  not called.

## Size & complexity
- C surface: eval.c is 1393 lines / 52 funcs; the positional portion `eval_full` pulls
  in is ~900-1000 lines across ~35 funcs.
- Asm estimate: **~1500-2500 lines** — the largest asm in the repo by far (3-4× the
  599-line `gen_legal`, ~2× the 881-line `gen_pseudo`).
- Risk: **VERY HIGH**. Bit-exact to 22157/22157 across ~35 interacting terms; the
  16-bit modular (uint16 wrap) score arithmetic must match exactly; many edge cases
  (endgame branch, tapered blend, king-zone, pins).

## The key de-risker: a DIRECT, FAST, per-position eval oracle
Unlike movegen (validated only indirectly through search fidelity), the eval has a
**direct bit-exact oracle**: `tools/texel_eval.py` + the 22157-position dataset +
`native_eval_check.py` already test `eval_full` bit-for-bit, in **seconds**, and
report WHICH positions mismatch. A wrong term shows up as a specific set of failing
positions whose shared feature localizes the bug. This makes a 35-term asm debuggable.

## Staging plan
1. **Build the asm-eval validator first** (~half a session): a 6502 image entry
   "eval this FEN → int score", run over the 22157 corpus, diff each score vs C
   `eval_full`. Mirror `engine6502.c`'s driver. Without this, debugging is infeasible.
   (The existing `build_engine6502.sh` + texel corpus give most of the plumbing.)
2. **Implement the monolith, validate via per-position diff.** Implement all terms,
   then iterate against the 22157 oracle; mismatching positions bisect to the buggy
   term. Term-group order: (a) main-loop pressure/outpost/advanced, (b) mobility +
   seventh, (c) pawn_structure, (d) king_pins + king_safety, (e) endgame branch,
   (f) A/B terms + tapered blend + wrap.
3. **Gate + ship**: scaffold `#ifdef CREF_ASM_EVAL_FULL` in eval.c, wire both build
   scripts, require full `speed_gate.sh` green (PERFT EXACT + 22157/22157 + golden
   50/50 + image 50/50) AND a measured cyc/move DROP before shipping.

## Effort & payoff
- Effort: a **multi-session** project. The 599-line `gen_legal` asm took one agent
  ~1.4M tokens / ~67 min. eval_full is 3-4× bigger + has the direct oracle to grind
  against → realistically **~4-6M tokens across several long agent runs** + main-thread
  orchestration (build the validator, decompose terms, validate each, ship).
- Payoff: eval_full is **34% of cycles**. Other asm conversions hit ~2-5× on their
  bodies; the expensive eval work is the ray walks (mobility) + attack detections.
  Realistic body speedup ~1.5-2× → **~−12 to −17% of TOTAL cycles** — the single
  biggest win of the campaign (cyc/move ~596M → ~500-520M). Uncertain: a chunk of
  eval_full is already-tight arithmetic (accumulator reads, term adds) that won't
  speed much, so the low end (~−12%) is more likely than the high end.
- Size: uncertain. `gen_pseudo`/`gen_legal` asm came out SMALLER than C codegen, but
  eval_full is large enough that asm could be comparable or bigger.

## Recommendation
**GO, but as a dedicated staged project, validator-first.** It is the only remaining
large lever and the eval has a uniquely strong (direct, fast, per-position) oracle
that makes a 35-term bit-exact asm tractable — without that oracle this would be
reckless. Set expectations: highest effort + risk of the campaign, realistic ~−12-17%,
several long sessions. NOT a quick win. Everything else cheap is already banked
(session total −21.9% cyc, −3.2KB, strength-neutral).
