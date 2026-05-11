#!/usr/bin/env python3
"""Merge sharded Stockfish Elo ladder JSON files."""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict
from pathlib import Path
from typing import Any

from run_elo_ladder import choose_anchor, ladder_status, print_ladder_summary, summarize_rating
from run_stockfish_games import GameResult


def load_payload(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"{path} is not a ladder JSON object")
    if "games" not in payload or not isinstance(payload["games"], list):
        raise ValueError(f"{path} is missing a games list")
    return payload


def game_result_from_dict(raw: dict[str, Any]) -> GameResult:
    data = dict(raw)
    data["moves"] = []
    return GameResult(**data)


def merge_payloads(payloads: list[dict[str, Any]], source_files: list[str]) -> dict[str, Any]:
    if not payloads:
        raise ValueError("No ladder payloads provided")

    first = payloads[0]
    games_by_key: dict[tuple[int, int, int], dict[str, Any]] = {}
    for payload in payloads:
        for item in payload["games"]:
            if not isinstance(item, dict):
                raise ValueError("Game entry must be an object")
            stockfish_elo = int(item["stockfish_elo"])
            start_index = int(item["start_index"])
            game_number = int(item["game"]["game"])
            key = (stockfish_elo, start_index, game_number)
            if key in games_by_key:
                raise ValueError(f"Duplicate game in input shards: elo={stockfish_elo} start={start_index} game={game_number}")
            games_by_key[key] = item

    all_games = sorted(games_by_key.values(), key=lambda item: int(item["game"]["game"]))
    ratings = sorted({int(item["stockfish_elo"]) for item in all_games})
    summaries = []
    for stockfish_elo in ratings:
        results = [
            game_result_from_dict(item["game"])
            for item in all_games
            if int(item["stockfish_elo"]) == stockfish_elo
        ]
        summaries.append(summarize_rating(stockfish_elo, results))

    anchor = choose_anchor(summaries)
    return {
        "generated_by": "tools/merge_elo_ladders.py",
        "source_files": source_files,
        "complete": all(bool(payload.get("complete")) for payload in payloads),
        "runner_target": first.get("runner_target"),
        "c64_backend": first.get("c64_backend"),
        "difficulty": first.get("difficulty"),
        "stockfish_path": first.get("stockfish_path"),
        "stockfish_identity": first.get("stockfish_identity"),
        "stockfish_depth": first.get("stockfish_depth"),
        "stockfish_movetime_ms": first.get("stockfish_movetime_ms"),
        "analysis_depth": first.get("analysis_depth"),
        "analysis_multipv": first.get("analysis_multipv"),
        "max_plies": first.get("max_plies"),
        "adjudicate_max_plies": first.get("adjudicate_max_plies"),
        "adjudicate_win_cp": first.get("adjudicate_win_cp"),
        "status": ladder_status(summaries),
        "best_estimate": asdict(anchor) if anchor else None,
        "ratings": [asdict(summary) for summary in summaries],
        "games": all_games,
    }


def print_summary(payload: dict[str, Any]) -> None:
    summaries = []
    for rating in payload["ratings"]:
        games = [
            game_result_from_dict(item["game"])
            for item in payload["games"]
            if int(item["stockfish_elo"]) == int(rating["stockfish_elo"])
        ]
        summaries.append(summarize_rating(int(rating["stockfish_elo"]), games))

    print_ladder_summary(
        summaries,
        runner_target=str(payload.get("runner_target") or "-"),
        c64_backend=str(payload.get("c64_backend") or "-"),
        difficulty=str(payload.get("difficulty") or "-"),
        stockfish_depth=int(payload.get("stockfish_depth") or 0),
        stockfish_movetime_ms=payload.get("stockfish_movetime_ms"),
        analysis_depth=int(payload.get("analysis_depth") or 0),
    )


def run_self_test() -> int:
    sample = {
        "complete": True,
        "runner_target": "headless",
        "c64_backend": "sim6502",
        "difficulty": "hard",
        "stockfish_depth": 1,
        "analysis_depth": 1,
        "games": [
            {
                "stockfish_elo": 1320,
                "start_index": 1,
                "game": {
                    "game": 1,
                    "c64_color": "white",
                    "result": "1-0",
                    "c64_score": 1.0,
                    "termination": "checkmate",
                    "plies": 3,
                    "c64_moves": 2,
                    "c64_average_loss": 0.0,
                    "c64_max_loss": 0,
                    "c64_total_cycles": 100,
                    "moves": [],
                    "pgn": "1. Rh8# 1-0\n",
                    "final_score_cp": None,
                },
            }
        ],
    }
    merged = merge_payloads([sample], ["sample.json"])
    assert merged["ratings"][0]["c64_score"] == 1.0
    assert merged["best_estimate"]["stockfish_elo"] == 1320
    print("Self-test passed.")
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Merge sharded Stockfish Elo ladder JSON files.")
    parser.add_argument("inputs", nargs="*", type=Path)
    parser.add_argument("--json", type=Path, help="Write merged ladder JSON.")
    parser.add_argument("--pgn", type=Path, help="Write merged PGN.")
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        return run_self_test()
    if not args.inputs:
        print("At least one input ladder JSON is required.", file=sys.stderr)
        return 2

    payloads = [load_payload(path) for path in args.inputs]
    merged = merge_payloads(payloads, [str(path) for path in args.inputs])
    print_summary(merged)

    if args.json:
        args.json.write_text(json.dumps(merged, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if args.pgn:
        pgns = [str(item["game"].get("pgn") or "") for item in merged["games"]]
        args.pgn.write_text("\n\n".join(pgn for pgn in pgns if pgn).rstrip() + "\n", encoding="utf-8")

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
