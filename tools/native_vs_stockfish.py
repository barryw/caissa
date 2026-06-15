#!/usr/bin/env python3
"""Measure the native engine's ABSOLUTE Elo vs Stockfish at a FIXED search depth.

This is the measuring stick for the 1800 campaign. The native engine's strength
at depth d predicts the 6502's ceiling IF the 6502 reaches depth d (the eval +
search algorithm port faithfully; only speed is lost). So we pin native at a
fixed depth, play it against a Stockfish calibrated to a known Elo, and read off
native's Elo. Run it at d4/d5/d6 to get the depth->strength curve.

Stockfish strength: UCI_Elo (floor 1320) when --sf-elo given, else Skill Level
0-20 (weaker than 1320) when --sf-skill given.

  python3 tools/native_vs_stockfish.py --native-depth 5 --sf-elo 1500 --games 60 --jobs 8
"""
from __future__ import annotations

import argparse
import math
import subprocess
import sys
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import chess  # noqa: E402
import chess.engine  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
CREF = ROOT / "native" / "cref"
SF = "/opt/homebrew/bin/stockfish"
_MAT = {chess.PAWN: 100, chess.KNIGHT: 320, chess.BISHOP: 330, chess.ROOK: 500, chess.QUEEN: 900}


def material_cp(b: chess.Board) -> int:
    t = 0
    for pt, v in _MAT.items():
        t += v * (len(b.pieces(pt, chess.WHITE)) - len(b.pieces(pt, chess.BLACK)))
    return t


def native_move(fen: str, depth: int, nodes: int = 0, weights: str = "") -> chess.Move | None:
    cmd = [str(CREF), "bestmove", fen, str(depth)]
    if nodes or weights:
        cmd.append(str(nodes))          # nodes positional must precede weights
    if weights:
        cmd.append(weights)
    out = subprocess.run(cmd, capture_output=True, text=True).stdout
    if not out.startswith("bestmove"):
        return None
    try:
        return chess.Move.from_uci(out.split()[1])
    except (ValueError, IndexError):
        return None


def play_game(arg: dict) -> float:
    """Returns native's score (1 win / 0.5 draw / 0 loss)."""
    fen, native_white, depth, nodes = arg["fen"], arg["native_white"], arg["depth"], arg.get("nodes", 0)
    weights = arg.get("weights", "")
    sf_elo, sf_skill, sf_time = arg["sf_elo"], arg["sf_skill"], arg["sf_time"]
    board = chess.Board(fen)
    eng = chess.engine.SimpleEngine.popen_uci(SF)
    try:
        if sf_elo is not None:
            eng.configure({"UCI_LimitStrength": True, "UCI_Elo": sf_elo})
        elif sf_skill is not None:
            eng.configure({"Skill Level": sf_skill})
        while not board.is_game_over(claim_draw=True) and board.ply() < 250:
            native_turn = (board.turn == chess.WHITE) == native_white
            if native_turn:
                mv = native_move(board.fen(), depth, nodes, weights)
                if mv is None or mv not in board.legal_moves:
                    return 0.0  # native failed -> loss
            else:
                mv = eng.play(board, chess.engine.Limit(time=sf_time)).move
            board.push(mv)
    finally:
        eng.quit()

    if board.is_game_over(claim_draw=True):
        res = board.result(claim_draw=True)
    else:
        bal = material_cp(board)
        res = "1-0" if bal >= 300 else "0-1" if bal <= -300 else "1/2-1/2"
    if res == "1/2-1/2":
        return 0.5
    return 1.0 if (res == "1-0") == native_white else 0.0


def elo_diff(rate: float) -> float | None:
    if rate <= 0 or rate >= 1:
        return None
    return -400.0 * math.log10(1.0 / rate - 1.0)


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--native-depth", type=int, default=5)
    p.add_argument("--native-nodes", type=int, default=0, help="node budget per move (0 = fixed depth)")
    p.add_argument("--native-weights", type=str, default="", help="eval weight overrides key=val,... for native side")
    p.add_argument("--sf-elo", type=int, default=None, help="Stockfish UCI_Elo (>=1320)")
    p.add_argument("--sf-skill", type=int, default=None, help="Stockfish Skill Level 0-20 (weaker than 1320)")
    p.add_argument("--sf-time", type=float, default=0.1, help="Stockfish seconds/move")
    p.add_argument("--games", type=int, default=60)
    p.add_argument("--jobs", type=int, default=8)
    p.add_argument("--openings", type=Path, default=ROOT / "tools" / "openings_big.txt")
    args = p.parse_args(argv)
    if args.sf_elo is None and args.sf_skill is None:
        args.sf_elo = 1500

    fens = [ln.strip() for ln in args.openings.read_text().splitlines()
            if ln.strip() and not ln.startswith("#")]
    pairs = max(1, args.games // 2)
    tasks = []
    for i in range(pairs):
        for nw in (True, False):
            tasks.append({"fen": fens[i % len(fens)], "native_white": nw, "depth": args.native_depth,
                          "nodes": args.native_nodes, "weights": args.native_weights,
                          "sf_elo": args.sf_elo, "sf_skill": args.sf_skill, "sf_time": args.sf_time})

    opp = f"SF UCI_Elo={args.sf_elo}" if args.sf_elo else f"SF Skill={args.sf_skill}"
    print(f"native d{args.native_depth} vs {opp}: {len(tasks)} games, jobs={args.jobs}")
    scores = []
    with ProcessPoolExecutor(max_workers=args.jobs) as pool:
        futs = [pool.submit(play_game, t) for t in tasks]
        for i, f in enumerate(as_completed(futs), 1):
            scores.append(f.result())
            if i % 10 == 0 or i == len(tasks):
                s = sum(scores)
                print(f"  [{i}/{len(tasks)}] native {s:.1f}/{i} = {100*s/i:.1f}%", flush=True)

    n = len(scores)
    s = sum(scores)
    rate = s / n
    ed = elo_diff(rate)
    anchor = args.sf_elo if args.sf_elo else None
    print(f"\n=== native d{args.native_depth} vs {opp} ===")
    print(f"native: {s:.1f}/{n} = {100*rate:.1f}%   Elo diff vs opp ~ {ed:+.0f}" if ed is not None
          else f"native: {s:.1f}/{n} = {100*rate:.1f}%   (saturated)")
    if anchor and ed is not None:
        print(f"==> native Elo ~ {anchor + ed:.0f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
