#!/usr/bin/env python3
"""Automated eval-weight tuner on the native reference engine (Tier 3).

Turns "tune the engine" into a background search. For each candidate weight
change it runs a reference-vs-reference self-play A/B (native/cref) and reads the
Elo/score. Two-tier to stay fast AND trustworthy:

  SCREEN at d3 (each ~seconds)  -> keep candidates scoring >= promote threshold
  CONFIRM at d4 (each ~tens-s)  -> SPRT verdict; d4 is the depth that catches
                                   depth-dependent terms (d3 lied about pins)

Reports a ranked leaderboard of d4-confirmed Elo improvements + a stacked
candidate combining every individually-winning change for a final combined A/B.

Each A/B is engine A = baseline + the one override, vs engine B = baseline. So a
positive Elo means the change wins games. Winners are re-confirmed on the 6502
before shipping (this is the iteration surface, not the ship target).

  python3 tools/native_tune.py                 # full curated sweep
  python3 tools/native_tune.py --only king_zone_attack,castled
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CREF = ROOT / "native" / "cref"

# Baseline weights (must match eval.c eval_reset_weights / cref set_weight keys).
BASELINE = {
    "pawn": 100, "knight": 320, "bishop": 330, "rook": 500, "queen": 900,
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

# Curated sweep: the structural / positional / aggression terms most likely to
# move strength. Each maps to the multipliers tested (baseline 1.0 implicit).
SWEEP = {
    # --- aggression knobs (reward attacking enemy pieces / king) ---
    "king_zone_attack":     [0.0, 2.0, 3.0, 5.0],
    "pawn_attack_minor":    [0.5, 1.5, 2.0],
    "pawn_attack_rook":     [0.5, 1.5, 2.0],
    "pawn_attack_queen":    [0.5, 1.5, 2.0],
    "queen_attack_minor":   [0.5, 1.5, 2.0],
    "minor_attack_rook":    [0.5, 1.5, 2.0],
    "minor_attack_queen":   [0.5, 1.5, 2.0],
    "knight_outpost":       [0.5, 1.5, 2.0],
    # --- king safety ---
    "castled":              [0.5, 1.5, 2.0, 3.0],
    "pawn_shield":          [0.0, 2.0, 3.0],
    "open_file_penalty":    [0.5, 1.5, 2.0],
    "semi_open_file_penalty": [0.5, 1.5, 2.0],
    "king_center":          [0.5, 1.5, 2.0],
    # --- pawn structure ---
    "doubled_pawn":         [0.5, 1.5, 2.0],
    "isolated_pawn":        [0.5, 1.5, 2.0],
    "advanced_pawn":        [0.5, 1.5, 2.0],
    "deep_advanced_pawn":   [0.5, 1.5, 2.0],
    "bishop_pair":          [0.5, 1.5, 2.0],
    "connected_passer":     [0.5, 1.5, 2.0],
    "protected_passer":     [0.5, 1.5, 2.0],
    "blockaded_passer":     [0.5, 1.5, 2.0],
    # --- rook activity ---
    "rook_open_file":       [0.5, 1.5, 2.0],
    "rook_semi_open_file":  [0.5, 1.5, 2.0],
    "heavy_seventh_rank":   [0.5, 1.5, 2.0],
    "rook_behind_passer":   [0.5, 1.5, 2.0],
    # --- endgame ---
    "endgame_king_activity": [0.5, 1.5, 2.0],
}

RESULT_RE = re.compile(r"=\s*([\d.]+)%")
ELO_RE = re.compile(r"Elo diff ~\s*([+-]?\d+)")
SPRT_RE = re.compile(r"->\s*(H0[^\n]*|H1[^\n]*|inconclusive)")


def run_ab(spec: str, depth: int, games: int, jobs: int, sprt: bool) -> dict:
    cmd = [str(CREF), "selfplay", "--games", str(games), "--depth", str(depth),
           "--jobs", str(jobs), "--weights-a", spec, "--label", spec or "baseline"]
    if sprt:
        cmd.append("--sprt")
    out = subprocess.run(cmd, capture_output=True, text=True).stdout
    rate = float(RESULT_RE.search(out).group(1)) if RESULT_RE.search(out) else 50.0
    elo = int(ELO_RE.search(out).group(1)) if ELO_RE.search(out) else 0
    sprt_v = SPRT_RE.search(out).group(1).strip() if SPRT_RE.search(out) else "n/a"
    return {"rate": rate, "elo": elo, "sprt": sprt_v}


def candidates(only: list[str] | None):
    for w, mults in SWEEP.items():
        if only and w not in only:
            continue
        base = BASELINE[w]
        for m in mults:
            val = round(base * m)
            if val == base:
                continue
            yield w, m, val


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--screen-depth", type=int, default=3)
    p.add_argument("--screen-games", type=int, default=120)
    p.add_argument("--confirm-depth", type=int, default=4)
    p.add_argument("--confirm-games", type=int, default=160)
    p.add_argument("--promote", type=float, default=52.0, help="screen rate %% to promote to confirm")
    p.add_argument("--jobs", type=int, default=10)
    p.add_argument("--only", default=None, help="comma list of weight names to sweep")
    p.add_argument("--json", type=Path, default=ROOT / "build" / "native_tune.json")
    args = p.parse_args(argv)

    if not CREF.exists():
        print("build native/cref first (make -C native)", file=sys.stderr)
        return 2
    only = args.only.split(",") if args.only else None
    cand = list(candidates(only))
    print(f"# tuner: {len(cand)} candidates | screen d{args.screen_depth}/{args.screen_games}g "
          f"-> confirm d{args.confirm_depth}/{args.confirm_games}g (promote>={args.promote}%)\n")

    screened = []
    for i, (w, m, val) in enumerate(cand, 1):
        spec = f"{w}={val}"
        r = run_ab(spec, args.screen_depth, args.screen_games, args.jobs, sprt=False)
        flag = "->confirm" if r["rate"] >= args.promote else ""
        print(f"[screen {i:>2}/{len(cand)}] {spec:<28} d{args.screen_depth} {r['rate']:5.1f}% "
              f"({r['elo']:+d} Elo) {flag}", flush=True)
        screened.append({"weight": w, "mult": m, "value": val, "spec": spec, "screen": r})

    promoted = [s for s in screened if s["screen"]["rate"] >= args.promote]
    print(f"\n# {len(promoted)} promoted to d{args.confirm_depth} confirm\n")
    for i, s in enumerate(promoted, 1):
        r = run_ab(s["spec"], args.confirm_depth, args.confirm_games, args.jobs, sprt=True)
        s["confirm"] = r
        print(f"[confirm {i:>2}/{len(promoted)}] {s['spec']:<28} d{args.confirm_depth} {r['rate']:5.1f}% "
              f"({r['elo']:+d} Elo) SPRT:{r['sprt']}", flush=True)

    winners = sorted([s for s in promoted if s.get("confirm", {}).get("rate", 0) > 50.0],
                     key=lambda s: s["confirm"]["rate"], reverse=True)
    print("\n=== d4-CONFIRMED WINNERS (ranked) ===")
    if not winners:
        print("  (none beat baseline at the confirm depth)")
    for s in winners:
        c = s["confirm"]
        print(f"  {s['spec']:<28} {c['rate']:5.1f}% {c['elo']:+d} Elo  SPRT:{c['sprt']}")

    stacked = ",".join(s["spec"] for s in winners)
    if stacked:
        print(f"\n# stacked candidate (combine all winners), confirm with:")
        print(f"  native/cref selfplay --games 240 --depth 4 --jobs {args.jobs} --sprt --weights-a \"{stacked}\"")

    args.json.write_text(json.dumps({"screened": screened, "winners": winners, "stacked": stacked}, indent=2))
    print(f"\nwrote {args.json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
