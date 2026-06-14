# Caïssa — Engine Strength Campaign Handover

Last updated: 2026-06-14 (end of the eval-pivot session). Read this first when resuming.

## Mission
Make this 6502/C64 chess engine (**Caïssa**, repo id `caissa`) strong enough to
**beat Colossus Chess 4** (~1600-1700). Engine is ~754 Elo on the Stockfish
proxy ladder. Colossus is concentrated 1985 chess expertise in tight 6502; the
gap is chess knowledge in the eval, not magic. Clean-room: learn IDEAS from
Colossus's PLAY, NEVER copy its code/tables/book (build/colossus_extract).

## ★★★ THE PIVOT (this session) — READ THIS FIRST ★★★
**The engine is EVAL-QUALITY bound, NOT search-bound. Conclusively proven.**
The old "eval-bound, tune weights" framing was wrong on both counts: weights are
tapped out, AND the real issue is eval *knowledge*, not the search. Evidence
(all measured this session):
- **Depth barely pays: d6-vs-d3 self-play = +64 Elo total ≈ +21 Elo/ply** (a
  sound engine gets +50-100/ply). Deeper search optimizes a coarse eval → small
  gain.
- **Move ordering is GOOD** (~93% first-move beta-cutoff; target >90%).
- **TT is NOT a lever**: 256 entries → ~8.6% hit; grown to 2048 → ~13% (plateaus,
  small re-probe working set); a 2048-vs-256 d6 A/B scored 48.1% (-13 Elo). A
  bigger table at the 16-bit hash adds false-hit exposure. Not worth it without a
  wider hash, and even then minor.
- **Eval is ~4.5K cycles/call** (NOT the 446K the old handover claimed) → we are
  NOT node-starved; we DO reach depth 6 (~1.75B cyc, ~200-400k nodes).
- Per-node speed is tapped (a bit-identical 6510 pass got +3.7%).

**Conclusion: stop search/weight work. The campaign is now EVAL QUALITY — add
structural positional knowledge (king attack, pawn levers, piece coordination,
prophylaxis, etc., clean-room Colossus ideas), measured on the fast loop.**

## NEXT MOVE (teed up, user wants it): native reference engine for lightning game-Elo
User: "i want that instant game-elo.. games to play lightning fast so that we can
tune and test quickly." Build **Tier 3** of `docs/fast-iteration-plan.md`:
- **What:** the bit-exact eval oracle (`tools/texel_eval.py`, `eval_full`) + a
  native search (negamax + alpha-beta + quiescence + simple TT + MVV-LVA) on
  python-chess → reference-vs-reference self-play at native speed. Reuse the
  SPRT/adjudication logic from `run_selfplay_match.py`.
- **Fidelity contract:** eval BIT-EXACT (done — the oracle), search just
  REPRESENTATIVE (a better eval helps any reasonable search; the 6502 confirms
  winners).
- **Speed reality (honest):** python reference ≈ MINUTES/A/B (cheap DEEP search:
  python d6 ~1-5s/move vs emulated 25s = ~5-25×; no emulator). TRUE lightning
  (sub-second A/B, 1000s games/sec) needs a C port = big build.
- **Recommendation: python-first.** Reuses the oracle, builds in one session,
  proves the critical thing — do reference-measured eval changes transfer to the
  6502? Then port hot path (eval+movegen) to C only if minutes isn't enough.
- First milestone: reference picks sane moves + an A/B runs in minutes; measure
  transfer vs a known 6502 result (e.g. the mobility-halve +41); then decide on C.
- OPEN QUESTION for the user: python-first vs straight-to-C.

## The fast-iteration loop (BUILT this session — use it)
`docs/fast-iteration-plan.md`. Loop: **oracle (seconds) → d3+SPRT (minutes) →
d6 (rare)**.
- **Texel oracle** `tools/texel_eval.py`: FULL eval ported to python, **bit-exact
  6700/6700** vs engine `lazy=0`. `eval_full(chess.Board(fen))` = engine eval.
  Weights are module globals → numpy-fit vs the 22k SF-labeled positions
  (`build/texel_data.json`) in SECONDS, write tuned weights back to eval.s/pst.s.
  Proxy (MSE-vs-SF), so it's a FILTER; confirm with self-play.
- **Self-play** `tools/run_selfplay_match.py`:
  - `--sprt` (GSPRT early-stop, H0:elo=0 vs H1:elo=`--sprt-elo1` default 30;
    clearly-bad change dies in ~15-20 games; marginal/near-neutral runs to cap).
  - `--difficulty-a/-b` (per-side depth; the d6-vs-d3 experiment).
  - `--adjudicate-streak N` (default 6; cut decided games short — makes d6 viable).
  - Two-tier: screen `--difficulty hard` (d3, ~minutes) + `--sprt`; confirm
    finalists `--difficulty beast` (d6, hours, rare). Use
    `--start-fen-file tools/selfplay_openings.txt` (48 diverse FENs); the default
    6-FEN set is degenerate at d6.
- **Profiler:** bridge bestmove with `"profile":true` returns `pcSamples`
  (PC histogram, bucketed every 1024 cyc); attribute to routines via `.sym`
  (`/tmp/prof2.py` pattern). Also `depthCycles`/`searchCompletedDepth` in every
  bestmove reply (EBF + does-it-reach-depth).

## First eval lever found (and a caveat)
`157b286` fixed a real bug: `ApplyPinnedAttackPressure` clobbered the king-square
zp `$f0` and never restored it → multi-pin positions dropped pins after the
first. Fix: the ray loop re-derives the king origin each direction. Regression
test `eval-detects-multiple-king-pins` (engine_core.6502). BUT the d3+SPRT
game-test was 47.0% / -21 Elo inconclusive — a "mildly load-bearing bug":
correct detection applies MORE pin penalty, so **the pin penalty weight is now a
touch overweight → retune via the oracle (good first oracle job).**

## Engine strength now: ~754 Elo (unchanged; this session was diagnosis + tooling)
This session banked NO board Elo — it was the strategic pivot + the fast-iteration
infrastructure that makes the eval campaign tractable. The strength gains come
NEXT, from eval knowledge measured on the fast loop.

## Session commits (8, `f9f29bf`→`157b286`)
- `65a35d4` Part B — eval rescaled to literal centipawns (pawn=100), move-identical
  (verified eval×10-exact + best-move-identical). Unlocks sub-10cp resolution.
- `c60dc6d` d6 self-play instrument (`--adjudicate-streak`).
- `dfcdaed` search profiler + `--difficulty-a/-b`.
- `f4c42ef` bit-identical speed pass (+3.7%, attack/eval/movegen SMC).
- `1a096ab` SPRT early-stop + fast-iteration plan.
- `979d3ea` Texel oracle — full eval bit-exact.
- `34146ec` TT_SIZE host-configurable (default 256 byte-identical; nova-safe);
  concludes the search-soundness hunt.
- `157b286` pin-bug fix + regression test + oracle re-sync.

## Architecture facts you need
- **Eval scale (Part B):** literal centipawns, pawn=100, all weights ×10 of old.
  PSTs are 16-bit (`_Lo`/`_Hi`). King safety still accumulates in a SIGNED BYTE
  that WRAPS past ±127 then ×10 (load-bearing; the oracle reproduces it). Eval is
  16-bit signed in `EvalScore`/`EvalScore+1`, white-POV.
- **Score ABI (Part A):** 16-bit two's complement, lo in A / hi in `$ec`. zp pairs
  score `$eb/$ec`, alpha `$e8/$ed`, beta `$e9/$ee`. MATE_SCORE=30000 flat,
  STATIC_EVAL_LIMIT=29000, NEG_INF `$8080`, POS_INF `$7f7f`. Direct Negamax/Quiesce
  test callers must set hi window bytes `$ed`/`$ee`.
- **TT:** 256 entries × 8 bytes at `$C800` (TT_SIZE/ENGINE_TT_BASE host-
  overridable; default unchanged). 16-bit hash verification. Not a lever (see pivot).
- **MAX_DEPTH=8.** LEVEL_BEAST (`--difficulty beast`) = depth 6 (harness-only,
  exempt from the headless depth-3 cap). At ~3B cyc budget it completes depth 4-5
  in real midgames (nominal "depth 6" is optimistic).
- Engine owns zp `$02-$37`, `$e0-$fe`. ca65, stock 6502 (NO 65C02). Two builds:
  engine (`make engine-build`) and rules-only (`CHESS_RULES_ONLY`).
- **nova chess** (`~/Git/e6502`, `examples/novachess`) VENDORS a snapshot of this
  engine and provides 2KB host RAM for the TT. Keep TT_SIZE default 256 so
  re-vendoring is unaffected. Strength is measured HEADLESS, not on the C64 build.

## Build / test / measure
- `make engine-build` — headless PRG. **NEVER `make clean`** (rm -rf build/ wipes
  irreplaceable build/colossus_extract). Needs Docker/OrbStack for sim6502.
- `make test` (6 suites) / `make benchmark` (9 cycle gates) — keep green.
- Colossus corpus gate (8/8 top1): `python3 tools/run_stockfish_strength.py
  --runner-target headless --c64-backend sim6502 --corpus tools/colossus_blunders.json
  --difficulty hard --stockfish-depth 8 --multipv 3 --jobs 4 --timeout-cycles
  750000000 --json build/cb.json`.
- **Verifiers (keepers):** `tools/verify_eval_rescale.py` (eval == base×N over a
  dataset; factor 1 = unchanged), `tools/verify_moves_identical.py` (two builds
  pick same moves — catches attack/movegen/search changes the eval verifier can't).

## Beast (remote compute, `ssh beast`, 32-core)
- `~/Git/chess6502-engine` is an **rsync target, NOT git** (no ca65). Build
  locally, then `rsync -az build/*.{prg,sym} beast:.../build/` + `rsync -az
  src tools beast:...`.
- **GOTCHA: ALWAYS `rsync tools/run_selfplay_match.py` to beast after editing it
  before launching A/Bs** — a stale runner silently fails argparse (no `--sprt`)
  and produces no games.
- **GOTCHA: backgrounded python block-buffers stdout** → `nohup ... > log` shows
  no progress until flush/exit; rely on the result JSON as the done-signal. (The
  per-game line now flushes, `157b286`, but other prints don't.)
- Per-move d6 cost ≈ 25s emulated (~100 MIPS). 26 jobs. d3 self-play ≈
  minutes/A/B; d6 ≈ ~1-1.5 hr/A/B.

## Measuring vs Colossus (unchanged from before)
- RAW backend BROKEN (corrupts Colossus). VICE backend WORKS:
  `run_colossus_match.py --colossus-backend vice` (x64sc remote monitor). Our side
  via the sim6502 bridge = the headless build. Task #9 (full VICE game vs Colossus)
  still open — the real verdict, now with eval work pending.

## Constraints (hard rules)
- Clean-room (ideas from PLAY, never code). Binds agents.
- Fix flaky tools at the source before leaning on them (user directive).
- One src-editing agent at a time (shared `.s` files). Never `make clean`.

## Open tasks
- ★ NEXT: build the native reference engine (Tier 3) for lightning game-Elo
  (python-first recommended; user to choose python vs C).
- Eval quality: retune the pin penalty weight (oracle); add structural positional
  terms (clean-room Colossus ideas) via oracle → d3+SPRT → d6.
- #9 full VICE game vs Colossus; #11 repo rename to caissa + display name in
  README/banner/PGN tags.

## Memory pointers (~/.claude/.../memory/)
strength-campaign-2026-06.md (full session-by-session detail — the pivot section
is the latest), beast-remote-setup.md, colossus-raw-emulation-bug.md (VICE),
colossus-cleanroom-boundary.md, engine-name.md, zobrist-hash-entropy-bug.md,
MEMORY.md (index). docs/fast-iteration-plan.md in repo.
