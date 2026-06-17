#!/usr/bin/env python3
"""Verify the 6502-compiled C eval is BIT-EXACT to tools/texel_eval.py eval_full.

Phase 1 of hand-asm'ing eval_full: this is the bit-exact safety net. It feeds the
22k-position texel dataset FENs to the 6502 eval validator (the native C eval_full
compiled by llvm-mos and run on the cycle-exact fast6502 sim) and diffs every
returned score against the python oracle eval_full. texel_eval is already
bit-exact to the original 6502 path, so matching it proves the compiled-down eval
is identical to the oracle -- the baseline the future hand-asm eval is held to.

Build the validator first:  bash tools/llvmmos_bench/build_eval_validator.sh
Then:                       python3 tools/eval_corpus_check.py
"""
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import chess  # noqa: E402
from texel_eval import eval_full  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
VALIDATE = Path("/tmp/eval_validate")
SIM = Path("/tmp/eval6502.sim")
MAP = Path("/tmp/eval6502.map")


def main() -> int:
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 22157
    for p in (VALIDATE, SIM, MAP):
        if not p.exists():
            print(f"missing {p} -- run: bash tools/llvmmos_bench/build_eval_validator.sh",
                  file=sys.stderr)
            return 2
    positions = json.load(open(ROOT / "build" / "texel_data.json"))["positions"][:n]
    fens = [p["fen"] for p in positions]
    proc = subprocess.run([str(VALIDATE), str(SIM), str(MAP)],
                          input="\n".join(fens) + "\n",
                          capture_output=True, text=True)
    got = proc.stdout.split()
    if len(got) != len(fens):
        print(f"output count {len(got)} != {len(fens)} fens", file=sys.stderr)
        print(proc.stderr[-2000:], file=sys.stderr)
        return 2
    mism = []
    for fen, g in zip(fens, got):
        want = eval_full(chess.Board(fen))
        if g == "ERR" or int(g) != want:
            mism.append((fen, g, want))
    nN = len(fens)
    print(f"[6502 eval] {nN - len(mism)}/{nN} bit-exact vs texel_eval")
    for fen, g, want in mism[:25]:
        print(f"  MISMATCH 6502={g} oracle={want} "
              f"diff={'?' if g == 'ERR' else int(g) - want} | {fen}")
    return 0 if not mism else 1


if __name__ == "__main__":
    raise SystemExit(main())
