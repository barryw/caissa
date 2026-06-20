# Big transposition table in XRAM/REU — design + measured payoff

**Date:** 2026-06-19 (REU validated end-to-end 2026-06-20)
**Status:** REU backing **validated on real emulation (x64sc -reu): d4 bit-exact to
host after fixing an IRQ-during-DMA bug — see "Validation (2026-06-20)" below.**
Nova backing still pending. Foundation on branch `xram-tt`.

> **Update 2026-06-20 — read this first.** The keystone link-drop the prior handover
> flagged (asm `is_square_attacked` dropped under REU/ULTIMATE) is **STALE**: the
> server, caissa.c mos-sim, and `chess_reu.prg` (c64chess.c) all link cleanly on the
> current toolchain (symbol present in every map). Two real findings replaced it:
> 1. **REU DMA bug FOUND + FIXED** — the `$DF00` register setup was non-atomic and
>    the live 60 Hz KERNAL IRQ corrupted it mid-search. `reu_xfer` now brackets the
>    setup in `sei`/`cli` (with a `"memory"` clobber). Result: the REU server is
>    **move+node bit-exact to the host oracle at d4** (was move-mismatch=1 / 11 node
>    diffs before the fix). The prior "validated on emulated hardware" only covered
>    the isolated `reu_dma_test` micro-test (write-all-then-read-all), which never
>    tripped the IRQ window — only a full search did. Classic "structural checks lie."
> 2. **"MAX_PLY-8 6502↔host divergence" — ROOT-CAUSED + FIXED. It was a HARNESS
>    build-config bug, NOT an engine bug. The shipped Ultimate 6502 is fine.** The
>    `memcfg.h` profile auto-default guard listed only NOVA/C64/HOST, so a **host**
>    build with `-DCREF_PROFILE_ULTIMATE`/`-DCREF_PROFILE_REU` fell through to
>    `CREF_PROFILE_HOST` (the `#if defined(CREF_PROFILE_HOST)` branch shadows the later
>    `#elif ULTIMATE/REU`). The **oracle** therefore silently compiled as HOST
>    (TT16/MP48/POOL8192) instead of the intended profile (TT7-14/MP8/POOL768). At d4
>    the configs agree (shallow → TT/pool/ply irrelevant) so it looked clean; at d5+
>    the TT-size mismatch showed up as fake "node divergence" and a knife-edge d6 move
>    flip. The 6502 builds were ALWAYS correct (on `__mos__` the guard defaults C64 but
>    the `#elif` chain still selects ULTIMATE/REU). **Fix:** add ULTIMATE+REU to the
>    guard exclusion list. With a correctly-built oracle: Ultimate mos-sim **0
>    node-mismatch @d5**; flat-shim REU **0 @d5 AND d6**; REU server in `x64sc -reu`
>    **0 @d5** (move+node). Bisection that found it: every individual knob (TT7/MP8/
>    LAZY0) AND all combos were 0-mismatch on the C64 base, but `cc -E -dM
>    -DCREF_PROFILE_ULTIMATE` revealed the host config was HOST, not Ultimate. Lesson:
>    the node-count check added to `validate.c` is what exposed this — a move-only gate
>    hid it (incl. the prior "Ultimate 30/30").

## Why (measured, not assumed)
A transposition table bigger than 64K can't live in the 6502's 16-bit address
space — it needs banked/windowed RAM (Nova 512K XRAM) or DMA RAM (C64 REU). Is it
worth the per-access overhead? **Yes, by ~200×.** Measured (host, reduced/on-chip
config, regression corpus):

| depth | total nodes/move TT8→TT16 | TT accesses/move (~2×main) |
|---|---|---|
| d4 | 5700 → 5079  (−10.9%) | ~4.2K |
| d6 | 70950 → 52903 (**−25.4%**) | ~48K |

- **Savings** (d6): −25% nodes ≈ −311 M cyc/move (at ~17.3K cyc/node).
- **Penalty** (d6): ~48K accesses × ~30 cyc window/DMA overhead ≈ **1.4 M cyc/move
  = 0.15 % of cyc/move.**
- A TT probe costs ~30 cyc; each node it eliminates costs ~17,000 cyc. 48K cheap
  accesses vs ~18K saved expensive nodes ⇒ the penalty is negligible on **both**
  Nova windowed XRAM and C64 REU DMA.
- The cut **grows with depth** (more transpositions) — biggest exactly at the d7/d8
  the 64 MHz Ultimate / fast HW reaches. Default **TT14 (16K entries ≈ 192 KB)** is
  the universal-REU-safe floor; bigger REUs gain another −10 % (TT15) to −20 % (TT18)
  at d7 — see "Measured payoff" below for the size sweep.

Net: **~−25 % cyc/move at d6**, recovering the TT7 fit-tax and adding more on top
→ shallower-time-to-depth → more Elo on fast hardware.

## Measured payoff on THIS engine (2026-06-20) — node counts (host == 6502, bit-exact)
The numbers above were a host estimate; these are measured on cref over 50 self-play
**midgame** positions. (`cyc/node` is ~flat, so node% ≈ cyc% ≈ time%; the per-access
DMA penalty is ~0.15%.)

**REU TT14 vs the Ultimate's flat TT7** — the real win of putting the TT in the REU:

| depth | TT7 nodes | TT14 nodes | reduction |
|---|---|---|---|
| d4 | 251 820 | 195 925 | **−22.2 %** |
| d5 | 933 181 | 703 146 | **−24.7 %** |
| d6 | 3 308 485 | 2 248 099 | **−32.1 %** |

Grows with depth (more transpositions deeper) — biggest exactly where the 64 MHz
Ultimate plays.

**TT-size sweep @ d7 (vs TT14), midgame** — how big a REU is worth it:

| TT | REU (12 B/entry) | d7 nodes vs TT14 | marginal/doubling |
|---|---|---|---|
| TT15 | 384 KB | **−10.2 %** | −10.2 % |
| TT16 | 768 KB | **−13.9 %** | −4.2 % |
| TT17 | 1.5 MB | −16.7 % | −3.3 % |
| TT18 | 3 MB | −20.3 % | −4.2 % |

Big jump at TT14→TT15, then ~3–4 %/doubling. The `tt_xram_clear` cost (TT_SIZE DMA
stores/move) stays negligible vs the node savings even at TT18.

⚠ **Midgame-only.** The sparse endgame corpus is already **saturated at TT14**
(~0 % from TT15/16) — few distinct positions. Most of a real game is midgame, so it
is a genuine play lever.

### Sizing guidance (which TT for which REU)
- `CREF_PROFILE_REU` ships **TT14** = universal-safe: fits a 256 KB 1764, validated
  move+node bit-exact in `x64sc -reu` at d4/d5/d6 + a full 30-move game.
- Bigger REUs override the (`#ifndef`-guarded) knob:
  - **512 KB 1750** → `-DCREF_TT_BITS=15` (`-reusize 512`): **−10 % nodes @ d7**.
    Validated move+node bit-exact in `x64sc -reu -reusize 512` (10 midgame @ d5).
  - **Ultimate 64 (large REU)** → `-DCREF_TT_BITS=16` (`-reusize 1024`): −14 % @ d7.
- No separate "Ultimate+REU" profile is needed: `CREF_PROFILE_REU` already sets
  MAX_PLY 8, so `CREF_PROFILE_REU -DCREF_TT_BITS=16` on the Ultimate IS the flagship
  config (64 MHz + a big REU TT).

## The abstraction (DONE, bit-exact — `src/search.c`)
TT access is wrapped so any backing plugs in. The flat default keeps direct entry
pointers (zero-copy, byte-identical — gate PASS); `CREF_TT_XRAM` copies one entry
in/out of a scratch:
```c
#if CREF_TT_XRAM
  TTEntry te; TTEntry *e = &te; tt_xram_load(tt_idx, e);   /* probe: copy in  */
  ... read e->key/value/best/depth/flag ...
  ... fill e at store ...
  tt_xram_store(tt_idx, e);                                 /* store: flush out */
#else
  TTEntry *e = &tt[tt_idx];                                 /* flat: direct      */
#endif
```
Validation shim = a flat `tt_x[]` + memcpy load/store/clear. **CREF_TT_XRAM ==
flat default: 0/50 move+node bit-exact @d6** — proves the copy-in/out logic is
correct. The real backings below swap memcpy for DMA/window with identical
semantics, so the search behaviour is unchanged; only the entry's home moves.

## Entry layout for XRAM
Pad `TTEntry` 12 → **16 bytes** (power of two) so no entry spans a 256-byte page
(Nova window) or complicates DMA addressing: `idx*16` is the byte offset; the high
bits select the page/bank. 16 B × 16K entries = 256 KB.

## Backing 1 — C64 REU (DMA)  [validate in VICE, which models the 1764/1750]
REU registers at $DF00. Per access copy 16 B between a C64 scratch and REU:
```
  $DF02-03 = C64 base (scratch addr)
  $DF04-06 = REU base  (idx*16, 24-bit)
  $DF07-08 = length = 16
  $DF0A    = 0  (no address fixing)
  $DF01    = $90 C64->REU (store) | $91 REU->C64 (load)   (bit7=execute)
```
~7 register writes + the 16-byte DMA (CPU halted ~16 cyc) ≈ ~50 cyc/access. The CPU
stalls during DMA — irrelevant per the penalty math. `tt_xram_clear` = DMA-fill or
just rely on the `key==hash` guard (a stale entry with the wrong key is ignored, so
a full clear is not strictly required if the key check is trusted — but keep it for
determinism / golden parity).

## Backing 2 — Nova XmcWin (windowed)  [validate on the e6502 emulator, ~/Git/e6502]
512 KB XRAM via 4×256 B windows at $BC00-$BFFF (XmcWin* regs) or 64K banks
($BA0C). Per access: set a window to the entry's 256 B page (one of the 4 windows),
then read/write 16 B through $BC00+off. ~1 window-reg write + the 16-byte copy ≈
~25 cyc/access. With 16-byte aligned entries, one window covers a full entry.

## Profiles (memcfg.h)
- `CREF_PROFILE_REU`: `CREF_TT_XRAM 1`, `CREF_TT_BITS 14` (16K entries, 256 KB REU),
  MAX_PLY 8+, eager or lazy (REU is on a stock 64K C64, low RAM still tight → eager).
- `CREF_PROFILE_NOVA`: `CREF_TT_XRAM 1`, `CREF_TT_BITS 14`, the XmcWin accessor.
- Default / C64 / Ultimate: unchanged (no CREF_TT_XRAM).

## Validation plan
1. Abstraction: DONE (copy-through == flat, 0/50; gate PASS).
2. Logic of the platform accessor: unit-test the DMA/window copy against a flat
   reference (same bytes in == out).
3. End-to-end: build the prg with the profile; run on the platform emulator
   (VICE + `-reu` for REU; the e6502 emulator for Nova) and confirm move-for-move
   AND node-for-node vs host `cref` at d4/d6. Do NOT trust structural checks NOR
   isolated DMA round-trip tests alone — only a real search caught the IRQ bug.
4. Then measure real cyc/move on the platform core to confirm the −25% net.

## Validation (2026-06-20) — REU, on real emulation (x64sc -reu)
Tooling built this session (all committed):
- **`tools/reu_validate.py`** — boots `caissa_server.prg` (REU profile) in
  `x64sc -reu` via `vice_caissa.py` (now honours `CAISSA_REU=1` to attach the REU)
  and compares every best move + node count to a host oracle.
- **Host oracle** = `cref` built `-DCREF_PROFILE_REU -DCREF_TT_REU=0` (flat in-RAM
  shim, no `$DF00`). `memcfg.h` now `#ifndef`-guards `CREF_TT_REU` and `CREF_TT_BITS`
  in the REU block so the oracle (and TT-size bisection) is buildable.
- **`test/reu_stress3_test.c`** — full-scale (16384-entry) clear+RMW REU accessor
  self-test, verifies every read via a per-idx version array. PASSES — proves the
  DMA transport itself is byte-perfect (necessary but NOT sufficient; see bug #1).
- **`validate.c` now checks node counts** (`n6502` vs `nhost`, `[ND]` tag) — this is
  what exposes the MAX_PLY-8 divergence the move-only gate hid.
- **`#ifdef CREF_TT_REU_DEBUG`** in `search.c` — dual REU+RAM-shadow self-check
  (latches the first byte where a REU load != the shadow). Used to prove the
  transport is consistent in a real search (`g_reu_err=0`); reusable for the Nova
  accessor. Only fits at small TT (shadow in low RAM).

Measured (12-FEN endgame/tactical corpus, REU TT14 server vs flat-shim TT14 oracle):
| depth | before IRQ fix | after `sei`/`cli` fix (vs MISBUILT oracle) | after BOTH fixes (correct oracle) |
|---|---|---|---|
| d4 | move 1, node 11 | **0 / 0** | **0 / 0** |
| d5 | — | move 0, node 5  *(oracle artifact)* | **0 / 0 (move+node bit-exact)** |
| d6 | — | move 1, node 10 *(oracle artifact)* | **0 / 0** (VICE -reu, move+node bit-exact) |

The d5/d6 "residual" was **not** an engine divergence — it was the misbuilt host
oracle (memcfg guard bug, finding #2). After fixing the guard so the oracle compiles
as the real REU/Ultimate profile, the REU server is **move+node bit-exact at d5**
(VICE -reu) and the flat-shim REU is bit-exact at d5 AND d6 (mos-sim). REU is fully
validated; the previously-feared shipped-Ultimate engine bug does not exist.

## Open
- TTEntry 12→16 padding touches the gate golden (size change is bit-exact in VALUE
  but the struct layout differs) — re-bless if needed, or keep 12 B for flat and 16
  only under CREF_TT_XRAM.
- REU `tt_xram_clear` cost (256 KB DMA-fill at boot) — one-time, fine.
