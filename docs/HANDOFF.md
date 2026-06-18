# Handoff — resume here

_Last updated: 2026-06-17. Read this first, then `docs/ARCHITECTURE.md`._

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
old C# raw runner). **Colossus BOOTS and renders on the fast core at 32 M cyc/s**
(32× VICE); blocked on an input-handling emulation divergence (spins on $D900 I/O
reads). See `tools/fastcolossus/NOTES.md` — that bring-up (differential trace vs a
one-shot VICE oracle) is THE active task. Once `1.e4 → e7e5`, drop it into the
match loop (Caïssa via `caissa_cli`) and games run in seconds.

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
