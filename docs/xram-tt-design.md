# Big transposition table in XRAM/REU — design + measured payoff

**Date:** 2026-06-19
**Status:** abstraction landed + validated; platform backings (REU / Nova) are the
next step (need platform emulation to validate). Foundation on branch `xram-tt`.

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
  the 64 MHz Ultimate / fast HW reaches. Knee at **TT14 (16K entries ≈ 192 KB)**,
  fits Nova 512K and any REU.

Net: **~−25 % cyc/move at d6**, recovering the TT7 fit-tax and adding more on top
→ shallower-time-to-depth → more Elo on fast hardware.

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
   reference (same 16 bytes in == out).
3. End-to-end: build the prg with the profile; run on the platform emulator
   (VICE + `-reu` for REU; the e6502 emulator for Nova) and confirm move-for-move
   vs host `cref` at d4/d6 — the same recipe that validated the Ultimate build via
   the mos-sim core. Do NOT trust structural checks alone (the banking saga: a
   build that "passed" everything was non-bootable — always run it).
4. Then measure real cyc/move on the platform core to confirm the −25% net.

## Open
- TTEntry 12→16 padding touches the gate golden (size change is bit-exact in VALUE
  but the struct layout differs) — re-bless if needed, or keep 12 B for flat and 16
  only under CREF_TT_XRAM.
- REU `tt_xram_clear` cost (256 KB DMA-fill at boot) — one-time, fine.
