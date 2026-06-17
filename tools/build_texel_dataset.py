#!/usr/bin/env python3
"""Build a LARGE labeled position dataset for Texel eval tuning.

Positions come from Stockfish self-play games seeded from a broad opening book,
with top-k opening randomness AND occasional random-move injection for variety
and to reach realistic endgames. Each sampled position is QUIET-filtered (not in
check, best move not a capture) and labeled with a deeper Stockfish eval
(white-POV centipawns, clamped). Tuning material+PST (and tapered MG/EG PST)
toward these labels teaches Stockfish's positional understanding -- a far cleaner
signal than the weak engine's own game results.

Durability: each worker streams its positions to a JSONL shard
(build/texel_shards/shard_<seed>.jsonl), flushed per game, so a multi-hour run
survives crashes and can be extended. The merge step reads all shards, dedups,
optionally phase-balances (cap per game-phase bucket), and writes the final JSON.

Output JSON: {"positions": [{"fen": "...", "cp": <white-POV cp>}, ...], ...}

  # generate (big): one worker per core, lots of games
  python3 tools/build_texel_dataset.py gen --games 8000 --jobs 9
  # merge shards -> final dataset, phase-balanced to <=40k per phase bucket
  python3 tools/build_texel_dataset.py merge --phase-cap 40000 --out build/texel_data.json
"""

from __future__ import annotations

import argparse
import json
import random
import sys
import time
from pathlib import Path
from concurrent.futures import ProcessPoolExecutor, as_completed

sys.path.insert(0, str(Path(__file__).resolve().parent))
import chess          # noqa: E402
import chess.engine   # noqa: E402

REPO = Path(__file__).resolve().parents[1]
SHARD_DIR = REPO / "build" / "texel_shards"
CLAMP_CP = 1500
PHASE_WEIGHT = {chess.KNIGHT: 1, chess.BISHOP: 1, chess.ROOK: 2, chess.QUEEN: 4}


def game_phase(board: chess.Board) -> int:
    p = 0
    for pt, wt in PHASE_WEIGHT.items():
        p += wt * (len(board.pieces(pt, chess.WHITE)) + len(board.pieces(pt, chess.BLACK)))
    return min(p, 24)


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


def _worker(a: dict) -> int:
    """Generate games, stream quiet labeled positions to a JSONL shard. Returns count."""
    rng = random.Random(a["seed"])
    openings = a["openings"]
    eng = chess.engine.SimpleEngine.popen_uci(a["sf_path"])
    shard = SHARD_DIR / f"shard_{a['seed']}.jsonl"
    written = 0
    try:
        with shard.open("a", buffering=1) as fh:
            for _ in range(a["n_games"]):
                board = chess.Board(rng.choice(openings))
                sampled: list[str] = []
                while not board.is_game_over() and board.ply() < a["max_ply"]:
                    if board.ply() < 16:                          # opening: top-k variety
                        infos = eng.analyse(board, chess.engine.Limit(depth=a["gen_depth"]), multipv=4)
                        moves = [i["pv"][0] for i in infos if i.get("pv")]
                        move = rng.choice(moves) if moves else None
                    elif rng.random() < a["rand_prob"]:           # inject a random legal move
                        move = rng.choice(list(board.legal_moves))
                    else:
                        res = eng.play(board, chess.engine.Limit(depth=a["gen_depth"]))
                        move = res.move
                    if move is None:
                        break
                    board.push(move)
                    if (board.ply() >= a["min_ply"] and board.ply() % a["sample_every"] == 0
                            and not board.is_check()):
                        sampled.append(board.fen())
                # label + quiet-filter
                for fen in sampled:
                    b = chess.Board(fen)
                    info = eng.analyse(b, chess.engine.Limit(depth=a["label_depth"]))
                    pv = info.get("pv") or []
                    if pv and b.is_capture(pv[0]):                # not quiet -> skip
                        continue
                    cp = _white_pov_cp(info["score"])
                    if cp is None:
                        continue
                    fh.write(json.dumps({"fen": fen, "cp": cp, "ph": game_phase(b)}) + "\n")
                    written += 1
    finally:
        eng.quit()
    return written


def cmd_gen(args) -> int:
    import shutil
    sf = args.sf_path or shutil.which("stockfish") or "/opt/homebrew/bin/stockfish"
    openings = [ln.strip() for ln in args.openings.read_text().splitlines()
                if ln.strip() and not ln.startswith("#")]
    SHARD_DIR.mkdir(parents=True, exist_ok=True)
    per = max(1, args.games // args.jobs)
    tasks = [{"sf_path": sf, "openings": openings, "n_games": per,
              "gen_depth": args.gen_depth, "label_depth": args.label_depth,
              "seed": args.seed_base + i, "sample_every": args.sample_every,
              "min_ply": args.min_ply, "max_ply": args.max_ply, "rand_prob": args.rand_prob}
             for i in range(args.jobs)]
    print(f"gen ~{per*args.jobs} games x {args.jobs} workers "
          f"(gen d{args.gen_depth}, label d{args.label_depth}, rand {args.rand_prob}) -> {SHARD_DIR}")
    t0 = time.time()
    total = 0
    with ProcessPoolExecutor(max_workers=args.jobs) as pool:
        futs = [pool.submit(_worker, t) for t in tasks]
        for fut in as_completed(futs):
            total += fut.result()
            print(f"  worker done; shard total ~{shard_count()} positions ({time.time()-t0:.0f}s)")
    print(f"gen complete: {shard_count()} positions across shards in {time.time()-t0:.0f}s")
    return 0


def shard_count() -> int:
    return sum(1 for f in SHARD_DIR.glob("shard_*.jsonl") for _ in f.open())


def cmd_merge(args) -> int:
    seen: set[str] = set()
    buckets: dict[int, list[dict]] = {}
    nshards = 0
    for f in sorted(SHARD_DIR.glob("shard_*.jsonl")):
        nshards += 1
        for line in f.open():
            line = line.strip()
            if not line:
                continue
            rec = json.loads(line)
            if rec["fen"] in seen:
                continue
            seen.add(rec["fen"])
            buckets.setdefault(rec.get("ph", -1), []).append({"fen": rec["fen"], "cp": rec["cp"]})
    rng = random.Random(12345)
    positions: list[dict] = []
    print(f"merged {nshards} shards. phase histogram (cap={args.phase_cap}):")
    for ph in sorted(buckets):
        recs = buckets[ph]
        kept = recs
        if args.phase_cap and len(recs) > args.phase_cap:
            kept = rng.sample(recs, args.phase_cap)
        positions.extend(kept)
        bar = "#" * min(60, len(recs) // max(1, args.bar_scale))
        print(f"  phase {ph:2d}: {len(recs):7d} -> kept {len(kept):7d}  {bar}")
    rng.shuffle(positions)
    args.out.write_text(json.dumps({"positions": positions, "label_depth": args.label_depth,
                                    "clamp_cp": CLAMP_CP, "n": len(positions)}, indent=0))
    print(f"wrote {len(positions)} positions to {args.out}")
    return 0


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    g = sub.add_parser("gen", help="generate shards")
    g.add_argument("--sf-path", default=None)
    g.add_argument("--openings", type=Path, default=REPO / "data" / "openings_big.txt")
    g.add_argument("--games", type=int, default=8000)
    g.add_argument("--jobs", type=int, default=9)
    g.add_argument("--gen-depth", type=int, default=6)
    g.add_argument("--label-depth", type=int, default=10)
    g.add_argument("--sample-every", type=int, default=2)
    g.add_argument("--min-ply", type=int, default=8)
    g.add_argument("--max-ply", type=int, default=200)
    g.add_argument("--rand-prob", type=float, default=0.08, help="prob of a random legal move (variety/endgames)")
    g.add_argument("--seed-base", type=int, default=1000)
    g.set_defaults(fn=cmd_gen)

    m = sub.add_parser("merge", help="merge shards -> dataset")
    m.add_argument("--out", type=Path, default=REPO / "build" / "texel_data_big.json")
    m.add_argument("--phase-cap", type=int, default=0, help="max positions per phase bucket (0 = no cap)")
    m.add_argument("--label-depth", type=int, default=10)
    m.add_argument("--bar-scale", type=int, default=2000)
    m.set_defaults(fn=cmd_merge)

    args = p.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
