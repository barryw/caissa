# Handoff — resume here

_Last updated: 2026-06-17. Read this first, then `docs/ARCHITECTURE.md`._

## The goal
Get **Caïssa to beat Colossus 4.0 on a real C64**, and to do that we must be able
to **play Caïssa vs Colossus headlessly and measure/tune** against it (Colossus is
the bar, not Stockfish).

## Where we are (all on `main`, pushed, `make verify` + `make gate` green)
- **ONE engine** now: `src/` (portable C: board/movegen/eval/search + 6502 hand-asm
  hot paths incl. the `eval_full_6502.s` monolith). The old ca65 engine is deleted.
  Layout: `src/` engine · `apps/cli` (cref) · `apps/c64` (chess.prg + caissa_abi.c) ·
  `test/` · `tools/` · `data/` · `docs/` · `build/`. Top-level `Makefile`.
- **Engine↔UI API** shipped: `src/caissa.h` (+ `docs/API.md`) — new_game, state
  (mate/stalemate/draws), legal_moves, bestmove, commit/undo, ponder. Test in
  `make verify`.
- **eval_full asm monolith** shipped earlier: −12.3% cyc/move, −4.8KB, strength
  identical. (Speed frontier: depth at a real time control.)

## Strength reality (don't re-confuse this)
- `native` host engine: ~1785–1874 vs Stockfish (PC, not a C64 program).
- On-chip **move quality** ~1850 (direct, real 6502 binary vs SF) — but
  **speed-capped**: depth 6 ≈ hours/move on a real 1MHz C64.
- The old **~982** number was the now-DELETED ca65 engine — ignore it.
- **vs Colossus: never measured.** That's the next task.

## Decisions locked (do not re-litigate)
1. **Both engines play in headless VICE** (real C64, symmetric). The fast6502
   cycle-exact core (`tools/fast6502_bridge/cpu6502.c`) is **unit-tests-only** now.
2. **Rename `engine6502` → `caissa`** everywhere.
3. **Rip the old `sim6502` ca65 harness** (it was a unit-test tool for the dead
   engine), but **keep `cpu6502.c` (unit tests) and `vice_colossus.py` (reused)**.

## NEXT SESSION — execute in this order (each: verify, then commit on a branch)
1. **Rename** `engine6502`→`caissa` in `tools/llvmmos_bench/` (`build_engine6502.sh`
   →`build_caissa.sh`; `engine6502.c`→caissa driver; `engine6502_cli`→`caissa_cli`;
   `/tmp/engine6502.{sim,map}`→`caissa.{sim,map}`; refs in `validate.c`,
   `speed_gate.sh`, `build_and_run.sh`, `build_eval_validator.sh`, `gen_golden.py`,
   `profile6502.c`, `eval6502.c`, `.gitignore`, `NOTES.md`). Then `make gate` green.
2. **Rip** the dead sim6502 harness: delete `tools/Sim6502HeadlessBridge/`,
   `tools/ColossusRawRunner/`, `tools/sim6502_headless_runner.py`,
   `tools/fast6502_bridge/fast6502_bridge.c` (KEEP `cpu6502.c`/`.h`),
   `tools/run_colossus_raw.py`, old `tools/run_colossus_match.py` +
   `run_colossus_parallel.py`. Cascade: `run_selfplay_match.py`,
   `run_stockfish_strength.py`, `search_fidelity.py`, `compile_opening_book.py`,
   `verify_*.py` import `sim6502_headless_runner` → retire or repoint (old-engine
   measure tools). KEEP `vice_colossus.py`.
3. **Build the VICE match (the real work):**
   - **`caissa.prg`** — a headless C64 ABI *server* built with `mos-c64-clang` from
     the `src/` engine + a thin loop. PERSISTENT (boot once, loop serving moves —
     VICE boot is ~18s, must NOT re-boot per move). Expose RAM globals:
     `g_fen[100]`, `g_depth`, `g_go`, `g_done`, `g_from`, `g_to`, `g_promo`,
     `g_ready`. Model on `tools/llvmmos_bench/engine6502.c`'s ABI but C64 + looping.
     (See `tools/build_c64.sh` for the mos-c64-clang invocation + the asm gates.)
   - **`vice_caissa.py`** — VICE driver: boot `caissa.prg` in x64sc, then per move
     poke `g_fen`+`g_depth` and set `g_go=1` via the **x64sc monitor** (using the
     `.map` addresses), poll `g_done==1`, peek `g_from/g_to/g_promo`. RAM poke/peek
     is *cleaner* than Colossus's screen-scrape. Mirror `vice_colossus.py`'s robust
     boot/monitor handling.
   - **match loop** — boot `caissa.prg` in one x64sc + `coloss40_rebuilt.d64` in
     another; alternate moves on a `python-chess` board; legality fail-loud; play to
     result/maxplies; emit PGN + per-ply instrumentation (Caïssa: score/depth;
     Colossus: screen `Lookahead`/`Positions`/`Score`).
4. **Play a Caïssa-vs-Colossus game** end-to-end. Then scale (parallel across cores)
   + tune the eval/search vs Colossus (SPRT).

## Key facts / commands / paths
- Build host engine + tests: `make` / `make verify`. 6502 fidelity+speed gate:
  `make gate` (~3 min).
- 6502 image build: `tools/llvmmos_bench/build_engine6502.sh` → `/tmp/engine6502.sim`
  (will become `caissa.sim`). FEN→move CLI: `engine6502_cli bestmove "FEN" D`
  (becomes `caissa_cli`; fast6502 = unit-test path).
- **Headless VICE: built this session** at `~/Git/vice-macos/vice/src/x64sc`
  (`./configure --enable-headlessui --disable-html-docs && make -j`). PROVEN: boots
  Colossus headless and plays `1.e4`→`e7e5` (correct). `tools/vice_colossus.py` is
  the working driver (boot/warp/monitor/screen-scrape + relaunch-replay).
- Colossus assets: `build/coloss40_rebuilt.d64`, `build/colossus_extract/`.
  **`build/colossus_extract/` is IRREPLACEABLE** (original disk gone; canonical
  backup on beast `~/Git/chess6502-engine/build/colossus_extract`). **NEVER
  `rm -rf build/`** (`make clean` only removes binaries).
- Beast: 32-core Linux, **no VICE installed** there → massively-parallel matches
  need headless VICE built on beast too (it's C, `--enable-headlessui`).
- llvm-mos `as` **silently mis-assembles `#<(-N)`** (drops the negation) — write
  explicit wrapped bytes (`-0x10`→`#0xF0`). Grep new asm for `#<(-` before commit.

## Memory pointers (auto-loaded)
`engines-map` (canonical one-engine map), `colossus-match-harness` (this plan in
detail), `engine-ui-api`, `speed-campaign-cref`, `onchip-1800-campaign`,
`colossus-raw-emulation-bug` (raw runner SUPERSEDED — use headless VICE).
