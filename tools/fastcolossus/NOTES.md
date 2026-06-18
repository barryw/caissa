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
- **Pinpointed** (I/O read histogram, `g_ioreads`): the spin hammers
  **$D900–$D907** (~65k reads each) — an `LDA ($zp),Y` (op b1) whose pointer sits
  in the $D800–$DBFF color-RAM/I-O region, almost certainly a WRONG pointer from
  an upstream divergence (its symptom, not the bug). Implementing $DC0D ICR
  (return 0x81 once/jiffy) did NOT change the spin, so it isn't $DC0D.

## Next (differential trace vs VICE — the method the C# attempt lacked)
1. Try the one-byte-at-a-time keyboard feed (feed next byte when $C6==0, with a
   cycle gap), mirroring the C# QueuedKeyboardInput.
2. If still stuck: trace the same snapshot on VICE (monitor `r`/step) and on this
   core in lockstep; find the FIRST divergent instruction → fix the opcode/timing.
   Candidates from the C# postmortem: CIA-timer/IRQ fidelity, undocumented opcodes
   (cpu6502.c stubs them as NOP — log which Colossus hits), I/O-internal state.
3. Once 1.e4 → e7e5 (VICE truth), wire move-in + screen-scrape and replace the
   VICE Colossus in `match_caissa_colossus.py` with this (Caissa via caissa_cli).

## Build / run
    cc -O2 -I ../fast6502_bridge fastcolossus.c ../fast6502_bridge/cpu6502.c -o fastcolossus
    ./fastcolossus [max_cycles]          # from repo root (snapshot paths are relative)
    FCDEBUG=1 FCFINE=1 ./fastcolossus 2000000   # step trace
