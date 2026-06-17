#!/usr/bin/env python3
"""Native reference engine (Tier 3) — fast game-Elo feedback for eval work.

The 6502 self-play loop is the rate-limiter on eval iteration: a depth-6 move is
~25s emulated, a game ~20 min, an A/B ~1 hr. This module pairs the bit-exact eval
oracle (`texel_eval.eval_full`) with a clean alpha-beta search on python-chess so
reference-vs-reference self-play runs at native speed (a game is seconds, not
minutes). See docs/fast-iteration-plan.md (Tier 3).

Fidelity contract (from the plan):
  * EVAL is bit-exact to the 6502 (it IS the oracle) — so eval experiments
    transfer.
  * SEARCH is only REPRESENTATIVE — a clean negamax/alpha-beta/quiescence with
    MVV-LVA ordering and a small TT. A better eval helps any reasonable search,
    so the screen transfers; the 6502 confirms winners.

CLI (sanity check vs the 6502 at matched depth):
    python3 tools/reference_engine.py "FEN" --depth 4
"""

from __future__ import annotations

import argparse
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "test"))  # texel_eval lives in test/

import chess  # noqa: E402
import chess.polyglot  # noqa: E402

from texel_eval import eval_full  # noqa: E402

# Mirror the engine's score ABI (src/ai constants). MATE_SCORE is flat 30000;
# static evals are bounded well under it (STATIC_EVAL_LIMIT=29000). We encode
# mate distance into the score so the search prefers faster mates / slower losses.
MATE_SCORE = 30000
MATE_THRESHOLD = 29000          # |score| above this == a forced mate
INF = 32000                     # search window infinity (> MATE_SCORE)

# MVV-LVA victim/attacker values (centipawns; king as attacker = cheapest).
_MVV = {chess.PAWN: 100, chess.KNIGHT: 320, chess.BISHOP: 330,
        chess.ROOK: 500, chess.QUEEN: 900, chess.KING: 20000}

# Transposition-table entry flags.
_EXACT, _LOWER, _UPPER = 0, 1, 2


@dataclass
class SearchInfo:
    nodes: int = 0
    qnodes: int = 0
    tt_hits: int = 0
    depth: int = 0
    elapsed: float = 0.0
    score: int = 0
    pv: list = field(default_factory=list)


def evaluate_stm(board: chess.Board) -> int:
    """Oracle eval (white-POV centipawns) converted to side-to-move POV."""
    e = eval_full(board)
    return e if board.turn == chess.WHITE else -e


class Searcher:
    """Negamax + alpha-beta + quiescence + small TT + MVV-LVA ordering."""

    def __init__(self) -> None:
        # key -> (depth, flag, value, best_move)
        self.tt: dict[int, tuple[int, int, int, chess.Move | None]] = {}
        self.info = SearchInfo()

    # -- move ordering --------------------------------------------------------
    def _mvv_lva(self, board: chess.Board, move: chess.Move) -> int:
        victim = board.piece_type_at(move.to_square)
        if victim is None:  # en-passant capture
            victim = chess.PAWN
        attacker = board.piece_type_at(move.from_square) or chess.PAWN
        score = _MVV[victim] * 16 - _MVV.get(attacker, 0)
        if move.promotion:
            score += _MVV.get(move.promotion, 0)
        return score

    def _ordered_moves(self, board: chess.Board, tt_move: chess.Move | None):
        caps, quiets = [], []
        for m in board.legal_moves:
            if board.is_capture(m) or m.promotion:
                caps.append(m)
            else:
                quiets.append(m)
        caps.sort(key=lambda m: self._mvv_lva(board, m), reverse=True)
        ordered = caps + quiets
        if tt_move is not None and tt_move in ordered:
            ordered.remove(tt_move)
            ordered.insert(0, tt_move)
        return ordered

    # -- quiescence -----------------------------------------------------------
    def _quiesce(self, board: chess.Board, alpha: int, beta: int, ply: int) -> int:
        self.info.qnodes += 1
        in_check = board.is_check()
        if not in_check:
            stand = evaluate_stm(board)
            if stand >= beta:
                return stand
            if stand > alpha:
                alpha = stand
        # In check we must search all evasions (no standing pat); otherwise only
        # captures/promotions to settle tactical noise at the horizon.
        if in_check:
            moves = list(board.legal_moves)
            if not moves:
                return -MATE_SCORE + ply          # checkmate
        else:
            moves = [m for m in board.legal_moves
                     if board.is_capture(m) or m.promotion]
            moves.sort(key=lambda m: self._mvv_lva(board, m), reverse=True)
        best = alpha
        for m in moves:
            board.push(m)
            score = -self._quiesce(board, -beta, -alpha, ply + 1)
            board.pop()
            if score >= beta:
                return score
            if score > best:
                best = score
            if score > alpha:
                alpha = score
        return best

    # -- negamax --------------------------------------------------------------
    def _negamax(self, board: chess.Board, depth: int, alpha: int, beta: int, ply: int) -> int:
        self.info.nodes += 1

        if ply > 0 and (board.is_repetition(3) or board.is_fifty_moves()
                        or board.is_insufficient_material()):
            return 0

        alpha_orig = alpha
        key = chess.polyglot.zobrist_hash(board)
        tt_move = None
        hit = self.tt.get(key)
        if hit is not None:
            t_depth, t_flag, t_val, t_move = hit
            tt_move = t_move
            if t_depth >= depth:
                self.info.tt_hits += 1
                if t_flag == _EXACT:
                    return t_val
                if t_flag == _LOWER and t_val > alpha:
                    alpha = t_val
                elif t_flag == _UPPER and t_val < beta:
                    beta = t_val
                if alpha >= beta:
                    return t_val

        if depth <= 0:
            return self._quiesce(board, alpha, beta, ply)

        moves = self._ordered_moves(board, tt_move)
        if not moves:
            return -MATE_SCORE + ply if board.is_check() else 0   # mate / stalemate

        best_val = -INF
        best_move = None
        for m in moves:
            board.push(m)
            val = -self._negamax(board, depth - 1, -beta, -alpha, ply + 1)
            board.pop()
            if val > best_val:
                best_val = val
                best_move = m
            if val > alpha:
                alpha = val
            if alpha >= beta:
                break

        flag = (_UPPER if best_val <= alpha_orig else
                _LOWER if best_val >= beta else _EXACT)
        self.tt[key] = (depth, flag, best_val, best_move)
        return best_val

    # -- root / iterative deepening ------------------------------------------
    def search(self, board: chess.Board, depth: int) -> SearchInfo:
        self.info = SearchInfo(depth=depth)
        start = time.perf_counter()
        best_move = None
        best_score = 0
        for d in range(1, depth + 1):
            alpha, beta = -INF, INF
            local_best = None
            local_score = -INF
            tt_move = best_move
            for m in self._ordered_moves(board, tt_move):
                board.push(m)
                val = -self._negamax(board, d - 1, -beta, -alpha, 1)
                board.pop()
                if val > local_score:
                    local_score = val
                    local_best = m
                if val > alpha:
                    alpha = val
            if local_best is not None:
                best_move, best_score = local_best, local_score
            # Stop early on a proven mate.
            if abs(best_score) > MATE_THRESHOLD:
                break
        self.info.elapsed = time.perf_counter() - start
        self.info.score = best_score
        self.info.pv = [best_move] if best_move else []
        return self.info


def best_move(board: chess.Board, depth: int) -> tuple[chess.Move | None, SearchInfo]:
    s = Searcher()
    info = s.search(board, depth)
    return (info.pv[0] if info.pv else None), info


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("fen", nargs="?", default=chess.STARTING_FEN, help="position FEN")
    p.add_argument("--depth", type=int, default=4)
    args = p.parse_args(argv)

    board = chess.Board(args.fen)
    move, info = best_move(board, args.depth)
    if move is None:
        print("no legal move (terminal position)")
        return 1
    san = board.san(move)
    nps = int((info.nodes + info.qnodes) / info.elapsed) if info.elapsed else 0
    print(f"bestmove {move.uci()} ({san})  score {info.score:+d}cp  depth {info.depth}")
    print(f"  nodes {info.nodes:,}  qnodes {info.qnodes:,}  tt_hits {info.tt_hits:,}  "
          f"{info.elapsed*1000:.0f}ms  {nps:,} nps")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
