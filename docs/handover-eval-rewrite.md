# Handover — Eval Rewrite (design pass)

**Date:** 2026-06-18
**Purpose:** brief a fresh session to **brainstorm + design a rewrite of the eval's
positional layer**. The engine's foundation is verified solid; the binding strength
constraint is the shallow-depth positional eval. This doc is the full context so the
design pass doesn't repeat what's already been tried and killed.

---

## 1. Verdict: the foundation is SOLID (verified this session)

Do **not** rewrite these — they're correct and appropriate:

- **Movegen** — PERFT EXACT vs python-chess (ground truth) on the standard bug-catcher
  suite: castling+promo+pins (`r3k2r/Pppp1ppp/...` d4=422333), underpromotion
  (`rnbq1k1r/...` d4=2103487), promo-race (d5=3605103), ep/pin endgame (d5=674624).
  `python3 test/native_perft_check.py` → `PERFT EXACT`.
- **Search** — sound: finds forced mates (`+29997/+29999`), and scales **+~100 Elo/ply**
  cleanly (d4→d5→d6 vs SF-1800; see §3). Clean depth scaling is the signature of a
  correct alpha-beta. Pruning is comprehensive (killers, null-move r=2, LMR +78 Elo,
  delta, lazy-margin). Don't rewrite.
- **make/unmake, 0x88 board, 6502 asm hot paths** — bit-exact (6502 image == cref_mos
  50/50, eval 22157/22157, golden 0-mismatch). 0x88 + C→6502 (llvm-mos) is the right
  architecture for an 8-bit CPU; bitboards are murder on a 6502. Speed is near the
  practical limit — DON'T rewrite for speed (won't close the ~30-60× on-chip gap).

Engine strength: **~1730 (d4) → 1942 (d6)** vs Stockfish. A real engine, not a turd.

## 2. Why the eval positional layer is THE rewrite target

- It's the **binding constraint at the depth the chip actually plays**. On-chip the
  engine is speed-capped to ~d3-d4 (~344M cyc/move at d4 ≈ 344s/move @1MHz). Depth pays
  +100/ply but is **unreachable on-chip** — so strength is bounded by shallow-depth eval
  quality. When search is shallow, eval dominates.
- The current eval = **material + PST (solid, classic) + a thin/patchy positional layer**
  that was **scalar-tuned to exhaustion** on top of a weak structure:
  - King-safety is **absent**: `castled`/`pawn_shield`/`king_march_base`/`open_file_penalty`/
    `pawn_storm` all weight 0; only a literal `<<3` king-march shift + `king_zone_attack=5`
    are live. `king_center` is **structurally useless** — it penalizes file d/e for BOTH
    sides (`src/eval.c:985,1015`) so it CANCELS.
  - Many positional terms ship at weight 0 (pawn_attack_*, knight_outpost, isolated/
    advanced_pawn, connected/protected_passer, rook_open_file, trapped, the A/B terms).
  - Eval files: `src/eval.c` (host C body + `EvalWeights` in `src/eval.h`),
    `src/eval_full_6502.s` (3498-line hand-asm MONOLITH, all terms inlined — the 6502
    image uses THIS, not the C; any eval change must be re-derived in asm, gate-gated).

## 3. What was TRIED and KILLED this session (do NOT repeat)

All measured, all negative — the discipline matters because eval changes backfire easily:

- **Naive king-weight bump** (`castled=40,king_march_base=24,pawn_shield=15,...`) =
  **−344 Elo** (self-play A=87.9%). Scalar king tuning is TAPPED.
- **Structural `king_exposure` term** (own-king rank-advance off home, endgame-gated):
  fixed the exact g5 Kd2 blunder (deterministic) BUT net **−Elo at every depth/opponent**
  (self-play −72@w16, SF-1700 −34, SF-1900@d6 −56). Reverted. Design doc:
  `docs/plans/2026-06-18-king-exposure-term-design.md` (marked REJECTED).
- **Surgical attacker-gate** on that term (`count_king_zone_attackers==0 → skip`): KILLED
  the benefit — when Kd2 is played, the king-zone attacker count is 0 (danger is
  positional/future, not currently-raying pieces). Wrong signal.
- **Depth hypothesis** for king-safety: refuted (term still −Elo at d6).
- **Lesson:** the cure (static penalty) made the engine globally passive; the cost
  exceeded the benefit of dodging the rare blunder. A structural eval improvement must be
  *coherent and carefully calibrated*, not bolted-on penalties.

Prior (in memory): scalar-weight tuning TAPPED (~754→~1850 over the campaign);
material+PST+terms MSE-TAPPED.

## 4. The measurement toolkit (use ALL of it — data-driven mandate)

Every change must be PROVEN to move speed/intelligence/size meaningfully, else reverted.

- **SF gradient (the yardstick — USE THIS, not Colossus):**
  `NATIVE_CREF=build/cref python3 tools/native_vs_stockfish.py --native-depth D
  --sf-elo 1800 --games N --jobs 10 --native-weights "key=val,..."`. Clean, deterministic,
  no bitmap/ponder issues. Depth ladder this session: d4=40%(1730), d5=55%(1833),
  d6=69%(1942). Dial sf-elo to put Caïssa near 50% so eval changes are measurable.
  **Default Colossus is SATURATED** (Caïssa ~72%, flip-chaos noise) and raising its level
  is blocked by a bitmap-menu wall — so tune vs SF, reserve Colossus for final sanity.
- **Self-play A/B + SPRT:** `cref selfplay --weights-a "" --weights-b "spec" --depth D
  --games N --jobs 10 --openings data/openings_big.txt [--sprt]`. (Caveat: self-play can
  UNDERSTATE a term's value vs a tactical opponent — cross-check vs SF.)
- **Texel tuning:** `tools/texel_tune.py`, `tools/build_texel_dataset.py`,
  `cref mse TSV [weights]` (bit-exact full-eval oracle, seconds feedback). For a rewrite,
  build a dataset that **includes king-danger / sharp positions** (the current dataset's
  blind spot).
- **evaldiff vs Stockfish-d18:** `/tmp/evaldiff.py` (compares Caïssa search-eval to SF18,
  exposes systematic optimism — e.g. +220-300cp on king-exposing moves). Re-create for
  any eval hypothesis.
- **Speed/size gate (bit-exact + cyc/move):** `bash tools/llvmmos_bench/speed_gate.sh`
  (PERFT + eval 22157/22157 + golden 50/50 d4+d6 + 6502==cref_mos + cyc/move). Profiler:
  `tools/llvmmos_bench/caissa_prof "FEN" DEPTH [SYMBOL]` (per-fn + in-fn PC histogram).
- **C-vs-6502 port:** any eval change is C-first (`src/eval.c`), then the asm monolith
  `src/eval_full_6502.s` must be re-derived (validator: `tools/eval_corpus_check.py`,
  build via `tools/llvmmos_bench/build_eval_validator.sh`). The bring-up method that
  worked for the eval_full monolith is in `docs/eval-asm-scope.md` + memory.

## 5. Hard constraints for the rewrite

- **Data-driven:** measure (SF gradient + SPRT + evaldiff) before shipping anything.
- **Shallow-depth focus:** the eval must help at d3-d4 (where the chip plays), not just
  deep. Test at d4 (and d3) vs SF, not only d6.
- **6502 size + the asm monolith:** `eval_full_6502.s` is hand-asm; a richer eval = more
  asm + more image bytes (C64 RAM budget: was ~3979B free). Size is a tracked needle.
- **Competing with a mature eval:** Colossus 4.0's eval is strong (~1700-1800). Realistic
  payoff for a clean rebuild ≈ +50-150 Elo at shallow depth; it won't 2× the engine.
- **Bit-exact where possible:** pure-structure changes that don't move shipped weights can
  stay golden-validated; weight changes need SPRT/SF (not golden).

## 6. Open design questions for the brainstorm

1. **King-safety** (the biggest gap): attack-zone scoring (count + weight attackers near
   the king, scaled by attacker piece value), pawn-shield/storm, open-file-near-king,
   king-tropism — designed so it does NOT just make the engine passive (the failure mode).
   How to scale by game phase without the binary `endgame` gate's discontinuity.
2. **Mobility** — currently halved (a +41 Elo win earlier); is the structure right?
3. **Pawn structure** — passed/connected/isolated/backward, properly weighted (mostly
   weight-0 today).
4. **Piece coordination / outposts / rook activity** — currently thin.
5. **Tuning strategy** — Texel on a richer dataset (with king-danger positions) vs SPRT
   hand-tuning; which terms to tune jointly.
6. **Validation plan** — SF gradient at d3/d4 + evaldiff gap-closure + SPRT, before the
   6502 asm port.
7. **Scope** — incremental term-by-term rebuild (safer, measurable each step) vs a
   from-scratch positional eval. Recommend incremental + SF-gated per term.

## 7. Pointers

- Memory: `[[colossus-match-harness]]` (king-safety saga + depth=+100/ply + yardstick),
  `[[speed-campaign-cref]]` (speed levers, all tapped/assessed), `[[data-driven-mandate]]`,
  `[[strength-campaign-2026-06]]`, `[[onchip-1800-campaign]]`, `[[reference-engine-tier3]]`.
- This session committed: `e1ffbb8` (promo-piece fix + cref eval-A/B driver),
  `a7dcc14` (ponder/no-commit PV-recovery). Engine `src/` is clean (all eval/speed
  experiments reverted). Tune-via-host-cref-vs-Colossus: `CAISSA_ENGINE=cref
  CAISSA_WEIGHTS="spec" python3 tools/match_fast.py`.
