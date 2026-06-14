#!/usr/bin/env python3
"""Verify the Part B centipawn rescale is move-identical (eval scaled by exactly N).

Part B multiplies every evaluation term by 10 (pawn 10 -> 100 units) purely to
unlock sub-10cp resolution. By construction it must change NO move decision: the
post-rescale eval of any position must equal the pre-rescale eval times the
scale factor, EXACTLY, for both the full eval and the lazy (material+PST+phase)
eval. Any deviation is a 16-bit carry/borrow bug in the rescale, and this script
pinpoints the offending FEN.

Usage:
    # before the rescale, on the HEAD build:
    python3 tools/verify_eval_rescale.py dump --prg build/engine_harness.prg \
        --positions build/texel_data.json --n 1500 --out /tmp/eval_base.json
    # ...do the rescale, rebuild...
    python3 tools/verify_eval_rescale.py compare --prg build/engine_harness.prg \
        --baseline /tmp/eval_base.json --factor 10 --n 1500
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sim6502_headless_runner import Sim6502HeadlessRunner  # noqa: E402
from run_stockfish_strength import fen_to_c64  # noqa: E402


def load_fens(positions_path: Path, n: int) -> list[str]:
    data = json.loads(positions_path.read_text())
    rows = data["positions"] if isinstance(data, dict) else data
    fens = [r["fen"] for r in rows]
    # Deterministic, spread sample across the dataset (no RNG -> reproducible).
    if n >= len(fens):
        return fens
    step = len(fens) / n
    return [fens[int(i * step)] for i in range(n)]


def dump_evals(prg: Path, fens: list[str]) -> dict[str, list[int]]:
    repo_root = Path(__file__).resolve().parents[1]
    runner = Sim6502HeadlessRunner(
        repo_root=repo_root,
        program_path=prg.resolve(),
        symbols_path=prg.with_suffix(".sym").resolve(),
    )
    out: dict[str, list[int]] = {}
    try:
        for i, fen in enumerate(fens):
            pos = fen_to_c64(fen)
            full = int(runner.evaluate(pos, lazy=0)["eval"])
            lazy = int(runner.evaluate(pos, lazy=1)["eval"])
            out[fen] = [full, lazy]
            if (i + 1) % 200 == 0:
                print(f"  dumped {i + 1}/{len(fens)}", file=sys.stderr)
    finally:
        runner.close()
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["dump", "compare"])
    ap.add_argument("--prg", type=Path, default=Path("build/engine_harness.prg"))
    ap.add_argument("--positions", type=Path, default=Path("build/texel_data.json"))
    ap.add_argument("--n", type=int, default=1500)
    ap.add_argument("--out", type=Path, default=Path("/tmp/eval_base.json"))
    ap.add_argument("--baseline", type=Path, default=Path("/tmp/eval_base.json"))
    ap.add_argument("--factor", type=int, default=10)
    args = ap.parse_args()

    fens = load_fens(args.positions, args.n)

    if args.mode == "dump":
        evals = dump_evals(args.prg, fens)
        args.out.write_text(json.dumps(evals))
        print(f"dumped {len(evals)} positions -> {args.out}")
        return 0

    # compare
    base = json.loads(args.baseline.read_text())
    cand = dump_evals(args.prg, fens)
    mismatches = []
    checked = 0
    for fen, (b_full, b_lazy) in base.items():
        if fen not in cand:
            continue
        c_full, c_lazy = cand[fen]
        checked += 1
        if c_full != b_full * args.factor:
            mismatches.append(("full", fen, b_full, c_full, b_full * args.factor))
        if c_lazy != b_lazy * args.factor:
            mismatches.append(("lazy", fen, b_lazy, c_lazy, b_lazy * args.factor))
    print(f"checked {checked} positions @ factor x{args.factor}")
    if not mismatches:
        print(f"PASS: every eval is exactly base x{args.factor} (move-identical)")
        return 0
    print(f"FAIL: {len(mismatches)} mismatches (showing first 20):")
    for kind, fen, b, c, want in mismatches[:20]:
        print(f"  [{kind}] base={b} want={want} got={c} diff={c - want} | {fen}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
