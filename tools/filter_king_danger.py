#!/usr/bin/env python3
"""Filter an SF-labeled Texel TSV (FEN\\tcp) down to KING-DANGER positions.

The eval rewrite's term #1 (king-danger) only fires when a king is under real
attack, but the full Texel set is quiet-filtered and dominated by positions where
king-danger is 0 -- so a global MSE fit washes the term out. This selects the
positions where the term is active, so `cref mse` on the output isolates the
king-danger calibration signal (supervise-to-Stockfish, per
docs/plans/2026-06-18-eval-rewrite-design.md).

Keep a position if EITHER king is in danger:
  * the enemy has heavy material (queen=2, rook=1; >= MIN_HEAVY units), AND
  * >= 1 enemy piece attacks the king's square or one of its 8 ring squares.

  python3 tools/filter_king_danger.py build/texel_big.tsv build/kd_tune.tsv
  python3 tools/filter_king_danger.py build/texel_big.tsv build/kd_tune.tsv --cap 60000
"""
from __future__ import annotations
import argparse, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import chess  # noqa: E402

MIN_HEAVY = 2   # enemy heavy material (Q=2,R=1) needed to count as a real threat


def heavy(board: chess.Board, color: bool) -> int:
    return 2 * len(board.pieces(chess.QUEEN, color)) + len(board.pieces(chess.ROOK, color))


def king_in_danger(board: chess.Board, king_color: bool) -> bool:
    ksq = board.king(king_color)
    if ksq is None:
        return False
    enemy = not king_color
    if heavy(board, enemy) < MIN_HEAVY:
        return False
    ring = [ksq] + list(chess.SquareSet(chess.BB_KING_ATTACKS[ksq]))
    return any(board.attackers(enemy, s) for s in ring)


def is_kd(fen: str) -> bool:
    try:
        b = chess.Board(fen)
    except Exception:
        return False
    return king_in_danger(b, chess.WHITE) or king_in_danger(b, chess.BLACK)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--cap", type=int, default=0, help="max output rows (0 = all)")
    args = ap.parse_args()

    kept = total = 0
    with open(args.src) as fin, open(args.dst, "w") as fout:
        for line in fin:
            total += 1
            tab = line.find("\t")
            if tab < 0:
                continue
            fen = line[:tab]
            if is_kd(fen):
                fout.write(line)
                kept += 1
                if args.cap and kept >= args.cap:
                    break
    print(f"kept {kept}/{total} king-danger positions -> {args.dst}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
