#!/usr/bin/env python3
"""Build a labeled position dataset for Texel eval tuning.

Positions come from short Stockfish self-play games (realistic distribution
across all game stages, with top-k randomness for variety); each position is
labeled with a deeper Stockfish eval (white-POV centipawns, clamped). Tuning the
engine's material+PST toward these labels teaches it Stockfish's positional
understanding -- much cleaner signal than the weak engine's own game results.

Output JSON: {"positions": [{"fen": "...", "cp": <white-POV centipawns>}, ...]}

Run on beast for speed:
    python3 tools/build_texel_dataset.py --games 600 --jobs 26 \
        --out build/texel_data.json
"""

from __future__ import annotations

import argparse
import json
import random
import sys
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import chess  # noqa: E402
import chess.engine  # noqa: E402

CLAMP_CP = 1500


def _load_openings(path: Path) -> list[str]:
    return [ln.strip() for ln in path.read_text().splitlines() if ln.strip() and not ln.startswith("#")]


def _white_pov_cp(score: chess.engine.PovScore) -> int | None:
    s = score.white()
    if s.is_mate():
        m = s.mate()
        if m == 0:
            return None
        return CLAMP_CP if m > 0 else -CLAMP_CP
    cp = s.score()
    if cp is None:
        return None
    return max(-CLAMP_CP, min(CLAMP_CP, cp))


def _worker(args_dict: dict) -> list[dict]:
    sf_path = args_dict["sf_path"]
    openings = args_dict["openings"]
    n_games = args_dict["n_games"]
    gen_depth = args_dict["gen_depth"]
    label_depth = args_dict["label_depth"]
    seed = args_dict["seed"]
    sample_every = args_dict["sample_every"]
    min_ply = args_dict["min_ply"]
    max_ply = args_dict["max_ply"]

    rng = random.Random(seed)
    engine = chess.engine.SimpleEngine.popen_uci(sf_path)
    out: list[dict] = []
    seen: set[str] = set()
    try:
        for g in range(n_games):
            board = chess.Board(rng.choice(openings))
            sampled_this_game = []
            while not board.is_game_over() and board.ply() < max_ply:
                # Top-k randomness in the opening for variety; best move afterward.
                if board.ply() < 16:
                    infos = engine.analyse(board, chess.engine.Limit(depth=gen_depth), multipv=3)
                    moves = [i["pv"][0] for i in infos if i.get("pv")]
                    move = rng.choice(moves) if moves else None
                else:
                    res = engine.play(board, chess.engine.Limit(depth=gen_depth))
                    move = res.move
                if move is None:
                    break
                board.push(move)
                if board.ply() >= min_ply and board.ply() % sample_every == 0 and not board.is_check():
                    fen = board.fen()
                    if fen not in seen:
                        seen.add(fen)
                        sampled_this_game.append(fen)
            # Label sampled positions with a deeper eval.
            for fen in sampled_this_game:
                info = engine.analyse(chess.Board(fen), chess.engine.Limit(depth=label_depth))
                cp = _white_pov_cp(info["score"])
                if cp is not None:
                    out.append({"fen": fen, "cp": cp})
    finally:
        engine.quit()
    return out


def main(argv: list[str]) -> int:
    repo_root = Path(__file__).resolve().parents[1]
    import shutil

    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--sf-path", default=shutil.which("stockfish") or "/usr/games/stockfish")
    p.add_argument("--openings", type=Path, default=repo_root / "tools" / "selfplay_openings.txt")
    p.add_argument("--games", type=int, default=600, help="total self-play games across all workers")
    p.add_argument("--jobs", type=int, default=8)
    p.add_argument("--gen-depth", type=int, default=6)
    p.add_argument("--label-depth", type=int, default=10)
    p.add_argument("--sample-every", type=int, default=4, help="sample a position every N plies")
    p.add_argument("--min-ply", type=int, default=8)
    p.add_argument("--max-ply", type=int, default=120)
    p.add_argument("--out", type=Path, default=repo_root / "build" / "texel_data.json")
    args = p.parse_args(argv)

    openings = _load_openings(args.openings)
    per = max(1, args.games // args.jobs)
    tasks = [{
        "sf_path": args.sf_path, "openings": openings, "n_games": per,
        "gen_depth": args.gen_depth, "label_depth": args.label_depth,
        "seed": 1000 + i, "sample_every": args.sample_every,
        "min_ply": args.min_ply, "max_ply": args.max_ply,
    } for i in range(args.jobs)]

    print(f"generating ~{per * args.jobs} games on {args.jobs} workers "
          f"(gen d{args.gen_depth}, label d{args.label_depth})...")
    positions: list[dict] = []
    seen: set[str] = set()
    with ProcessPoolExecutor(max_workers=args.jobs) as pool:
        futs = [pool.submit(_worker, t) for t in tasks]
        for fut in as_completed(futs):
            for rec in fut.result():
                if rec["fen"] not in seen:
                    seen.add(rec["fen"])
                    positions.append(rec)
            print(f"  collected {len(positions)} unique labeled positions")

    args.out.write_text(json.dumps({"positions": positions,
                                    "gen_depth": args.gen_depth, "label_depth": args.label_depth,
                                    "clamp_cp": CLAMP_CP}, indent=0))
    print(f"wrote {len(positions)} positions to {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
