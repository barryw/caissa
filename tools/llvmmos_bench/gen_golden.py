#!/usr/bin/env python3
"""Regenerate golden_moves.txt: the search-regression baseline for speed work.

Golden = cref_mos (host engine in the EXACT 6502 config: -D__mos__, TT8,
MAX_PLY=7, history off) best move at d4 and d6 over regression_fens.txt. The
6502 image plays these same moves move-for-move (validate.c proves it), so a
golden mismatch == a real behavior change.

Run this to RE-BLESS golden ONLY after an INTENTIONAL behavior change (then
re-measure Elo: NATIVE_CREF=tools/llvmmos_bench/caissa_cli
python3 tools/native_vs_stockfish.py --native-depth 6 --sf-elo 1700 ...).

Prereq: native/cref_mos built
  clang -O3 -D__mos__ native/board.c native/movegen.c native/eval.c \
        native/search.c native/cref.c -o native/cref_mos
"""
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
HERE = Path(__file__).resolve().parent
CREF = ROOT / "native" / "cref_mos"


def mv(fen: str, d: int) -> str:
    out = subprocess.run([str(CREF), "bestmove", fen, str(d)],
                         capture_output=True, text=True).stdout
    return out.split()[1] if out.startswith("bestmove") else "ERR"


def main() -> None:
    fens = [l.strip() for l in (HERE / "regression_fens.txt").read_text().splitlines() if l.strip()]
    with (HERE / "golden_moves.txt").open("w") as g:
        g.write("# FEN\td4move\td6move  (cref_mos = exact 6502 config; regenerate with gen_golden.py)\n")
        for f in fens:
            g.write(f"{f}\t{mv(f, 4)}\t{mv(f, 6)}\n")
    print(f"golden: {len(fens)} positions @ d4 + d6")


if __name__ == "__main__":
    main()
