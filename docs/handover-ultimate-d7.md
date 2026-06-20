# Handover — d7/~2040 on the Ultimate 64 (and Nova), via more RAM

> **UPDATE 2026-06-19 — the banking approach below was ABANDONED.** A custom
> `-Wl,-T` linker fragment to place the TT under the KERNAL displaced the
> `.basic_header` SYS stub from $0801 → a non-bootable PRG (caught only by booting
> it in VICE — structural checks all passed). **Shipped instead: the eager-ordering
> profile** — on a 64 MHz Ultimate the lazy-move-selection speed opt is unneeded, so
> dropping `g_score_pool` (`CREF_LAZY_SELECT 0`, ~1.5 KB) + `TT_BITS 7` reclaims the
> 2 KB overflow with the STOCK bootable linker, and `MAX_PLY 8` gives d7. Files:
> `src/memcfg.h` (`CREF_PROFILE_ULTIMATE` + `CREF_LAZY_SELECT`), `src/search.c`
> (eager/lazy `#if` in negamax), `apps/c64/c64chess.c` (level selector),
> `tools/build_c64_ultimate.sh`. VALIDATED: host gates green, **eager==lazy 0/50
> bit-exact @d5**, `build/chess_ultimate.prg` bootable + **boots & runs in VICE**
> (banner + level prompt rendered). Open: full move-reply not screen-scraped (VICE
> monitor flakiness, not a build bug); run `speed_gate.sh` (unchanged) then merge.
> The under-KERNAL/REU banking is the path to a BIGGER TT later (TT7→TT12+ = the
> −15-25% node win) — revisit with a complete (non-additive) link script or REU DMA.



**Date:** 2026-06-19
**Goal (user):** hit **~1900–2040 on the 64 MHz Ultimate 64** at normal time
controls = "end all debate." Also serve the 12 MHz Nova at seconds/move.

## The reframe that changed everything (measured, not assumed)
We stopped chasing Colossus's 20M cyc/move on a *1 MHz* chip (wrong fight). On the
real target hardware the engine **as-is already gets there**:

| depth | Elo | cyc/move (post-SEE, 30-FEN) | @64 MHz Ultimate | @12 MHz Nova |
|---|---|---|---|---|
| d4 | ~1753 | 131 M | 2.1 s | 10.9 s |
| d5 | ~1850 | 351 M | 5.5 s | 29 s |
| d6 | ~1942 | 1226 M | **19 s** | 102 s |
| d7 | ~2042* | ~4.3 B* | ~67 s* | — |

*d7 = ladder extrapolation (+~100 Elo/ply; d6 measured 1942). Confirm by measuring
cref at fixed d7 vs SF-1800 (host MAX_PLY=48 already allows it).

The cycle numbers are from the **cycle-exact sim = real hardware** (per NOTES: "real
HW path … cycle-exact = matches sim"). So **1900 (≈d6) is already in the bag on the
Ultimate at ~19 s/move.** d7 (~2040) is the "by a mile" target.

## This session's speed work (shipped, pushed to origin/main)
4 commits, **−38% cyc/move** (212.3→131.3 M on 30-FEN), all Elo-neutral, port-exact:
- `f05d624` SEE quiescence pruning default-on + a 16-bit-int fix (`1<<30` sentinel
  overflowed on llvm-mos and crippled SEE on-chip).
- `ba96889` SEE move ordering (demote losing captures).
- `e8edeb0` see() used[] memset kill + qsearch see() call-guard.
- (LMP / forward pruning was tried and **reverted** — −234/−58 Elo; depth-unsuited
  at d4. eval-strip is Elo-negative; lazy_margin tapped. The clean cyc levers at d4
  are done — see auto-memory `eval-rewrite-design.md`.)

## The blocker this exposed
- **`apps/c64/c64chess.c` was hardcoded `ENGINE_DEPTH 3` (~1605).** I added a runtime
  **level selector `read_level()` (1–6)** so one .prg = d6/1942 on Ultimate, d3 on a
  stock C64. **UNCOMMITTED** (the build below is broken, so it wasn't committed).
  The change: replace `#define ENGINE_DEPTH 3` with `ENGINE_DEPTH_DEFAULT 4` +
  `ENGINE_DEPTH_MAX 6`, add `read_level()` before `has_legal_move`, call it in
  `main()` into `int engine_depth`, pass `engine_depth` to `search_bestmove`.
- **`make c64` / `tools/build_c64.sh` OVERFLOWS 64K by ~2 KB** (.bss +2010, .noinit
  +2144). This is a **silent regression** from the session's RAM growth (g_score_pool
  1536 B + see static used[128] + eval tables). **THE GATE DOESN'T CATCH IT** — the
  llvm-mos gate uses mos-sim **flat memory** (no 64K ceiling). Process gap: add a
  C64 link-fit check to `speed_gate.sh`.
- **Do NOT reclaim RAM by dropping lazy move-selection** (eager ordering): `pick_best`
  is only 5.2% *because* lazy skips sorting the tail on β-cutoff; eager full-sorts
  every node → big speed regression. The RAM must come from elsewhere.

## The plan (user chose: more RAM → d7/~2040)
**Ultimate / stock C64 — the EASY path (do this first):**
1. **Bank out BASIC ROM** ($A000–$BFFF = 8 KB RAM normally shadowed; engine doesn't
   need BASIC). llvm-mos has C64 memory configs for this (set `$01` banking; use the
   appropriate `mos-c64-*` link config / a custom ldscript raising the RAM ceiling
   past $A000). That 8 KB absorbs the 2 KB overflow with room to spare.
2. With the headroom: **`CREF_MAX_PLY 7→8`** (enables d7; +~64 B for g_killer) and a
   **bigger TT** (TT_BITS 8→12/13 → more hits → fewer nodes → faster). These are the
   `CREF_PROFILE_*` knobs in `src/memcfg.h`. Consider a new `CREF_PROFILE_ULTIMATE`.
3. Bump the level selector to 1–7.
4. Build `chess.prg`, verify it fits + runs d6/d7 in the fast core (caissa_cli / sim).
5. Gate-validate any search-affecting change (bigger TT changes node counts but is
   Elo-neutral-or-up; re-bless golden if behavior shifts).

**Nova — the HARDER path (later):** Nova's lower 64K is only ~39.7 KB; its 512 KB
XRAM is windowed (4×256B at $BC00 via XmcWin*, or 64K banks via XMC_BANK $BA0C — see
`src/memcfg.h` notes and `~/Git/e6502`). A bigger TT on Nova needs the TT physically
placed in XRAM + windowed accessors (set window reg → read 12 B through $BC00 per
probe; tolerable since TT is probed ~once/node). This is real platform work; scope it
against the e6502 hardware docs.

## What's settled (don't re-litigate)
- **d7 = ~2013 Elo confirmed** (232/300 = 77.3% vs SF-1800, host cref). Ladder:
  d4 1753 / d5 1850 / d6 1942 / d7 2013. The engine **already smokes Colossus**
  (~1700) by +250-300 at depth — "max on 6502" = push depth as high as time allows.
- **Forward pruning is DEAD at every reachable depth.** LMP: d4 −58 Elo, d6 −55 Elo
  (300g each vs SF-1800). At d6 it cuts −34% nodes / 12-of-50 moves changed, but the
  −34% only buys ~+0.4 ply (~+45) < the −55 cost. Would need d10+ (unreachable).
  **Never revisit LMP / futility / razor.**
- **TT asymptote @d6** (clean TT-only, host C64-config): TT8→TT12 −15.2%, TT14 −23.3%,
  TT16 −25.4%; knee ~TT14 (16k entries = 192 KB → needs REU/XRAM). Stock-64K banked
  high-RAM fits only ~TT9-10 (~−8-12%).

## The MAX-RAM technique (worked out — this is the build)
The default `mos-c64` link.ld ALREADY unmaps BASIC (`INPUT(unmap-basic.o)`; RAM
$0801-$CFFF = 50 KB, includes the area under BASIC). The only remaining ROM is KERNAL
($E000-$FFFF, kept for CHROUT/CHRIN) + I/O ($D000-$DFFF). So the extra RAM is the
**8 KB under KERNAL**, reachable by banking KERNAL out *during the search* (search is
pure compute — no KERNAL calls; verified: I/O is only in c64chess.c's UI loop):

1. **Linker:** custom script = default link.ld + a `himem` region
   `ORIGIN=0xE000, LENGTH=0x1FFA` (to $FFF9, leave the $FFFA-$FFFF vectors) + a SECTION
   placing `.himem` there. Mark the TT (and other big tables) with
   `__attribute__((section(".himem")))`. This frees ~3 KB+ of low RAM (fixes the 2 KB
   overflow) and lets the TT grow into the 8 KB.
2. **Banking at the search call site** (c64chess.c, around `search_bestmove`):
   `SEI; save $01; $01=$34` (LORAM=0 BASIC-RAM, HIRAM=0 KERNAL-RAM, CHAREN=1 I/O-on)
   → $E000-$FFFF is RAM during the search; restore `$01=$36; CLI` after. SEI is
   required (KERNAL IRQ handler is banked out). Caveat: with KERNAL out the NMI vector
   reads RAM — RESTORE-key NMI during search would crash; set a RAM NMI stub or accept
   for the demo.
3. **memcfg:** new `CREF_PROFILE_ULTIMATE` (or extend C64): `MAX_PLY 8` (enables d7),
   `TT_BITS` sized to the himem region (~9-10 stock; 12-14 on REU/XRAM later).
4. **Level selector → 1-7.** Commit the (currently uncommitted) `read_level()` change
   together with the build fix.
5. **VALIDATE on the fast core, NOT the mos-sim gate** — the gate's mos-sim is FLAT
   memory and models neither the 64K limit nor $01 banking. The `tools/fastcolossus`
   cpu6502 core DOES model $01 banking (it handled BASIC-out in the Colossus work).
   Build chess.prg, drive it through the fast core (match_fast.py-style), confirm it
   plays correct moves move-for-move vs host cref at the same depth. THEN play it vs
   Colossus on the fast core to show the smoke.
6. **For the big TT (the −25% node win):** Ultimate REU ($DF00 DMA, up to 16 MB) or
   Nova XRAM (windowed $BC00 / banked $BA0C) — a separate, harder follow-on that holds
   TT12-14. Bounds the node lever at ~−25%.

## Confirm-the-payoff first (cheap, do before the build)
Measure **d7 strength**: `NATIVE_CREF=build/cref python3 tools/native_vs_stockfish.py
--native-depth 7 --sf-elo 1800 --games 300 --jobs 8` (host cref, MAX_PLY=48). If d7 ≈
2040, the build work is justified. (On-chip-config d7 needs MAX_PLY=8 in cref_mos/the
image — bump it in memcfg for the Ultimate profile.)

## Tooling recap
- cyc/move per depth: `/tmp/validate /tmp/caissa.sim /tmp/caissa.map <fenlist> <depth>
  /tmp/cref_mos` (image built by `tools/llvmmos_bench/build_caissa.sh`).
- Gate (bit-exact + cyc): `bash tools/llvmmos_bench/speed_gate.sh`.
- C64 build: `bash tools/build_c64.sh /tmp/chess.prg` (reports bytes free vs $D000).
- Strength: `tools/native_vs_stockfish.py` (cref_mos = on-chip config; cref = full).
- Full campaign detail: auto-memory `eval-rewrite-design.md` (the ★★★★★ HARDWARE +
  1900-ACHIEVED entry is the resume marker).
