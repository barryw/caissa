#!/usr/bin/env python3
"""Verify the native C movegen against python-chess (the perft oracle).

Builds nothing -- expects native/test_perft already compiled. Runs perft to a
few depths on a battery of positions (start, kiwipete, ep/castle/promo-heavy
endgames) and compares node counts to python-chess. Exit 0 iff every count
matches.
"""
import subprocess
import sys
from pathlib import Path

import chess

ROOT = Path(__file__).resolve().parent.parent
BIN = ROOT / "src" / "test_perft"

# (fen, max_depth) -- standard perft suite.
SUITE = [
    (chess.STARTING_FEN, 5),
    ("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1", 4),  # kiwipete
    ("8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1", 5),                              # ep/pins
    ("r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1", 4),       # promo/castle
    ("rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8", 4),
    ("n1n5/PPPk4/8/8/8/8/4Kppp/5N1N b - - 0 1", 5),                                 # promo-heavy
]


def py_perft(board: chess.Board, depth: int) -> int:
    if depth == 0:
        return 1
    total = 0
    for mv in board.legal_moves:
        board.push(mv)
        total += py_perft(board, depth - 1)
        board.pop()
    return total


def main() -> int:
    if not BIN.exists():
        print(f"missing {BIN} -- build first (make -C native)", file=sys.stderr)
        return 2
    bad = 0
    for fen, maxd in SUITE:
        for d in range(1, maxd + 1):
            got = int(subprocess.run([str(BIN), fen, str(d)], capture_output=True,
                                     text=True).stdout.strip() or -1)
            want = py_perft(chess.Board(fen), d)
            ok = got == want
            bad += not ok
            tag = "ok " if ok else "BAD"
            print(f"[{tag}] d{d} got={got:<12} want={want:<12} {fen}")
            if not ok:
                break
    print("PERFT EXACT" if not bad else f"{bad} MISMATCH(es)")
    return 0 if not bad else 1


if __name__ == "__main__":
    raise SystemExit(main())
