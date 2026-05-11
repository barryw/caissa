#!/usr/bin/env python3
"""Extract high-loss C64 moves from Elo ladder JSON into a strength corpus."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from run_stockfish_games import blunder_bucket, safe_name


def extract_positions(payload: dict[str, Any], threshold: int) -> list[dict[str, Any]]:
    positions = []
    seen_fens = set()
    for item in payload.get("games", []):
        stockfish_elo = int(item.get("stockfish_elo", 0))
        start_index = int(item.get("start_index", 0))
        game = item.get("game", {})
        game_number = int(game.get("game", 0))
        c64_color = str(game.get("c64_color", "unknown"))
        for move in game.get("moves", []):
            if move.get("actor") != "c64" or not move.get("legal") or not move.get("move"):
                continue
            loss = move.get("centipawn_loss")
            if loss is None or int(loss) < threshold:
                continue
            fen = str(move.get("fen") or "")
            if not fen or fen in seen_fens:
                continue
            seen_fens.add(fen)

            side = str(move.get("side", "unknown"))
            best = str(move.get("stockfish_best") or "unknown")
            c64_played = str(move.get("san") or move.get("move"))
            name = safe_name(
                f"elo-{stockfish_elo}-start-{start_index:02d}-"
                f"game-{game_number:03d}-ply-{int(move.get('ply', 0)):03d}-"
                f"{side}-loss-{int(loss)}"
            )
            positions.append(
                {
                    "name": name,
                    "fen": fen,
                    "description": (
                        f"{side} to move: C64 played {c64_played}, "
                        f"Stockfish preferred {best}, loss {int(loss)}cp"
                    ),
                    "category": "ladder-blunder",
                    "tags": [
                        "ladder",
                        "blunder",
                        c64_color,
                        side,
                        f"elo-{stockfish_elo}",
                        f"start-{start_index:02d}",
                        f"loss-{blunder_bucket(int(loss))}",
                    ],
                    "stockfish_elo": stockfish_elo,
                    "start_index": start_index,
                    "game": game_number,
                    "ply": int(move.get("ply", 0)),
                    "c64_color": c64_color,
                    "side": side,
                    "c64_move": move.get("move"),
                    "c64_san": move.get("san"),
                    "stockfish_best": move.get("stockfish_best"),
                    "stockfish_rank": move.get("stockfish_rank"),
                    "centipawn_loss": int(loss),
                    "c64_cycles": move.get("c64_cycles"),
                }
            )

    positions.sort(key=lambda item: (-int(item["centipawn_loss"]), str(item["name"])))
    return positions


def run_self_test() -> int:
    payload = {
        "games": [
            {
                "stockfish_elo": 1320,
                "start_index": 1,
                "game": {
                    "game": 1,
                    "c64_color": "white",
                    "moves": [
                        {
                            "actor": "c64",
                            "legal": True,
                            "move": "g1f3",
                            "san": "Nf3",
                            "fen": "8/8/8/8/8/8/8/K6k w - - 0 1",
                            "ply": 3,
                            "side": "white",
                            "stockfish_best": "g1h3",
                            "stockfish_rank": None,
                            "centipawn_loss": 200,
                            "c64_cycles": 123,
                        },
                    ],
                },
            }
        ]
    }
    positions = extract_positions(payload, 150)
    assert len(positions) == 1
    assert positions[0]["category"] == "ladder-blunder"
    assert positions[0]["tags"][-1] == "loss-150-plus"
    assert extract_positions(payload, 300) == []
    print("Self-test passed.")
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Extract ladder blunders into a Stockfish strength corpus.")
    parser.add_argument("input", type=Path, nargs="?", help="Input ladder JSON.")
    parser.add_argument("--threshold", type=int, default=150)
    parser.add_argument("--json", type=Path, required=False, help="Write output corpus JSON.")
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        return run_self_test()
    if args.input is None:
        print("Input ladder JSON is required.", file=sys.stderr)
        return 2
    output = args.json or Path("build/stockfish_ladder_blunders.json")
    payload = json.loads(args.input.read_text(encoding="utf-8"))
    positions = extract_positions(payload, args.threshold)
    corpus = {
        "generated_by": "tools/extract_ladder_blunders.py",
        "source": str(args.input),
        "blunder_threshold": args.threshold,
        "positions": positions,
    }
    output.write_text(json.dumps(corpus, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Wrote {len(positions)} blunder position(s) >= {args.threshold}cp to {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
