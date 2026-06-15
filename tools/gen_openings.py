#!/usr/bin/env python3
"""Generate a large, diverse, balanced opening book for self-play A/B testing.

Self-play in native/cref is DETERMINISTIC (reproducible -- good), but that means
a fixed opening set caps the real sample size: reusing an opening replays the
exact same game, so confidence intervals over duplicated games are fake-narrow.
The fix is many DISTINCT balanced start positions so every game in a high-N run
is independent.

Method: from the start position play N random plies (uniform over legal moves),
keep the position if it is quiet-ish and roughly balanced per the bit-exact eval
oracle (|eval| < THRESH), not in check, and not already seen. Random but
balance-filtered = diverse structures without lopsided starts that would bias the
A/B. Seeded for reproducibility.

  python3 tools/gen_openings.py --count 2000 --out tools/openings_big.txt
"""
from __future__ import annotations

import argparse
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import chess  # noqa: E402
from texel_eval import eval_full  # noqa: E402


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--count", type=int, default=2000)
    p.add_argument("--min-plies", type=int, default=6)
    p.add_argument("--max-plies", type=int, default=12)
    p.add_argument("--eval-thresh", type=int, default=150, help="|white-POV eval| cp ceiling (balance)")
    p.add_argument("--seed", type=int, default=20260614)
    p.add_argument("--out", type=Path, default=Path(__file__).resolve().parent / "openings_big.txt")
    args = p.parse_args(argv)

    rng = random.Random(args.seed)
    seen: set[str] = set()
    out: list[str] = []
    attempts = 0
    while len(out) < args.count and attempts < args.count * 200:
        attempts += 1
        b = chess.Board()
        plies = rng.randint(args.min_plies, args.max_plies)
        ok = True
        for _ in range(plies):
            moves = list(b.legal_moves)
            if not moves:
                ok = False
                break
            b.push(rng.choice(moves))
        if not ok or b.is_game_over() or b.is_check():
            continue
        key = b.board_fen() + (" w" if b.turn else " b")
        if key in seen:
            continue
        if abs(eval_full(b)) > args.eval_thresh:
            continue
        seen.add(key)
        out.append(b.fen())

    args.out.write_text(
        "# Diverse balanced opening book (random play, |eval|<%d, deduped).\n# %d positions, seed %d.\n"
        % (args.eval_thresh, len(out), args.seed)
        + "\n".join(out) + "\n")
    print(f"wrote {len(out)} openings to {args.out} ({attempts} attempts)")
    return 0 if len(out) >= args.count * 0.9 else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
