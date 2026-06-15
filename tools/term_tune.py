#!/usr/bin/env python3
"""Coordinate-descent tune of the eval's POSITIONAL TERM weights to minimize
Texel MSE vs Stockfish (via `cref mse`, fast C eval over the dataset).

Material+PST is already Texel-tuned (the +136 win) and tapped; this tunes the
remaining hand-set scalar terms (attacks, pins, pawn structure, passers, rook
activity, king safety, endgame). MSE improvement is necessary not sufficient --
confirm the winner vs Stockfish (native_vs_stockfish) before shipping.

  python3 tools/term_tune.py --data build/texel_big.tsv --rounds 3
"""
from __future__ import annotations
import argparse, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CREF = ROOT / "native" / "cref"

# baseline term values (eval_reset_weights); material/PST excluded (tapped).
BASE = {
    "pawn_attack_minor": 600, "pawn_attack_rook": 600, "pawn_attack_queen": 850,
    "queen_attack_minor": 750, "minor_attack_rook": 280, "minor_attack_queen": 350,
    "knight_outpost": 250,
    "pinned_pawn": 120, "pinned_minor": 250, "pinned_rook": 350, "pinned_queen": 450,
    "pinned_attacked": 200,
    "doubled_pawn": 150, "isolated_pawn": 200, "advanced_pawn": 80, "deep_advanced_pawn": 160,
    "rook_behind_passer": 200, "connected_passer": 120, "protected_passer": 80,
    "blockaded_passer": 100, "bishop_pair": 200, "rook_open_file": 250,
    "rook_semi_open_file": 120, "heavy_seventh_rank": 180,
    "endgame_king_activity": 300, "endgame_rook_open_file": 600, "endgame_rook_king_cutoff": 250,
    "castled": 30, "pawn_shield": 10, "open_file_penalty": 25, "semi_open_file_penalty": 12,
    "king_center": 30, "king_march_base": 8, "king_zone_attack": 5,
}


def mse(data: Path, weights: dict) -> float:
    spec = ",".join(f"{k}={v}" for k, v in weights.items())
    out = subprocess.run([str(CREF), "mse", str(data), spec],
                         capture_output=True, text=True).stdout
    return float(out.split()[0])


def grid(base: int) -> list[int]:
    if base == 0:
        return [0, 5, 10, 20, 40]
    cand = {0, base, base // 4, base // 2, (3 * base) // 4,
            (3 * base) // 2, 2 * base, 3 * base, 4 * base}
    return sorted(c for c in cand if c >= 0)


def main(argv):
    p = argparse.ArgumentParser()
    p.add_argument("--data", type=Path, default=ROOT / "build" / "texel_big.tsv")
    p.add_argument("--rounds", type=int, default=3)
    p.add_argument("--out", type=Path, default=ROOT / "build" / "term_tune.txt")
    args = p.parse_args(argv)

    w = dict(BASE)
    base_mse = mse(args.data, w)
    print(f"baseline MSE = {base_mse:.6f}  ({len(BASE)} terms)\n", flush=True)
    cur = base_mse
    for rnd in range(1, args.rounds + 1):
        improved = 0
        for term in BASE:
            best_v, best_m = w[term], cur
            for v in grid(BASE[term]):
                if v == w[term]:
                    continue
                trial = dict(w); trial[term] = v
                m = mse(args.data, trial)
                if m < best_m - 1e-7:
                    best_m, best_v = m, v
            if best_v != w[term]:
                print(f"  r{rnd} {term}: {w[term]} -> {best_v}   MSE {cur:.6f} -> {best_m:.6f}", flush=True)
                w[term] = best_v; cur = best_m; improved += 1
        print(f"= round {rnd}: MSE {cur:.6f} ({100*(base_mse-cur)/base_mse:.2f}% under baseline), {improved} terms moved\n", flush=True)
        if improved == 0:
            break

    changed = {k: v for k, v in w.items() if v != BASE[k]}
    spec = ",".join(f"{k}={v}" for k, v in changed.items())
    print("=== tuned term spec (changed only) ===")
    print(spec)
    args.out.write_text(spec + "\n")
    print(f"\nwrote {args.out}\nconfirm vs SF: native_vs_stockfish --native-nodes 12000 --sf-elo 1500 --games 240 --native-weights \"{spec}\"")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
