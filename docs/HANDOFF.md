# Handoff — resume here

_Last updated: 2026-06-17 (fastcolossus diff grind). Read this first, then `docs/ARCHITECTURE.md`._

## The goal
Get **Caïssa to beat Colossus 4.0 on a real C64**, and tune against Colossus in a
**rapid cycle — games in seconds/under a minute, not overnight**.

## ★ SPEED PIVOT (2026-06-17) — read this first
The VICE match harness below WORKS but is **unusably slow for tuning**: headless
VICE warp does **not** accelerate — it runs ~realtime (~1 MHz): a Caïssa depth-6
move is **225s**, depth-4 is 16s, so a full game is many minutes-to-hours. No flag
(`-warp`/`-speed 0`/`+sound`/`-soundwarpmode 0`) fixes it. **VICE is out for speed.**

The same 6502 binary on the **fast functional core (`cpu6502.c`)** runs **75–660×
faster**: Caïssa depth-6 = **3.25s** (`caissa_cli`), depth-4 = 0.22s. So the live
work is **`tools/fastcolossus/`** — run Colossus on that core too (a C port of the
old C# raw runner). Once it plays `1.e4 → e7e5`, drop it into the match loop
(Caïssa via `caissa_cli`) and games run in **seconds**.

## ★★ RESUME HERE — fastcolossus differential-trace grind
**THE active task.** Colossus boots + renders on the fast core but stalls (it reads
move input fine, then hangs in a board-redraw loop). We hunt the emulation bugs by
**differential trace vs VICE** — and it WORKS, grinding through bugs one at a time.

**The loop:** `tools/fastcolossus/vice_diff.py [N]` boots VICE (`/tmp/x64sc_stable`),
`bload`s the SAME `ready.ram.bin` both into VICE and the fast core, identical setup
(`$01=$36`, regs, pre-poke `'2'`, `r fl=23`, FCBASECYCLE phase-align), single-steps
both, and prints the **FIRST instruction where PC/regs diverge** (VICE = truth).
→ read the divergent instruction → fix the fast core's I/O/CPU → re-run → repeat
until no divergence, then `1.e4 → e7e5`.

**Bugs found+fixed so far (each via the diff):**
1. **Static TOD** — `$DC08` (CIA Time-of-Day, tenths) returned a frozen value;
   Colossus polls it for its clock → THE stall. Now advances from cycles.
2. **Banking** — was `$01=$37` (BASIC ROM in); Colossus runs **BASIC OUT**
   (`$01=$36`: `$A000–$BFFF` = its RAM variables, it `STA $B491`). Fixed both sides.
3. **Cycle align** — VICE's chip state isn't reset by `bload`; `vice_diff` reads
   VICE's cycle count and passes `FCBASECYCLE` so TOD/timers share phase.

**NEXT divergence to chase:** `$4C08 INC $B43B` (N flag). My core's result
(`0xd1→0xd2`, N=1) looks correct → VICE's `$B43B` differs, so one more banking/load
nuance. Peek VICE's `$B43B` at that step (`m b43b b43b` after stepping there) vs the
snapshot (`ready.ram.bin[$B43B]=0xd1`) to see which is off.

**Commands:**
- Diff: `python3 tools/fastcolossus/vice_diff.py 600` (N = instructions to trace).
- Fast core alone: `tools/fastcolossus/fastcolossus [max_cycles]` (from repo root);
  rebuild: `cc -O2 -I tools/fast6502_bridge tools/fastcolossus/fastcolossus.c
  tools/fast6502_bridge/cpu6502.c -o tools/fastcolossus/fastcolossus`.
- Instruments (env): `FCDEBUG`/`FCFINE` (step trace), `FCTRACE=N`, `FCRING`
  (ring + trace at first `$5645`), `FCKB` (keyboard feeds), `FCHASH=N`+`FCEMIT`
  (deterministic trace for the diff), `g_ioreads` histogram, undoc detector.

**GOTCHAS:**
- The in-`~/Git/vice-macos` headless `x64sc` **kept getting wiped** (something
  cleans the tree). Rebuilt to **`/tmp/x64sc_stable`** + full tree **`/tmp/vice_stable`**;
  `vice_diff` prefers those. To rebuild if gone:
  `cd ~/Git/vice-macos/vice && ./configure --enable-headlessui --disable-html-docs
  && make -k -j8 ; cp src/x64sc /tmp/x64sc_stable` (the `make` rc=2 is the unrelated
  x64dtv variant — `x64sc` still builds; copy it IMMEDIATELY).
- VICE `z` reports state AFTER the step; `vice_diff` prepends the known initial state
  to realign to "before instr i". `r fl=23` sets flags; `r a=00` etc. set regs.
- Snapshots: `build/colossus_extract/runtime/ready.ram.bin` (RAM) +
  `ready_cpu.ram.bin` (CPU-view, for ROM/IO). Ready PC = `$F155`, SP=`$F5`.
  Chargen ROM loaded from `~/Git/vice-macos/vice/data/C64/chargen-901225-01.bin`.
- Already ruled out as bug classes: undoc opcodes (none executed), JSR/RTS off-by-one,
  PHP/PLP/PLA/RTI flag quirks — `cpu6502.c` core is solid there.
Full play-by-play: `tools/fastcolossus/NOTES.md`.

## Where we are (merged to `main`, all commits green, not yet pushed)
The whole Caïssa-vs-Colossus match harness is **BUILT and PROVEN end-to-end**.
A real game was played headlessly: `1. d4 d5  2. Bf4 Nf6  3. Nc3 e6` (legal,
sensible, PGN emitted). The four pieces:

1. **`apps/c64/caissa_server.c`** (`tools/build_caissa_server.sh` →
   `build/caissa_server.prg`) — a **persistent** headless C64 bestmove server:
   boots ONCE, then loops forever serving one move per request over a pure-RAM
   handshake (`g_fen`, `g_depth`, `g_go`/`g_done`/`g_ready`, `g_from/to/promo/
   score/nodes`). Same `src/` engine + same C64 asm config as the shipping game;
   search setup identical to the validated fidelity driver so moves match host
   `cref`. Builds at 28.8KB / 10.5KB free.
2. **`tools/vice_caissa.py`** — VICE driver for the server. Boots
   `caissa_server.prg` in `x64sc`, waits `g_ready`, pokes the FEN+depth, polls
   `g_done`, peeks the move — all over the x64sc text monitor (`bank ram`).
   Port-parameterised (default **6511**). Reads ABI addresses fresh from the
   `.map`. PROVEN: `bestmove "<startpos>" 4` → `d2d4 score 0 nodes 1808`
   (boot→ready 11s, full move 34s in warp).
3. **`tools/vice_colossus.py`** (kept, unchanged) — drives real Colossus 4.0 in
   headless VICE (monitor **6510**): `inject_move`, `wait_for_ply`,
   `read_screen`/`screen_move_entries`, `disable_prediction`, relaunch-replay.
4. **`tools/match_caissa_colossus.py`** — the game loop. python-chess board is
   the source of truth; Caïssa=White (server), Colossus=Black (scrape);
   legality fail-loud; emits PGN + per-ply Caïssa score/depth/nodes.

Earlier this session (steps 1–2 of the old handoff): renamed `engine6502`→
`caissa` in `tools/llvmmos_bench/`; ripped the dead sim6502/ca65 measurement
harness (−6130 lines), repointing the two kept tools; fixed `make c64` (reorg
had left `build_c64.sh` pointing at `src/c64chess.c`). `make verify` + `make
gate` green throughout (50/50 fidelity, eval 22157/22157, golden match).

## How to run a match
```
tools/build_caissa_server.sh                 # -> build/caissa_server.prg
# make sure only ONE Colossus is on monitor 6510 (pkill -f 'x64sc.*coloss')
tools/match_caissa_colossus.py --depth 4 --max-plies 80 --pgn build/game.pgn
```
Single quick driver smoke-test (no match): `tools/vice_caissa.py bestmove "<FEN>" 4 --verbose`.

## NEXT SESSION — scale + tune (each: verify, commit on a branch)
1. **Play a full game to a result** (`--max-plies 200`), confirm draw/mate
   adjudication and PGN. ~30–60s/Colossus-move in warp → a full game is long;
   run it backgrounded.
2. **Known harness gaps to close before serious measurement:**
   - **Colossus think-time is unbounded** (it plays at its default level when
     ready). The retired `run_colossus_match.py@4e925d4` used an **'M' move-now
     keypress** to bound per-move time — port that in if games run too long, or
     set a fixed Colossus level. Without it, strength is at Colossus's full
     strength but slow.
   - **Colossus per-ply stats not scraped.** The screen shows `Lookahead`/
     `Positions`/`Score`; capture them into the PGN for analysis (the handoff
     wanted this). `vice_colossus.read_screen()` already has the text.
   - **Caïssa is White only.** Color-switch (Caïssa as Black) needs Colossus
     told to move first; not automated (same limit as the old harness). Needed
     for color-balanced match pairs.
   - **Promotions inject only the from-to** (`inject_move` is 4-char); Colossus
     auto-queens. Fine for most games; revisit for underpromotions.
3. **Scale** across cores (the beast is 32-core but has **no VICE** — build
   headless VICE there too, `--enable-headlessui`). Parameterise both monitor
   ports per worker so N matches run in parallel (Caïssa already takes `--caissa-
   port`; `vice_colossus` hardcodes 6510 → parameterise it for parallelism).
4. **Tune** Caïssa's eval/search vs Colossus with SPRT over the match results.

## Key facts / commands / paths
- Host engine + tests: `make` / `make verify`. 6502 fidelity+speed gate:
  `make gate` (~3 min). C64 game: `make c64`.
- 6502 fidelity rig: `tools/llvmmos_bench/build_caissa.sh` → `/tmp/caissa.sim`;
  `caissa_cli bestmove "FEN" D` (fast6502 = unit-test path).
- **Headless VICE: `~/Git/vice-macos/vice/src/x64sc`** (built with
  `--enable-headlessui --disable-html-docs`). Both drivers default to it.
- Colossus assets: `build/coloss40_rebuilt.d64`, `build/colossus_extract/`.
  **`build/colossus_extract/` is IRREPLACEABLE** (canonical backup on beast
  `~/Git/chess6502-engine/build/colossus_extract`). **NEVER `rm -rf build/`**
  (`make clean` only removes binaries).
- llvm-mos `as` **silently mis-assembles `#<(-N)`** (drops the negation) — write
  explicit wrapped bytes. Grep new asm for `#<(-` before commit.

## Memory pointers (auto-loaded)
`engines-map`, `colossus-match-harness` (this plan — now BUILT), `engine-ui-api`,
`speed-campaign-cref`, `onchip-1800-campaign`.
