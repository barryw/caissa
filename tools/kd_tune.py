#!/usr/bin/env python3
"""Coordinate-descent calibration of the king-danger term (eval rewrite term #1)
to minimize Texel MSE vs Stockfish via `cref mse` -- the supervise-to-SF strategy
from docs/plans/2026-06-18-eval-rewrite-design.md.

Tunes a small, interpretable parameter set (NOT the 16 raw table cells, which
would overfit and could go non-monotonic):
  kd_w_queen, kd_w_rook, kd_w_minor  -- attacker unit weights per ring square
  kd_phase_min_heavy                 -- enemy heavy material (Q=2,R=1) to activate
  table_lin, table_quad              -- safety table shape: table[i] = lin*i + quad*i^2
                                        (monotonic by construction; table[0]=0)

MSE improvement is necessary, NOT sufficient (self-play/Texel gains overstate
real Elo). Confirm the winner with tools/native_vs_stockfish.py at depth 4 and an
SPRT self-play run before shipping.

  python3 tools/kd_tune.py --data build/kd_tune.tsv --rounds 3
"""
from __future__ import annotations
import argparse, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CREF = ROOT / "build" / "cref"
KD_TABLE_SIZE = 16

# starting point (chess-sensible; coordinate descent refines)
INIT = {
    "kd_w_queen": 3, "kd_w_rook": 2, "kd_w_minor": 1,
    "kd_phase_min_heavy": 3,
    "table_lin": 3, "table_quad": 1,
}

# candidate grids per parameter
GRIDS = {
    "kd_w_queen": [1, 2, 3, 4, 5, 6],
    "kd_w_rook": [1, 2, 3, 4],
    "kd_w_minor": [0, 1, 2, 3],
    "kd_phase_min_heavy": [1, 2, 3, 4, 5, 6],
    "table_lin": [0, 1, 2, 3, 4, 6, 8],
    "table_quad": [0, 1, 2, 3, 4, 6],
}


def table_cells(lin: int, quad: int) -> dict:
    """safety table[i] = lin*i + quad*i^2, clamped >= 0, table[0] = 0."""
    return {f"kd_st{i}": max(0, lin * i + quad * i * i) for i in range(KD_TABLE_SIZE)}


def spec(params: dict) -> str:
    w = {k: params[k] for k in ("kd_w_queen", "kd_w_rook", "kd_w_minor", "kd_phase_min_heavy")}
    w.update(table_cells(params["table_lin"], params["table_quad"]))
    return ",".join(f"{k}={v}" for k, v in w.items())


def mse(data: Path, params: dict) -> float:
    out = subprocess.run([str(CREF), "mse", str(data), spec(params)],
                         capture_output=True, text=True).stdout
    return float(out.split()[0])


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default=str(ROOT / "build" / "kd_tune.tsv"))
    ap.add_argument("--rounds", type=int, default=3)
    args = ap.parse_args()
    data = Path(args.data)

    base_off = subprocess.run([str(CREF), "mse", str(data)], capture_output=True, text=True).stdout
    print(f"baseline (king-danger OFF): {base_off.strip()}")

    params = dict(INIT)
    best = mse(data, params)
    print(f"init: {best:.8f}  {spec(params)}")

    for r in range(args.rounds):
        improved = False
        for key, grid in GRIDS.items():
            cur = params[key]
            best_v, best_m = cur, best
            for v in grid:
                if v == cur:
                    continue
                params[key] = v
                m = mse(data, params)
                if m < best_m:
                    best_v, best_m = v, m
            params[key] = best_v
            if best_m < best:
                print(f"  round {r}: {key} {cur} -> {best_v}  mse {best:.8f} -> {best_m:.8f}")
                best = best_m
                improved = True
        if not improved:
            print(f"round {r}: no improvement, converged")
            break

    print(f"\nbest mse: {best:.8f}")
    print(f"best spec: {spec(params)}")
    print(f"params: {params}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
