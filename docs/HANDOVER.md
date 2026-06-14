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
- **Nothing live. Beast idle.** Ladders v7 AND v8 both ≈ **713 Elo** (v8 = book +
  hash fix; book/hash moved ZERO game-level Elo). The **SF ladder is FLOORED at
  0/48** (engine ~600 Elo below SF1320) so it CANNOT measure sub-100-Elo eval
  gains — **use self-play A/B (`tools/run_selfplay_match.py`) for eval tuning**,
  ladder only as an occasional milestone check once we climb ~400 Elo.

## Engine strength now: ~754 Elo (713 + mobility +41)
+41 Elo banked this session (mobility). Eval is the wall, confirmed 3×.

## DONE this session: opening book wired (task #12) — `74db46e`
The book is **live in the headless/test build too** (not just C64), because our
ladder + VICE-vs-Colossus harnesses both drive OUR side through the sim6502
bridge = the test build. A C64-only book would never run in any harness.
- `src/ai/opening_book.s` — `LookupOpeningMove` 16-bit binary search (shared).
- `src/ai/opening_book_data.s` — AUTO-GENERATED, 198 entries (4B each, sorted).
- `tools/compile_opening_book.py` — drives the bridge `zobrist` command for each
  FEN's key (NEVER reimplements the hash), uci→0x88 from/to, dedup, sort, emit.
- Bridge gained a `zobrist` command + `searchUsedBook` in the bestmove reply
  (`Program.cs`); runner gained `.zobrist()` (`sim6502_headless_runner.py`).
- `platform_test.s` now `jmp LookupOpeningMove` / `jmp BookMoveAvoidsPawnAttack`
  (was clc/sec stubs) so headless plays the book like the C64 build.
- **search.s reorder:** the crude root positional heuristics
  (`TryRootOpeningCenterPawnMove`, `TryRootDevelopingBishopRecaptureMove`) were
  firing BEFORE the book and short-circuiting at depth 0 — book never ran. Moved
  them to fire only on a book miss; mate-safety + tactics still precede the book.
- Verified: 12/12 repertoire FENs hit (correct move, `usedBook=1`); 0/118 false
  hits in deep non-book positions (legality net is strong); 90 tests / 9 gates /
  8-of-8 corpus all green.

## DONE this session: Zobrist hash entropy fixed (task #13) — `29f5cd8`
`ZobristPRNG`'s "Galois LFSR step" ROTATED the 16-bit register (bit0→bit15)
instead of shifting bit0 out through the feedback tap — output collapsed into a
5-bit-per-byte subspace (~9.6 effective hash bits). Fixed to a correct Galois
shift (`lsr $fc / ror $fb`, XOR $B4 on carry). Measured over 1500 positions:
byte coverage **32 → 254/255**, distinct keys **780 → 1445** (~16 real bits),
book collisions **21 → 1** (book now 218/219 entries; recompiled). This also
removes a large class of aliased-position TT cutoffs the weak hash allowed —
may help the eval-bound weakness. All gates green post-fix. See
[[zobrist-hash-entropy-bug]]. **Recompile the book with
`tools/compile_opening_book.py` after ANY future key-affecting change.**

## DONE this session: eval-tuning loop + first lever + Texel infra
- **`tools/run_selfplay_match.py`** (`2fa3f0c`) — engine-A-prg vs engine-B-prg,
  N games from `tools/selfplay_openings.txt` (48 book-edge FENs), both colors,
  parallel; reports W/D/L + Wilson 95% + Elo-diff. A=B → exactly 50.0%. THE eval
  tuning signal (ladder is floored). Run on beast (26 jobs, ~28s/game, draw-heavy
  → ~300 games for a ±50 Elo read). `difficulty hard` headless = depth 3 (the
  depth-6 cap is LEVEL_BEAST-only) → fast.
- **`3d4e64e` mobility halved → +41 Elo.** `EvaluateMobility` applied raw square
  count at 10cp/sq UNCAPPED + uniform (queen +270cp → premature sorties). Halved
  (one lsr). Self-play 240g: 55.8% (+41). quarter/queen-quarter both worse → half
  is optimal.
- **Texel tuner built** (`12bc270` bridge `eval` cmd + verified Python eval port
  600/600 exact; `a1d684f` dataset gen + numpy optimizer). VERDICT: material+PST
  already near-optimal (~2% MSE headroom) AND 10cp granularity rounds fine tweaks
  away → not written back. Ready to pay off after Part B / porting other terms.
- **Lever hunt (self-play A/B, all reverted except mobility):** pawn-attack
  penalty halve = **-38** (load-bearing, compensates shallow search); doubled/
  isolated halve = **-2** (neutral). META: eval weights are mostly well-tuned;
  mobility was the lone gross error. Easy scalar-weight wins are TAPPED OUT.

## Next moves (priority order) — easy eval wins are done; structural work next
1. **Part B — centipawn rescale** (pawn=10→100, all eval constants ×10, widen to
   16-bit, re-verify 6 suites/9 gates/corpus). The recurring wall: unlocks
   granularity so Texel + fine terms actually bite. Then re-run Texel and/or port
   the other eval terms (mobility/pawn-struct/king-safety/pressure) into
   `tools/texel_eval.py` for a full automated tune. Modest direct gain, big enabler.
2. **Search depth** (`docs/optimization-backlog.md`) — buy depth 7+; eval-bound at
   depth 6 but deeper + decent eval compound. Different vein from eval.
3. **New eval terms / king-attack scaling** — structural additions, not scalar
   retuning (which is tapped out).
4. **Repo rename to `caissa`** (task #11) + display name in README/banner/PGN
   [White] tag (currently "C64 AI") — do when tree quiet.
5. Full VICE game vs Colossus on the hardened harness (task #9) — the real verdict
   (now with book live + hash fixed).

## Eval-tuning workflow (proven this session)
1. `cp build/engine_harness.{prg,sym} /tmp/base.{prg,sym}` (save current best).
2. Edit eval weight in `src/ai/eval.s` (or PST in `pst.s`), `make engine-build`.
3. rsync candidate + baseline to beast `build/`, run `run_selfplay_match.py`
   A=candidate B=baseline `--games 300 --jobs 26` (~6-12 min).
4. WIN (>50%, lower CI near/above 50) → corpus-gate + `make test`/`benchmark` →
   commit. LOSE/NEUTRAL → revert, rebuild. Dataset: `build/texel_data.json` (22k).

## Memory pointers (~/.claude/.../memory/)
strength-campaign-2026-06.md (full detail), colossus-raw-emulation-bug.md (VICE +
hazard), beast-remote-setup.md, colossus-cleanroom-boundary.md, engine-name.md,
MEMORY.md (index). docs/optimization-backlog.md + docs/opening-book-plan.md in repo.

## Open tasks
#4 analyze/improve (ongoing), #9 full VICE Colossus game, #11 rename to caissa,
#14 Part B centipawn rescale (NEW — granularity unlock for eval tuning),
#15 search-depth / perf backlog for depth 7+ (NEW).
DONE this session: #12 wire opening book (`74db46e`), #13 fix Zobrist PRNG
entropy (`29f5cd8`), eval self-play loop + mobility +41 (`2fa3f0c`/`3d4e64e`),
Texel tuner infra (`12bc270`/`a1d684f`).
