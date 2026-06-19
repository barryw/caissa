#!/usr/bin/env python3
"""On-chip strength vs time-control: the honest grounding measurement for the
campaign (docs/eval-rewrite-conclusion-and-goal-reframe.md).

Two independent measurements compose into a strength-vs-clock curve for the REAL
6502 image:

  1. TIME -> DEPTH.  Cycle-accurate cost of the shipping 6502 image per move at
     each fixed depth, averaged over a diverse corpus (caissa_prof). At the C64's
     ~1 MHz, cycles/move == seconds/move. So a time control (s/move) admits the
     deepest fixed depth whose cyc/move fits (the engine plays fixed depth; the
     on-chip CLI has no time management).

  2. DEPTH -> ELO.  cref_mos -- the host binary built with the SAME reduced config
     the 6502 image runs (TT8 / MAX_PLY=7 / no history), golden-verified move-for-
     move identical to the image -- played vs Stockfish at each fixed depth. This
     is the chip's strength per depth, measured fast on the host (no cycle sim).

  strength(time control) = Elo( deepest depth whose cyc/move <= budget ).

Usage:
  python3 tools/onchip_strength_vs_tc.py cycles                 # measurement 1
  python3 tools/onchip_strength_vs_tc.py elo --games 240        # measurement 2 (slow; needs SF)
  # then read both tables; map TC -> depth -> Elo by hand or extend report().

Notes:
  * Run `elo` with bounded parallelism (jobs <= cores) so the time-based Stockfish
    is not CPU-starved -- contention inflates the native side's apparent strength.
  * MHz assumption: C64 ~1.023 MHz (NTSC) / ~0.985 MHz (PAL); 1 MHz is used so
    cyc/move reads directly as seconds/move.
"""
from __future__ import annotations
import argparse, os, re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROF = ROOT / "tools" / "llvmmos_bench" / "caissa_prof"
FENS = ROOT / "tools" / "llvmmos_bench" / "regression_fens.txt"
CREF_MOS = ROOT / "build" / "cref_mos"
MHZ = 1_000_000  # cycles per second at the C64 clock (~1 MHz)


def measure_rows(depths, nfens=0):
    """Per-depth (avg cyc/move, avg nodes/move) over the corpus (or its first
    `nfens` positions if nfens>0 -- handy to keep deep searches tractable)."""
    fens = [l.strip() for l in open(FENS) if l.strip()]
    if nfens:
        fens = fens[:nfens]
    rows = {}
    for d in depths:
        tot = tnodes = nf = 0
        for f in fens:
            out = subprocess.run([str(PROF), f, str(d)], capture_output=True, text=True).stdout
            m = re.search(r"total cycles=(\d+)\s+nodes=(\d+)\s+qnodes=(\d+)", out)
            if m:
                tot += int(m.group(1)); tnodes += int(m.group(2)) + int(m.group(3)); nf += 1
        if nf:
            rows[d] = (tot / nf, tnodes / nf)
    return rows, len(fens)


def fmt_time(sec):
    if sec < 1:    return f"{sec*1000:.0f}ms"
    if sec < 90:   return f"{sec:.1f}s"
    return f"{sec/60:.1f}m"


def measure_cycles(depths, mhz=1.0, nfens=0):
    rows, n = measure_rows(depths, nfens)
    hz = mhz * MHZ
    print(f"clock = {mhz:g} MHz  ({n} positions)")
    print(f"{'depth':>5} {'cyc/move':>14} {'nodes/move':>11} {'cyc/node':>9} "
          f"{'s/move':>8} {'nodes/sec':>10}")
    for d in depths:
        if d not in rows: continue
        cm, nm = rows[d]; cpn = cm / nm if nm else 0
        print(f"{d:>5} {cm:>14,.0f} {nm:>11,.0f} {cpn:>9,.0f} "
              f"{fmt_time(cm/hz):>8} {hz/cpn if cpn else 0:>10,.0f}")
    return {d: rows[d][0] for d in rows}


def bench(depths, clocks, nfens=0):
    """Depth x clock matrix of seconds/move for the real 6502 image. Clock is a
    pure divisor on the cycle-exact count, so one measurement per depth covers
    every clock. Clocks in MHz: 1=stock C64, ~20=SuperCPU, ~40=Ultimate/Novu."""
    rows, n = measure_rows(depths, nfens)
    print(f"=== on-chip benchmark: {n} positions, cycle-exact 6502 image ===\n")
    print(f"{'depth':>5} {'cyc/move':>14} {'nodes/move':>11} {'cyc/node':>9}")
    for d in depths:
        if d not in rows: continue
        cm, nm = rows[d]
        print(f"{d:>5} {cm:>14,.0f} {nm:>11,.0f} {cm/nm if nm else 0:>9,.0f}")
    print(f"\n=== seconds/move by clock ===")
    hdr = "depth " + "".join(f"{str(c)+'MHz':>9}" for c in clocks)
    print(hdr)
    for d in depths:
        if d not in rows: continue
        cm = rows[d][0]
        print(f"{d:>5} " + "".join(f"{fmt_time(cm/(c*MHZ)):>9}" for c in clocks))


def measure_elo(depths, sf_by_depth, games, jobs):
    rows = {}
    for d in depths:
        sf = sf_by_depth[d]
        out = subprocess.run(
            [sys.executable, str(ROOT / "tools" / "native_vs_stockfish.py"),
             "--native-depth", str(d), "--sf-elo", str(sf),
             "--games", str(games), "--jobs", str(jobs)],
            capture_output=True, text=True,
            env={**os.environ, "NATIVE_CREF": str(CREF_MOS)}).stdout
        m = re.search(r"native Elo ~ (\d+)", out)
        sc = re.search(r"native: [\d.]+/\d+ = ([\d.]+)%", out)
        elo = m.group(1) if m else "?"
        pct = sc.group(1) if sc else "?"
        rows[d] = elo
        print(f"d{d} vs SF-{sf}: {pct}%  ->  ~{elo} Elo")
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["cycles", "bench", "elo"])
    ap.add_argument("--games", type=int, default=240)
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--depths", default="1,2,3,4")
    ap.add_argument("--clocks", default="1,5,10,12,20,40",
                    help="bench mode: CPU clocks in MHz (1=stock, ~20=SuperCPU, ~40=Ultimate)")
    ap.add_argument("--fens", type=int, default=0,
                    help="use only the first N corpus positions (0=all; keeps deep searches tractable)")
    ap.add_argument("--mhz", type=float, default=1.0,
                    help="cycles mode: CPU clock for the report (e.g. 40 for a C64 Ultimate)")
    args = ap.parse_args()
    depths = [int(x) for x in args.depths.split(",")]
    if args.mode == "cycles":
        measure_cycles(depths, args.mhz, args.fens)
    elif args.mode == "bench":
        bench(depths, [float(c) if "." in c else int(c) for c in args.clocks.split(",")], args.fens)
    else:
        sf_by_depth = {1: 1320, 2: 1400, 3: 1550, 4: 1700}
        measure_elo(depths, sf_by_depth, args.games, args.jobs)


if __name__ == "__main__":
    raise SystemExit(main())
