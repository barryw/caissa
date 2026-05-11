#!/usr/bin/env python3
"""Extract high-loss C64 moves from a Colossus match into a strength corpus."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

from run_stockfish_strength import Stockfish, chess, require_chess  # noqa: E402


def safe_name(value: str) -> str:
    return re.sub(r"[^a-zA-Z0-9_-]+", "-", value).strip("-") or "position"


def blunder_bucket(loss: int) -> str:
    if loss >= 500:
        return "500-plus"
    if loss >= 300:
        return "300-plus"
    if loss >= 150:
        return "150-plus"
    if loss >= 90:
        return "90-plus"
    return "minor"


def analyze_c64_moves(payload: dict[str, Any], stockfish: Stockfish, depth: int, multipv: int) -> list[dict[str, Any]]:
    board = chess.Board()
    rows: list[dict[str, Any]] = []
    for move_record in payload.get("moves", []):
        move_uci = str(move_record.get("move") or "")
        try:
            move = chess.Move.from_uci(move_uci)
        except ValueError:
            move = None

        note = str(move_record.get("note") or "")
        if (
            move_record.get("actor") == "c64"
            and "forced-opening" not in note
            and move is not None
            and move in board.legal_moves
        ):
            fen = board.fen()
            lines = stockfish.analyze(fen, depth=depth, multipv=multipv)
            best = lines[0] if lines else None
            best_score = best.score_cp if best else None
            c64_score = None
            rank = None
            loss = None
            if best_score is not None:
                for index, line in enumerate(lines, start=1):
                    if line.move == move_uci:
                        rank = index
                        c64_score = line.score_cp
                        loss = max(0, best_score - line.score_cp)
                        break
                if loss is None:
                    reply_lines = stockfish.analyze(fen, depth=depth, multipv=1, moves=[move_uci])
                    if reply_lines:
                        c64_score = -reply_lines[0].score_cp
                        loss = max(0, best_score - c64_score)
            rows.append(
                {
                    "fen": fen,
                    "ply": int(move_record.get("ply", len(rows) + 1)),
                    "side": str(move_record.get("side") or ("white" if board.turn == chess.WHITE else "black")),
                    "c64_move": move_uci,
                    "c64_san": str(move_record.get("san") or board.san(move)),
                    "c64_cycles": move_record.get("c64_cycles"),
                    "stockfish_best": best.move if best else None,
                    "stockfish_best_score": best_score,
                    "stockfish_rank": rank,
                    "c64_score": c64_score,
                    "centipawn_loss": loss,
                    "multipv": [{"move": line.move, "score_cp": line.score_cp} for line in lines],
                }
            )

        if move is None or move not in board.legal_moves:
            break
        board.push(move)
    return rows


def build_corpus(rows: list[dict[str, Any]], threshold: int, source: str, depth: int) -> dict[str, Any]:
    positions: list[dict[str, Any]] = []
    seen_fens: set[str] = set()
    for row in rows:
        loss = row.get("centipawn_loss")
        if loss is None or int(loss) < threshold:
            continue
        fen = str(row.get("fen") or "")
        if not fen or fen in seen_fens:
            continue
        seen_fens.add(fen)
        side = str(row.get("side") or "unknown")
        ply = int(row.get("ply") or 0)
        c64_played = str(row.get("c64_san") or row.get("c64_move") or "unknown")
        best = str(row.get("stockfish_best") or "unknown")
        name = safe_name(f"colossus-ply-{ply:03d}-{side}-loss-{int(loss)}")
        positions.append(
            {
                "name": name,
                "fen": fen,
                "description": (
                    f"{side} to move against Colossus: C64 played {c64_played}, "
                    f"Stockfish preferred {best}, loss {int(loss)}cp"
                ),
                "category": "colossus-blunder",
                "tags": [
                    "colossus",
                    "blunder",
                    side,
                    f"loss-{blunder_bucket(int(loss))}",
                ],
                "source": source,
                "ply": ply,
                "side": side,
                "c64_move": row.get("c64_move"),
                "c64_san": row.get("c64_san"),
                "stockfish_best": row.get("stockfish_best"),
                "stockfish_rank": row.get("stockfish_rank"),
                "stockfish_best_score": row.get("stockfish_best_score"),
                "c64_score": row.get("c64_score"),
                "centipawn_loss": int(loss),
                "c64_cycles": row.get("c64_cycles"),
            }
        )

    positions.sort(key=lambda item: (-int(item["centipawn_loss"]), int(item["ply"])))
    return {
        "generated_by": "tools/extract_colossus_blunders.py",
        "source": source,
        "stockfish_depth": depth,
        "blunder_threshold": threshold,
        "positions": positions,
    }


def run_self_test() -> int:
    rows = [
        {
            "fen": chess.STARTING_FEN,
            "ply": 1,
            "side": "white",
            "c64_move": "g1h3",
            "c64_san": "Nh3",
            "stockfish_best": "e2e4",
            "centipawn_loss": 160,
        },
        {
            "fen": chess.STARTING_FEN,
            "ply": 3,
            "side": "white",
            "c64_move": "g1f3",
            "c64_san": "Nf3",
            "stockfish_best": "e2e4",
            "centipawn_loss": 40,
        },
    ]
    corpus = build_corpus(rows, threshold=90, source="self-test", depth=1)
    assert len(corpus["positions"]) == 1
    assert corpus["positions"][0]["category"] == "colossus-blunder"
    assert corpus["positions"][0]["tags"][-1] == "loss-150-plus"
    print("Self-test passed.")
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, nargs="?", help="Colossus match JSON, e.g. build/colossus_match.json.")
    parser.add_argument("--stockfish-path", default=os.environ.get("STOCKFISH_PATH") or shutil.which("stockfish"))
    parser.add_argument("--stockfish-depth", type=int, default=12)
    parser.add_argument("--multipv", type=int, default=3)
    parser.add_argument("--threshold", type=int, default=90)
    parser.add_argument("--json", type=Path, required=False, help="Write output corpus JSON.")
    parser.add_argument("--analysis-json", type=Path, help="Optional detailed per-move analysis output.")
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    require_chess()
    if args.self_test:
        return run_self_test()
    if args.input is None:
        print("Input match JSON is required.", file=sys.stderr)
        return 2
    if not args.stockfish_path:
        print("Could not find Stockfish. Set STOCKFISH_PATH or pass --stockfish-path.", file=sys.stderr)
        return 2

    payload = json.loads(args.input.read_text(encoding="utf-8"))
    stockfish = Stockfish(args.stockfish_path)
    try:
        rows = analyze_c64_moves(payload, stockfish, depth=args.stockfish_depth, multipv=args.multipv)
    finally:
        stockfish.close()

    if args.analysis_json:
        args.analysis_json.parent.mkdir(parents=True, exist_ok=True)
        args.analysis_json.write_text(json.dumps({"moves": rows}, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    corpus = build_corpus(rows, threshold=args.threshold, source=str(args.input), depth=args.stockfish_depth)
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(corpus, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    else:
        print(json.dumps(corpus, indent=2, sort_keys=True))

    print(
        f"extracted {len(corpus['positions'])} Colossus blunder positions "
        f"at depth {args.stockfish_depth}, threshold {args.threshold}cp",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
