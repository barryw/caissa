#!/usr/bin/env python3
"""Python port of the engine's static eval, for Texel weight tuning.

Tuning weights needs the eval evaluated millions of times with varying weights;
the 6502 eval via sim6502 is far too slow for that, so we mirror it here in
Python (fast, mutable weights) and verify the port against the engine's own eval
through the bridge `eval` command. The self-play A/B harness is the final
ground-truth gate, so the port only has to be faithful enough to point at better
weights -- but we drive it toward exact agreement term by term.

This file is built up incrementally and verified at each stage:
  stage 1 (DONE here): material + PST  -> must match engine lazy eval (lazy=1)
  stage 2 (TODO):       + mobility, pawn structure, king safety, pressure, ...
                          -> must match engine full eval (lazy=0)

All scores are WHITE-POV in engine units (10cp = 1 unit), matching EvalScore.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import chess  # noqa: E402

# --- Weight constants (from src/ai/eval.s; the tunable parameters) ---
PIECE_VALUE = {
    chess.PAWN: 10,
    chess.KNIGHT: 32,
    chess.BISHOP: 33,
    chess.ROOK: 50,
    chess.QUEEN: 90,
    chess.KING: 0,
}

# --- Piece-square tables (from src/ai/pst.s), index 0 = a8, 63 = h1 ---
# (row 0 = rank 8 ... row 7 = rank 1), files a..h left to right.
PST_PAWN = [
    0, 0, 0, 0, 0, 0, 0, 0,
    20, 20, 20, 20, 20, 20, 20, 20,
    10, 10, 20, 30, 30, 20, 10, 10,
    5, 5, 10, 25, 25, 10, 5, 5,
    0, 0, 0, 20, 20, 0, 0, 0,
    5, -5, -10, 0, 0, -10, -5, 5,
    5, 10, 10, -20, -20, 10, 10, 5,
    0, 0, 0, 0, 0, 0, 0, 0,
]
PST_KNIGHT = [
    -50, -40, -30, -30, -30, -30, -40, -50,
    -40, -20, 0, 5, 5, 0, -20, -40,
    -30, 5, 10, 15, 15, 10, 5, -30,
    -30, 0, 15, 20, 20, 15, 0, -30,
    -30, 5, 15, 20, 20, 15, 5, -30,
    -30, 0, 10, 15, 15, 10, 0, -30,
    -40, -20, 0, 0, -3, 0, -20, -40,
    -50, -40, -30, -30, -30, -30, -40, -50,
]
PST_BISHOP = [
    -20, -10, -10, -10, -10, -10, -10, -20,
    -10, 5, 0, 0, 0, 0, 5, -10,
    -10, 10, 10, 10, 10, 10, 10, -10,
    -10, 0, 10, 10, 10, 10, 0, -10,
    -10, 5, 5, 10, 10, 5, 5, -10,
    -10, 0, 5, 10, 10, 5, 0, -10,
    -10, 0, 0, 0, 0, 0, 0, -10,
    -20, -10, -10, -10, -10, -10, -10, -20,
]
PST_ROOK = [
    0, 0, 0, 5, 5, 0, 0, 0,
    5, 10, 10, 10, 10, 10, 10, 5,
    -5, 0, 0, 0, 0, 0, 0, -5,
    -5, 0, 0, 0, 0, 0, 0, -5,
    -5, 0, 0, 0, 0, 0, 0, -5,
    -5, 0, 0, 0, 0, 0, 0, -5,
    -5, 0, 0, 0, 0, 0, 0, -5,
    0, 0, 0, 5, 5, 0, 0, 0,
]
PST_QUEEN = [
    -20, -10, -10, -5, -5, -10, -10, -20,
    -10, 0, 5, 0, 0, 0, 0, -10,
    -10, 5, 5, 5, 5, 5, 0, -10,
    0, 0, 5, 5, 5, 5, 0, -5,
    -5, 0, 5, 5, 5, 5, 0, -5,
    -10, 0, 5, 5, 5, 5, 0, -10,
    -10, 0, 0, 0, 0, 0, 0, -10,
    -20, -10, -10, -5, -5, -10, -10, -20,
]
PST_KING_MID = [
    20, 30, 10, 0, 0, 10, 30, 20,
    20, 20, 0, 0, 0, 0, 20, 20,
    -10, -20, -20, -20, -20, -20, -20, -10,
    -20, -30, -30, -40, -40, -30, -30, -20,
    -30, -40, -40, -50, -50, -40, -40, -30,
    -30, -40, -40, -50, -50, -40, -40, -30,
    -30, -40, -40, -50, -50, -40, -40, -30,
    -30, -40, -40, -50, -50, -40, -40, -30,
]
PST = {
    chess.PAWN: PST_PAWN, chess.KNIGHT: PST_KNIGHT, chess.BISHOP: PST_BISHOP,
    chess.ROOK: PST_ROOK, chess.QUEEN: PST_QUEEN, chess.KING: PST_KING_MID,
}


def _pst_index_white(sq: int) -> int:
    """0-63 PST index (a8=0) for a white piece, matching the engine's Sq88To64."""
    return (7 - chess.square_rank(sq)) * 8 + chess.square_file(sq)


def _pst_index_black(sq: int) -> int:
    """Rank-mirrored index for a black piece (engine Sq88To64Mirror = ^0x38)."""
    return chess.square_rank(sq) * 8 + chess.square_file(sq)


def eval_material_pst(board: chess.Board) -> int:
    """Material + PST only, WHITE-POV, engine units. Mirrors the lazy stage."""
    score = 0
    for sq, piece in board.piece_map().items():
        val = PIECE_VALUE[piece.piece_type]
        if piece.color == chess.WHITE:
            score += val + PST[piece.piece_type][_pst_index_white(sq)]
        else:
            score -= val + PST[piece.piece_type][_pst_index_black(sq)]
    return score


def _verify(n: int = 600) -> int:
    """Compare eval_material_pst to the engine lazy eval over n random positions."""
    import random
    from sim6502_headless_runner import Sim6502HeadlessRunner, repo_root_from_script
    from run_stockfish_strength import fen_to_c64

    rng = random.Random(20260614)
    fens = []
    for _ in range(n):
        b = chess.Board()
        for _ in range(rng.randint(0, 40)):
            ms = list(b.legal_moves)
            if not ms or b.is_game_over():
                break
            b.push(rng.choice(ms))
        if b.king(chess.WHITE) is not None and b.king(chess.BLACK) is not None:
            fens.append(b.fen())

    mism = 0
    worst = []
    with Sim6502HeadlessRunner(repo_root=repo_root_from_script()) as r:
        for fen in fens:
            eng = int(r.evaluate(fen_to_c64(fen), lazy=1)["eval"])
            mine = eval_material_pst(chess.Board(fen))
            if eng != mine:
                mism += 1
                if len(worst) < 12:
                    worst.append((eng, mine, fen))
    print(f"material+PST vs engine lazy: {len(fens) - mism}/{len(fens)} exact match")
    for eng, mine, fen in worst:
        print(f"  MISMATCH eng={eng} mine={mine} diff={mine - eng} | {fen}")
    return 0 if mism == 0 else 1


if __name__ == "__main__":
    raise SystemExit(_verify())
