# Handoff — resume here

_Last updated: 2026-06-18 (FULL Caïssa-vs-Colossus games run on the fast core in ~66s). Read this first, then `docs/ARCHITECTURE.md`._

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

## ★★ RESUME HERE — FULL Caïssa-vs-Colossus GAMES RUN ON THE FAST CORE (seconds)
**The match harness is BUILT and PROVEN end-to-end** (commit `67a4a0b`). A complete
40-move (80-ply) game plays in **~66s**, both engines on the fast 6502 core, no
realtime-VICE bottleneck. Caïssa won convincingly (promoted a queen).

Run it:
```
tools/match_fast.py --depth 4 --max-plies 200 --pgn build/fast_game.pgn
tools/match_fast.py --selftest        # 1.e4 -> e7e5 (smoke test)
```
- **Caïssa = White** via `tools/llvmmos_bench/caissa_cli` (`bestmove FEN DEPTH`).
- **Colossus = Black** via `tools/fastcolossus/fastcolossus server` (persistent;
  one live Colossus across the whole game, no reboot per move).
- python-chess = legality/result truth. Reuses `vice_colossus.py`'s scrape
  (`screen_move_entries`) + inject recipe.

**Server line protocol** (`fastcolossus server`, stdin/stdout, hex):
`K b..`=enqueue keys · `R n`=run n cycles · `P addr b..`=poke RAM · `M addr len`=dump
RAM · `Q`=quit.

**Two Colossus quirks pinned + handled (don't regress these):**
1. Move input must be poked **all 6 bytes at once with `$C6=6`** (the vice recipe);
   the one-key-at-a-time drain feeds move 1 but is silently dropped from move 2 on →
   move list freezes.
2. Once Colossus deepens (Lookahead≥3) it **PONDERS** after its move; the
   interrupt-poll drains+discards a buffered keystroke, so a single inject is lost.
   `submit_move()` re-injects while the buffer is drained until White's move echoes
   on the list, then clears leftover keys and waits for the reply. (`$B49B=0`
   prediction-disable alone did NOT stop the ponder key-eating.)

**NEXT — scale + tune (the whole point of the speed pivot):**
1. **Bound Colossus think-time.** In the endgame Colossus deepens and a single move
   eats minutes of emulated time (Black clock hit ~10 min/move), so long games drag.
   Options: set a fixed Colossus level, or port the **'M' move-now keypress** from
   the retired `run_colossus_match.py@4e925d4`. Pick the lever, wire it in.
2. **Caïssa-as-Black / color balance** for fair match pairs (Caïssa is White-only).
3. **Scrape Colossus per-ply stats** (`Lookahead`/`Positions`/`Score` are on screen)
   into the PGN for analysis.
4. **Parallelise** (the server is just a subprocess — no monitor ports, unlike VICE)
   and **SPRT-tune** Caïssa's eval/search against Colossus results.

(Old VICE harness below still works but is realtime-slow; the fast core supersedes
it for tuning. The `vice_*` drivers remain the fidelity oracle.)

**Grind history (each bug found via the diff, all fixed):**
1. **Static TOD** — `$DC08` (CIA Time-of-Day, tenths) returned a frozen value;
   Colossus polls it for its clock → the stall. Now advances from cycles.
2. **Banking** — Colossus runs **BASIC OUT** (`$01=$36`: `$A000–$BFFF` = its RAM
   variables, it `STA $B491`). Fast core fixed.
3. **Cycle align** — `vice_diff` reads VICE's cycle count and passes `FCBASECYCLE`
   so TOD/timers share phase.
4. **(harness, last)** — the `$4C08 INC $B43B` "divergence" was a `vice_diff` BUG,
   not a core bug: poking `> 0001 36` under `bank ram` writes only the hidden RAM
   shadow and leaves VICE's live port at `$37` (BASIC IN), so VICE read BASIC ROM at
   `$B43B` (`$68`) while the fast core correctly read game RAM (`$d1`). Fix: write
   `$00/$01` under `bank cpu`. After that, 0 divergences in 6000 instrs.

**The diff loop (kept as the fidelity oracle):** `tools/fastcolossus/vice_diff.py [N]`
boots VICE (`/tmp/x64sc_stable`), `bload`s the SAME `ready.ram.bin` both into VICE and
the fast core, identical setup, single-steps both, prints the FIRST divergent
instruction (VICE = truth). Now reports "No divergence" up to N tested.

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
