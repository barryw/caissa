# fastcolossus — run real Colossus 4.0 on the fast cpu6502 core

## Why
Headless VICE warp is **realtime** (~1 MHz: Caissa depth-6 move = 225s) — far too
slow to tune against. The same 6502 binary on `cpu6502.c` runs **75–660× faster**.
Caissa already runs there (`caissa_cli`, depth-6 = 3.25s). This puts **Colossus**
there too, so a Caissa-vs-Colossus game runs in **seconds**, not overnight.

This is a C port of the (deleted, C#) ColossusRawRunner onto `cpu6502.c` — a
different, clean-room core, so the open question is whether it reproduces the C#
runner's never-root-caused fidelity bug (1.e4 → f7f6 instead of e7e5).

## Status (2026-06-17)
**Speed proven, boot proven, input bring-up in progress.**
- Loads the VICE ready-state snapshot (`build/colossus_extract/runtime/ready.ram.bin`
  + `ready_cpu.ram.bin` for ROM/IO), banks via `$01`, runs from PC=$F155.
- **Boots + renders the Colossus board correctly** at **32 M cyc/s** (real code w/
  banking; 660 M cyc/s on trivial loops) — vs VICE's ~1 MHz.
- Fixes landed: force `$01=$37` (snapshot RAM-view $01=0 banked out all ROM →
  BRK-loop to $0000); NMOS decimal mode + banked-memory hooks in `cpu6502.c`
  (gate stays bit-exact); latched jiffy IRQ.
- One-byte-at-a-time keyboard feed (feed when $C6==0) added; Colossus still does
  not drain it.
- **BLOCKED:** with 1.e4 fed, Colossus loops in **$5663–$56af with I=1 forever**,
  repeatedly toggling `$01` 37↔33 to read **I/O registers** ($D0xx) and never
  reading the keyboard. It is **polling a hardware register my emulation doesn't
  faithfully reproduce** — prime suspect **CIA ICR $DC0D** (timer-underflow flag,
  polled instead of using the IRQ), or a CIA timer / VIC raster value. We return
  a static `io[0x0D]` today, so the awaited bit never sets → infinite spin. This
  is the hardware-fidelity gap the differential trace is meant to pin.
### Session-2 deep trace (the picture is now precise)
- **INPUT WORKS.** Full instruction trace from $F155: KERNAL RTS → Colossus init
  ($4C26 SEI, $4C23 CLI) → `JSR $FFE4` (GETIN) → KERNAL buffer read at $E5B4 →
  **reads `'2'` ($32)** → keystroke dispatch at $4C35 (CMP/BEQ chain). So the
  keyboard buffer feed reaches Colossus correctly.
- **The stall is a non-terminating BOARD-REDRAW loop AFTER the first keystroke.**
  Feed log: only `'2'`($32) then `'E'`($45) get fed; `'E'` is never consumed —
  Colossus enters a redraw loop and never returns to read the rest of the move.
  The loop nest: caller `$5484` → inline-parameter subroutines (`$67AD`: `PLA/PLA`
  to read the return addr, then reads inline `.byte` data after the `JSR`, advances
  via the 16-bit ptr-inc at `$6F33`) → per-char chargen copy `$5645` (src
  `$D800 + char*8` read with charen=0; that's the $D900 hammer). The `$548C`
  `LDX #$26 … DEX … BNE` counter is effectively stuck → infinite.
- **Ruled OUT as the cause:** undocumented opcodes (logged: NONE executed);
  decimal mode (D flag never set in this region); `JSR`/`RTS` off-by-one (correct:
  push pc-1 / pull+1); PHP/PLP/PLA/RTI B-flag & unused-bit quirks (all correct).
  The core is solid for everything Colossus exercises here, so the divergence is
  either a rarer CPU edge or an **I/O read value** the redraw branches on
  (e.g. `BIT $B42B; BPL` — if $B42B was set from a wrong I/O read upstream).
- Instruments in the harness (all env-gated): `FCDEBUG`/`FCFINE` (step trace),
  `FCTRACE=N` (first N instrs), `FCRING` (48-instr ring + 140 after first $5645),
  `FCKB` (keyboard feeds), `g_ioreads` histogram, undoc-opcode detector.

## Next — build the differential trace (the only definitive tool left)
1. **Oracle problem:** only a RAM-only snapshot exists (no `.vsf` full chip state),
   so re-running `ready.ram.bin` in VICE won't perfectly match. Regenerate a clean
   reference: boot Colossus fresh in headless VICE from `coloss40_rebuilt.d64`,
   play `1.e4` via the monitor, and capture a PC+regs trace (VICE CPU history
   `chis`, or breakpoint-step). This run is full-state-faithful and ends in `e7e5`.
2. Make this core boot the SAME way (or align both at a common checkpoint), then
   **diff the PC+reg streams → first divergent instruction = the bug.** Fix it
   (likely an I/O read value or a CPU flag edge), repeat until `1.e4 → e7e5`.
3. Then wire move-in + screen-scrape and drop this in for the VICE Colossus in
   `match_caissa_colossus.py` (Caissa via `caissa_cli`) → games in seconds.

## Build / run
    cc -O2 -I ../fast6502_bridge fastcolossus.c ../fast6502_bridge/cpu6502.c -o fastcolossus
    ./fastcolossus [max_cycles]          # from repo root (snapshot paths are relative)
    FCDEBUG=1 FCFINE=1 ./fastcolossus 2000000   # step trace
