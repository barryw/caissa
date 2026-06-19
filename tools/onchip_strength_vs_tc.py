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


def measure_cycles(depths):
    fens = [l.strip() for l in open(FENS) if l.strip()]
    print(f"{'depth':>5}  {'avg cyc/move':>14}  {'s/move @1MHz':>12}")
    rows = {}
    for d in depths:
        tot = nf = 0
        for f in fens:
            out = subprocess.run([str(PROF), f, str(d)], capture_output=True, text=True).stdout
            m = re.search(r"total cycles=(\d+)", out)
            if m:
                tot += int(m.group(1)); nf += 1
        avg = tot / nf if nf else 0
        rows[d] = avg
        print(f"{d:>5}  {avg:>14,.0f}  {avg/MHZ:>11.1f}s")
    return rows


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
    ap.add_argument("mode", choices=["cycles", "elo"])
    ap.add_argument("--games", type=int, default=240)
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--depths", default="1,2,3,4")
    args = ap.parse_args()
    depths = [int(x) for x in args.depths.split(",")]
    if args.mode == "cycles":
        measure_cycles(depths)
    else:
        sf_by_depth = {1: 1320, 2: 1400, 3: 1550, 4: 1700}
        measure_elo(depths, sf_by_depth, args.games, args.jobs)


if __name__ == "__main__":
    raise SystemExit(main())
