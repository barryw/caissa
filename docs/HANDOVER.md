# Caïssa — Engine Strength Campaign Handover

Last updated: 2026-06-13. Read this first when resuming.

## Mission
Make this 6502/C64 chess engine (named **Caïssa**; repo identifier `caissa`, no
accent) strong enough to **beat Colossus Chess 4** and reach ~**1700 Elo**.
Colossus is a strong human-written 1985 C64 engine (~1600-1700). We are not
trying to beat Stockfish on a 6502 — Stockfish is only a measuring stick.

## Honest current strength
- **~713 Elo** on the Stockfish proxy ladder (0/48 vs SF 1320/1520/1720 at
  depth 5 and depth 6). **The engine is EVAL-BOUND, not search-bound** — depth 6
  scored identically to depth 5. Searching deeper into a coarse/wrong eval just
  reaches the same losing conclusions faster.
- The gap to 1700 is ~1000 Elo. No single change spans it. The order that
  matters: **eval quality > opening book > more depth.**

## What's solid now (committed, all gated: 6 test suites / 9 benchmark gates / Colossus corpus 8/8 top1)
Commit trail (newest first), `git log`:
- `96c9917` opening book DATA + generator + wire-plan (engine-independent half)
- `ba730c2` eval: penalize passive Ne2/Ne7 knight square (develops Nc3 now)
- `f6d53fe` VICE harness survives long Colossus games (persistent socket + recover)
- `9283927` **Part A: 16-bit signed search scores** (removed the ±10.9-pawn clamp)
- `9b68e36` serialize sim6502 bridge build with an flock (parallel-run reliability)
- `869d124` beast reaches depth 6 + fixed move-list-snapshot OOB
- `6c2d1a4` **VICE-hosted Colossus backend** (honest engine-vs-Colossus path)
- `db0351f` hard recursion ceiling at MAX_DEPTH (crash fix)
- `f0dd331` revert unsound quiescence move-list save/restore (crash fix)
- earlier: lazy eval, 6510 SMC tightening, legality guards, committed-best timeout,
  quiet-check-bonus removal, king-march penalty, LEVEL_BEAST.

Net: Caïssa is **correct, crash-free, legal-move-guaranteed, depth-6, 16-bit eval
resolution**, with a working way to measure against the real Colossus. All the
infrastructure blockers are cleared. The remaining work is on-board strength.

## THE key lesson (don't relearn the hard way)
**The tactical blunder corpus CANNOT validate positional eval tuning.** Positional
PST/weight changes shuffle tactical PVs and show up as corpus "regressions" that
are really noise — this forced the eval agent into a timid one-square fix.
**Tune eval against GAMES (ladder/VICE), not the corpus.** Build a faster
game-based eval feedback loop before doing serious eval tuning.

## Architecture facts you need
- **Score ABI (Part A, 16-bit two's complement):** lo in A, hi in `$ec` returned
  from Evaluate/EvaluateLazy/Negamax/Quiesce. zp pairs: score `$eb/$ec`, alpha
  `$e8/$ed`, beta `$e9/$ee`, q-standpat `$ea/$ef`. Hi bytes for per-depth state
  live in PARALLEL SearchDepth-indexed arrays (NegamaxBestHi/AlphaHi/BetaHi/
  OrigAlphaHi, QAlphaHi/QBetaHi/QScoreHi) — NegamaxState stride is UNCHANGED
  (+1/+6/+7 are the lo bytes). MATE_SCORE=30000 flat, STATIC_EVAL_LIMIT=29000,
  NEG_INFINITY pair `$8080`, POS_INFINITY `$7f7f`. **Any direct Negamax/Quiesce
  caller (tests!) must set hi window bytes `$ed`/`$ee`.**
- **Eval scale is still ~10cp/unit** (pawn=10). "Part B" (rescale to literal
  centipawns, pawn=100) is DEFERRED — it changes no moves by itself, only matters
  once you add sub-10cp eval terms. Don't do it until a term needs it.
- **MAX_DEPTH=8.** Negamax drops to quiescence at SearchDepth>=MAX_DEPTH (hard
  ceiling — prevents the stack/array-overflow crash class). Beast difficulty
  (LEVEL_BEAST=3) searches depth 6 (MaxDepthTable `.byte 3,4,6,7`).
- **LEVEL_BEAST** is harness-only (no UI), exempt from the headless depth-3 cap;
  moves cost billions of cycles. Harness uses `--difficulty beast --c64-timeout
  20000000000`; bridge returns committed-best move on timeout (no forfeit).
- Engine owns zp `$02-$37`, `$e0-$fe`. ca65, stock 6502 (NO 65C02 opcodes).
- Two builds: engine (`make engine-build`) and rules-only (`CHESS_RULES_ONLY`).

## Build / test / measure
- `make engine-build` — build headless PRG. **NEVER `make clean`** (it's
  `rm -rf build/` and destroys `build/colossus_extract/` — irreplaceable Colossus
  runtime; see hazard below). Needs Docker/OrbStack up for sim6502 tests.
- `make test` (6 suites, 90 tests) / `make benchmark` (9 cycle gates) — both must
  stay green for any change. Tightest gate headroom: hard-hanging-queen ~36k,
  rook-behind-passer ~65k cycles.
- Colossus corpus gate: `python3 tools/run_stockfish_strength.py --runner-target
  headless --c64-backend sim6502 --corpus tools/colossus_blunders.json
  --difficulty hard --stockfish-depth 8 --multipv 3 --jobs 4
  --timeout-cycles 750000000 --json build/cb.json` → must stay 8/8 top1.
- Probe one position: tools/sim6502_headless_runner.py (import Sim6502HeadlessRunner,
  repo_root_from_script; from run_stockfish_strength import DIFFICULTY, fen_to_c64,
  c64_encoded_move_to_uci).

## Beast (remote compute)
- `ssh beast` (192.168.1.3, 32-core Ubuntu). `~/Git/chess6502-engine` is an
  **rsync target, NOT a git repo** — no ca65 there. Build locally, then
  `rsync -az build/engine_harness.{prg,sym,dbg} beast:.../build/` + `rsync -az src
  beast:...`. Toolchain on beast: dotnet, stockfish, python-chess, sim6502 runner.
- Bridge parallel-build race is FIXED in code (`9b68e36`, flock) — no manual
  prebuild needed.
- Beast can reboot unexpectedly (physical). Monitors tolerate outages.
- Ladder: `python3 tools/run_elo_ladder.py --runner-target headless --c64-backend
  sim6502 --difficulty beast --c64-timeout 20000000000 --c64-side both
  --games-per-side 2 --jobs 12 --stockfish-elos 1320,1520,1720 --stockfish-depth 6
  --analysis-depth 12 --analysis-multipv 3 --start-fen-file
  tools/stockfish_opening_fens.txt --max-plies 120 --adjudicate-max-plies --json
  build/eloNN.json` (nohup + disown). Beast holds the canonical backup of
  `build/colossus_extract` + `coloss40_rebuilt.d64`.

## Measuring vs Colossus
- **RAW backend is BROKEN — do not trust it.** ColossusRawRunner (sim6502) corrupts
  Colossus's own play (answers checks with illegal moves; deterministic). Quarantined.
- **VICE backend WORKS and is the honest path** (`6c2d1a4` + `f6d53fe`):
  `run_colossus_match.py --colossus-backend vice`. Drives cycle-exact x64sc remote
  monitor; our moves from the sim6502 bridge, Colossus's from VICE, replies
  validated vs python-chess (fail loud on illegal). Survives long games now
  (persistent socket + relaunch/replay). Proven: `1.e4 e6 2.Ne2 d5 3.d4` (pre-fix)
  and a 10-ply hard game; Colossus plays sound moves.
- VICE recipe: `/usr/local/bin/x64sc -default -remotemonitor -warp -console
  -autostart "build/coloss40_rebuilt.d64:colossus 4.0-d"`; monitor TCP 6510;
  move inject = poke KERNAL buffer `> 0277 <rank><FILE>0d<rank><FILE>0d` + `> c6 06`;
  screen at $0400-$07E7; prediction off via `bank ram` / `> b49b 00`.

## HAZARD
`make clean` = `rm -rf build/` destroys `build/colossus_extract/` (Colossus runtime
images + PRGs — IRREPLACEABLE, original disk gone). It was wiped once this session
and recovered from beast + rebuilt the .d64 via c1541 from the 5 PRGs
("colossus 4.0-t/-d","part1/2/3"). **TODO: move colossus_extract OUT of build/ so
clean can't nuke it.** Beast is the backup of record.

## Constraints (hard rules)
- **Clean-room:** learn IDEAS from Colossus by observing its PLAY only. NEVER
  disassemble/copy its code, tables, eval, or book data (build/colossus_extract).
  Bind any agent you spawn to this.
- **Reliability:** fix flaky tools at the source before leaning on them (user:
  "fix shit until it's reliable before we run tests").
- Agents that edit `src/*.s` collide with each other (shared files + constant
  rebuilds) — run ONE src-editing agent at a time; parallelize only across
  non-overlapping dirs (src vs tools). Tell agents: never `make clean`.

## What's running right now
- **Ladder v7** on beast (`build/elo_v7.json`) — full stack (Part A 16-bit + Ne2
  eval fix). First real Elo read post-eval-work. Monitor armed.

## Next moves (priority order)
1. **Read ladder v7 result.** If still ~713, confirms eval needs deeper work via
   GAME-based tuning (build that loop). If up, the direction is working.
2. **Wire the opening book (task #12)** — the Colossus-killer, data is ready:
   compile `tools/opening_repertoire.json` (219 pos) → key-sorted blob using the
   engine's `ComputeZobristHash` via the bridge (16-bit keys, NEVER reimplement
   the hash), write the `LookupOpeningMove` probe (referenced platform_c64.s:63,
   undefined), wire `EngineLookupOpeningMove` in platform_test.s (stub clc/rts) for
   headless/VICE. Plan: `docs/opening-book-plan.md`. Engine stays strong without it.
3. **Eval-term tuning via GAMES** — PST/development/center/king-safety/mobility,
   validated on the ladder/VICE not the corpus. The real path to 1700.
4. **Perf backlog** (`docs/optimization-backlog.md`) — buys more depth: dead-code
   (QSave* ~650 bytes), cache SearchDepth*8 offset, Zobrist LUT reuse, etc.
5. **Repo rename to `caissa`** (task #11) + wire display name into README / banner /
   PGN [White] tag (currently "C64 AI") — do when tree quiet.
6. Run a full VICE game vs Colossus on the hardened harness (task #9) for the real
   verdict.

## Memory pointers (~/.claude/.../memory/)
strength-campaign-2026-06.md (full detail), colossus-raw-emulation-bug.md (VICE +
hazard), beast-remote-setup.md, colossus-cleanroom-boundary.md, engine-name.md,
MEMORY.md (index). docs/optimization-backlog.md + docs/opening-book-plan.md in repo.

## Open tasks
#4 analyze/improve (ongoing), #6 re-run beast matches, #7 stockfish tuning loop,
#9 full VICE Colossus game, #11 rename to caissa, #12 wire opening book.
