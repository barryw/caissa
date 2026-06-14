#!/usr/bin/env python3
"""Assert two engine builds pick the SAME move on every test position.

The move-level safety net for speed optimizations: the eval-x10 verifier only
sees the static eval, so it cannot validate changes to attack detection,
move generation, or search ordering. If two builds agree on the best move for
a broad position sample at a fixed search depth, the optimization is behaviour-
preserving.

    python3 tools/verify_moves_identical.py --baseline-prg /tmp/speedbase.prg \
        --prg build/engine_harness.prg --n 120 --difficulty hard
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sim6502_headless_runner import Sim6502HeadlessRunner  # noqa: E402
from run_stockfish_strength import fen_to_c64, DIFFICULTY  # noqa: E402


def moves(prg: Path, fens: list[str], diff: int, timeout: int) -> list[tuple]:
    r = Sim6502HeadlessRunner(
        repo_root=Path(__file__).resolve().parents[1],
        program_path=prg.resolve(),
        symbols_path=prg.with_suffix(".sym").resolve(),
    )
    out = []
    try:
        for fen in fens:
            resp = r.best_move(fen_to_c64(fen), diff, timeout)
            out.append((resp.get("bestMoveFrom"), resp.get("bestMoveTo")))
    finally:
        r.close()
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--baseline-prg", type=Path, required=True)
    ap.add_argument("--prg", type=Path, required=True)
    ap.add_argument("--positions", type=Path, default=Path("build/texel_data.json"))
    ap.add_argument("--n", type=int, default=120)
    ap.add_argument("--difficulty", default="hard")
    ap.add_argument("--timeout", type=int, default=750_000_000)
    args = ap.parse_args()

    rows = json.loads(args.positions.read_text())["positions"]
    fens = [r["fen"] for r in rows]
    step = len(fens) / args.n
    sample = [fens[int(i * step)] for i in range(args.n)]
    diff = DIFFICULTY[args.difficulty]

    base = moves(args.baseline_prg, sample, diff, args.timeout)
    cand = moves(args.prg, sample, diff, args.timeout)
    diffs = [(sample[i], base[i], cand[i]) for i in range(args.n) if base[i] != cand[i]]
    print(f"checked {args.n} positions @ difficulty={args.difficulty}")
    if not diffs:
        print("PASS: every best move identical")
        return 0
    print(f"FAIL: {len(diffs)} positions differ (first 15):")
    for fen, b, c in diffs[:15]:
        print(f"  base={b} cand={c} | {fen}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
