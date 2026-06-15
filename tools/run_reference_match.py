#!/usr/bin/env python3
"""Reference-vs-reference self-play A/B — native-speed eval iteration (Tier 3).

Same A/B methodology as `run_selfplay_match.py` (color-balanced pairs, material
adjudication, SPRT early-stop) but both sides are the in-process Python reference
engine (`reference_engine.Searcher` + the bit-exact `texel_eval` oracle) instead
of two emulated 6502 binaries. No emulator, no bridge -> a game is seconds and an
A/B is minutes, not the ~1 hr the 6502 loop costs. See docs/fast-iteration-plan.md
(Tier 3).

The eval is the variable. Each side may carry a JSON of eval-weight OVERRIDES
(`{"PINNED_QUEEN_PENALTY": 300, ...}`) applied to the `texel_eval` module globals
before that side searches; an empty override set is the current/baseline eval. The
search is identical for both sides (representative, not bit-exact), so the score
isolates the eval change -- the same contract as the 6502 harness, run fast.

Loop fit: oracle MSE (seconds) -> THIS reference A/B (minutes) -> 6502 d3+SPRT
(minutes) -> 6502 d6 confirm (rare). Winners are re-confirmed on the 6502; the
reference is the iteration surface, the 6502 is the ship target.

Example -- does halving the pinned-queen penalty win games?
    echo '{"PINNED_QUEEN_PENALTY": 225}' > /tmp/wa.json
    python3 tools/run_reference_match.py --weights-a /tmp/wa.json \\
        --games 200 --depth 4 --sprt --jobs 8
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import chess  # noqa: E402

import texel_eval as te  # noqa: E402
from reference_engine import best_move  # noqa: E402
# Reuse the proven A/B statistics + adjudication from the 6502 harness verbatim.
from run_selfplay_match import (  # noqa: E402
    GameOutcome, material_cp, wilson, elo_diff, sprt_llr, _outcome,
)


# Pristine snapshot of every weight global, captured at import (before any
# override). Each worker process imports fresh, so this is the baseline eval.
_WEIGHT_NAMES = [n for n, v in vars(te).items() if n.isupper() and isinstance(v, (int, list))]
_BASELINE = {n: (list(getattr(te, n)) if isinstance(getattr(te, n), list) else getattr(te, n))
             for n in _WEIGHT_NAMES}


def apply_eval_overrides(overrides: dict) -> None:
    """Reset texel_eval to baseline, apply this side's overrides, rebuild tables.

    CRITICAL: the two sides alternate in one process, so we must RESTORE the
    pristine baseline first -- otherwise the previous side's override leaks into
    this one (an A override of QUEEN_VALUE would silently persist into B's move,
    making both sides identical -> a false 50%).

    The scalar weights (PINNED_QUEEN_PENALTY, ...) feed precomputed type-indexed
    tables (PINNED_PIECE_PENALTY, ...) that the eval reads, so after applying the
    scalar overrides we recompute every derived table. Overriding a table
    directly is also supported (the override loop runs after the reset).
    """
    for n, v in _BASELINE.items():
        setattr(te, n, list(v) if isinstance(v, list) else v)
    for k, v in overrides.items():
        setattr(te, k, v)
    te.PIECE_VALUE_TBL = [0, te.PAWN_VALUE, te.KNIGHT_VALUE, te.BISHOP_VALUE,
                          te.ROOK_VALUE, te.QUEEN_VALUE, te.KING_VALUE]
    te.PAWN_ATTACK_PENALTY = [0, 0, te.PAWN_ATTACK_MINOR_PENALTY, te.PAWN_ATTACK_MINOR_PENALTY,
                              te.PAWN_ATTACK_ROOK_PENALTY, te.PAWN_ATTACK_QUEEN_PENALTY, 0]
    te.QUEEN_ATTACK_PENALTY = [0, 0, te.QUEEN_ATTACK_MINOR_PENALTY, te.QUEEN_ATTACK_MINOR_PENALTY, 0, 0, 0]
    te.MINOR_ATTACK_PENALTY = [0, 0, 0, 0, te.MINOR_ATTACK_ROOK_PENALTY, te.MINOR_ATTACK_QUEEN_PENALTY, 0]
    te.PINNED_PIECE_PENALTY = [0, te.PINNED_PAWN_PENALTY, te.PINNED_MINOR_PENALTY, te.PINNED_MINOR_PENALTY,
                               te.PINNED_ROOK_PENALTY, te.PINNED_QUEEN_PENALTY, 0]


def play_one_game(args_dict: dict) -> GameOutcome:
    idx = args_dict["index"]
    board = chess.Board(args_dict["start_fen"])
    a_color = args_dict["a_color"]
    depth_a = args_dict["depth_a"]
    depth_b = args_dict["depth_b"]
    weights_a = args_dict["weights_a"]
    weights_b = args_dict["weights_b"]
    max_plies = args_dict["max_plies"]
    adj_cp = args_dict["adjudicate_win_cp"]
    adj_streak = args_dict["adjudicate_streak"]

    termination = "maxplies"
    decisive_streak = 0
    while not board.is_game_over(claim_draw=True) and board.ply() < max_plies:
        white_to_move = board.turn == chess.WHITE
        use_a = white_to_move == (a_color == "white")
        apply_eval_overrides(weights_a if use_a else weights_b)
        move, _ = best_move(board, depth_a if use_a else depth_b)
        if move is None or move not in board.legal_moves:
            # No legal move from a non-terminal position should not happen with
            # the reference search; treat as a loss for the side to move.
            result = "0-1" if white_to_move else "1-0"
            return _outcome(idx, a_color, result, board.ply(), "no-move")
        board.push(move)

        if adj_streak > 0:
            bal = material_cp(board)
            if bal >= adj_cp or bal <= -adj_cp:
                decisive_streak += 1
                if decisive_streak >= adj_streak:
                    result = "1-0" if bal >= adj_cp else "0-1"
                    return _outcome(idx, a_color, result, board.ply(), "adjudicated-early")
            else:
                decisive_streak = 0

    if board.is_game_over(claim_draw=True):
        result = board.result(claim_draw=True)
        oc = board.outcome(claim_draw=True)
        termination = oc.termination.name.lower() if oc else "gameover"
    else:
        bal = material_cp(board)
        if bal >= adj_cp:
            result, termination = "1-0", "adjudicated-material"
        elif bal <= -adj_cp:
            result, termination = "0-1", "adjudicated-material"
        else:
            result, termination = "1/2-1/2", "adjudicated-draw"

    return _outcome(idx, a_color, result, board.ply(), termination)


def load_start_fens(path: Path) -> list[str]:
    return [ln.strip() for ln in path.read_text().splitlines() if ln.strip() and not ln.startswith("#")]


def main(argv: list[str]) -> int:
    repo_root = Path(__file__).resolve().parent.parent
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--weights-a", type=Path, default=None, help="JSON of eval-weight overrides for engine A (default: baseline eval)")
    p.add_argument("--weights-b", type=Path, default=None, help="JSON of eval-weight overrides for engine B (default: baseline eval)")
    p.add_argument("--games", type=int, default=40, help="total games (rounded to color-balanced pairs)")
    p.add_argument("--depth", type=int, default=4, help="search depth for both sides")
    p.add_argument("--depth-a", type=int, default=None, help="override search depth for engine A only")
    p.add_argument("--depth-b", type=int, default=None, help="override search depth for engine B only")
    p.add_argument("--max-plies", type=int, default=160)
    p.add_argument("--adjudicate-win-cp", type=int, default=300)
    p.add_argument("--adjudicate-streak", type=int, default=6)
    p.add_argument("--start-fen-file", type=Path, default=repo_root / "tools" / "selfplay_openings.txt")
    p.add_argument("--jobs", type=int, default=6)
    p.add_argument("--sprt", action="store_true", help="GSPRT early-stop (H0: elo=0 vs H1: elo=sprt-elo1)")
    p.add_argument("--sprt-elo1", type=float, default=30.0)
    p.add_argument("--sprt-alpha", type=float, default=0.05)
    p.add_argument("--sprt-min", type=int, default=16)
    p.add_argument("--json", type=Path, default=None)
    p.add_argument("--label", default="A=candidate vs B=baseline (reference)")
    args = p.parse_args(argv)

    weights_a = json.loads(args.weights_a.read_text()) if args.weights_a else {}
    weights_b = json.loads(args.weights_b.read_text()) if args.weights_b else {}
    depth_a = args.depth_a if args.depth_a is not None else args.depth
    depth_b = args.depth_b if args.depth_b is not None else args.depth

    fens = load_start_fens(args.start_fen_file)
    if not fens:
        print("No start FENs.", file=sys.stderr)
        return 2

    pairs = max(1, args.games // 2)
    tasks = []
    for i in range(pairs):
        fen = fens[i % len(fens)]
        for a_color in ("white", "black"):
            tasks.append({
                "index": len(tasks), "start_fen": fen, "a_color": a_color,
                "depth_a": depth_a, "depth_b": depth_b,
                "weights_a": weights_a, "weights_b": weights_b,
                "max_plies": args.max_plies,
                "adjudicate_win_cp": args.adjudicate_win_cp,
                "adjudicate_streak": args.adjudicate_streak,
            })

    sprt_bound = math.log((1 - args.sprt_alpha) / args.sprt_alpha) if args.sprt else None
    sprt_result = None
    print(f"{args.label}: {len(tasks)} games, depth A={depth_a}/B={depth_b}, jobs={args.jobs}"
          + (f", SPRT[elo1={args.sprt_elo1}, a=b={args.sprt_alpha}, bound=±{sprt_bound:.2f}, min={args.sprt_min}]"
             if args.sprt else ""))
    outcomes: list[GameOutcome] = []
    done = 0
    with ProcessPoolExecutor(max_workers=args.jobs) as pool:
        futs = [pool.submit(play_one_game, t) for t in tasks]
        for fut in as_completed(futs):
            o = fut.result()
            outcomes.append(o)
            done += 1
            score = sum(x.a_score for x in outcomes)
            llr_str = ""
            if args.sprt and done >= args.sprt_min:
                llr = sprt_llr([x.a_score for x in outcomes], args.sprt_elo1)
                llr_str = f" LLR={llr:+.2f}"
                if llr >= sprt_bound:
                    sprt_result = f"H1 accepted: A is >= +{args.sprt_elo1} Elo (LLR {llr:+.2f})"
                elif llr <= -sprt_bound:
                    sprt_result = f"H0 accepted: A is NOT better (LLR {llr:+.2f})"
            print(f"  [{done}/{len(tasks)}] A({o.a_color[0]}) {o.result:7} {o.termination:22} "
                  f"plies={o.plies:3} | A {score:.1f}/{done}{llr_str}", flush=True)
            if sprt_result is not None:
                print(f"  *** SPRT stop after {done} games: {sprt_result} ***")
                for f in futs:
                    f.cancel()
                break

    n = len(outcomes)
    a_score = sum(o.a_score for o in outcomes)
    wins = sum(1 for o in outcomes if o.a_score == 1.0)
    draws = sum(1 for o in outcomes if o.a_score == 0.5)
    losses = sum(1 for o in outcomes if o.a_score == 0.0)
    rate = a_score / n if n else 0.0
    lo, hi = wilson(a_score, n)
    ed = elo_diff(rate)
    print("\n=== RESULT (engine A perspective) ===")
    print(f"A: +{wins} ={draws} -{losses}  score {a_score:.1f}/{n} = {100*rate:.1f}%")
    print(f"Wilson 95%: [{100*lo:.1f}%, {100*hi:.1f}%]   Elo diff ~ {ed:+.0f}" if ed is not None else
          f"Wilson 95%: [{100*lo:.1f}%, {100*hi:.1f}%]")
    verdict = ("A STRONGER (95%)" if lo > 0.5 else
               "B STRONGER (95%)" if hi < 0.5 else
               "inconclusive (need more games)")
    print(f"Verdict: {verdict}")
    if args.sprt:
        print(f"SPRT: {sprt_result or 'inconclusive (hit game cap before a decision)'}")

    if args.json:
        args.json.write_text(json.dumps({
            "label": args.label, "games": n, "a_wins": wins, "a_draws": draws, "a_losses": losses,
            "a_score": a_score, "rate": rate, "wilson95": [lo, hi], "elo_diff": ed,
            "sprt": sprt_result, "depth_a": depth_a, "depth_b": depth_b,
            "weights_a": weights_a, "weights_b": weights_b,
            "outcomes": [vars(o) for o in sorted(outcomes, key=lambda x: x.index)],
        }, indent=2))
        print(f"wrote {args.json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
