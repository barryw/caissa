#!/usr/bin/env python3
"""Verify the native C eval is BIT-EXACT to tools/texel_eval.py eval_full.

texel_eval is already bit-exact to the 6502 (6700/6700 on the bridge), so
matching it transitively makes the C eval bit-exact to the engine. Feeds the
22k-position texel dataset FENs to native/test_eval and diffs every score.
"""
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import chess  # noqa: E402
from texel_eval import eval_full  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
BIN = ROOT / "native" / "test_eval"


def main() -> int:
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 22157
    if not BIN.exists():
        print(f"missing {BIN} -- build first (make -C native)", file=sys.stderr)
        return 2
    positions = json.load(open(ROOT / "build" / "texel_data.json"))["positions"][:n]
    fens = [p["fen"] for p in positions]
    proc = subprocess.run([str(BIN)], input="\n".join(fens) + "\n",
                          capture_output=True, text=True)
    got = proc.stdout.split()
    if len(got) != len(fens):
        print(f"output count {len(got)} != {len(fens)} fens", file=sys.stderr)
        return 2
    mism = []
    for fen, g in zip(fens, got):
        want = eval_full(chess.Board(fen))
        if g == "ERR" or int(g) != want:
            mism.append((fen, g, want))
    nN = len(fens)
    print(f"[C eval] {nN - len(mism)}/{nN} bit-exact vs texel_eval")
    for fen, g, want in mism[:25]:
        print(f"  MISMATCH c={g} oracle={want} diff={'?' if g=='ERR' else int(g)-want} | {fen}")
    return 0 if not mism else 1


if __name__ == "__main__":
    raise SystemExit(main())
