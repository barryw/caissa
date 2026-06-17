#!/usr/bin/env python3
"""Measure how faithfully the native C search reproduces the 6502 search.

The native reference engine is only useful for game-Elo tuning if it picks the
SAME moves as the real 6502 engine. This feeds N positions to BOTH the 6502
(sim6502 bridge, a chosen difficulty) and native/cref (bestmove at a chosen
depth) and reports the % of positions where they pick the same move -- the
fidelity metric to drive the faithful-search-port up. It also reports the 6502's
self-reported search depth distribution so we learn the difficulty->depth mapping
empirically.

  python3 tools/search_fidelity.py --n 100 --difficulty hard --native-depth 3
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import chess  # noqa: E402
from run_stockfish_strength import DIFFICULTY, c64_encoded_move_to_uci, fen_to_c64  # noqa: E402
from sim6502_headless_runner import Sim6502HeadlessRunner, repo_root_from_script  # noqa: E402

ROOT = repo_root_from_script()
CREF = ROOT / "native" / "cref"


def native_bestmove(fen: str, depth: int) -> str | None:
    out = subprocess.run([str(CREF), "bestmove", fen, str(depth)],
                         capture_output=True, text=True).stdout
    for tok in out.split():
        if tok == "bestmove":
            continue
        return tok if out.startswith("bestmove") else None
    return None


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--n", type=int, default=100)
    p.add_argument("--difficulty", default="hard", choices=sorted(DIFFICULTY))
    p.add_argument("--native-depth", type=int, default=0,
                   help="native search depth; 0 = match the 6502's self-reported depth per position")
    p.add_argument("--timeout-cycles", type=int, default=400_000_000)
    p.add_argument("--positions", type=Path, default=ROOT / "data" / "openings_big.txt")
    args = p.parse_args(argv)

    fens = [ln.strip() for ln in args.positions.read_text().splitlines()
            if ln.strip() and not ln.startswith("#")][:args.n]

    match = 0
    total = 0
    depth_hist: Counter = Counter()
    mismatches = []
    with Sim6502HeadlessRunner(repo_root=ROOT) as r:
        for fen in fens:
            try:
                resp = r.best_move(fen_to_c64(fen), DIFFICULTY[args.difficulty], args.timeout_cycles)
            except Exception as exc:
                print(f"  bridge error: {exc}", file=sys.stderr)
                continue
            eng_uci = c64_encoded_move_to_uci(fen, int(resp["encoded"]))
            d6502 = int(resp.get("searchCompletedDepth", 0) or 0)
            depth_hist[d6502] += 1
            nd = args.native_depth or (d6502 if d6502 else 3)
            nat_uci = native_bestmove(fen, nd)
            total += 1
            if eng_uci == nat_uci:
                match += 1
            elif len(mismatches) < 20:
                mismatches.append((fen, eng_uci, nat_uci, d6502, nd))

    print(f"=== search fidelity: 6502({args.difficulty}) vs native ===")
    print(f"move agreement: {match}/{total} = {100*match/total:.1f}%" if total else "no positions")
    print(f"6502 search depth distribution: {dict(sorted(depth_hist.items()))}")
    print("sample mismatches (fen | 6502 | native | d6502 | dnat):")
    for fen, e, n, d6, dn in mismatches[:15]:
        print(f"  {e} vs {n}  (d6502={d6}, dnat={dn}) | {fen}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
