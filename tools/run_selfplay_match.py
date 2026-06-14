#!/usr/bin/env python3
"""Fast engine-vs-engine self-play A/B harness for eval tuning.

The Stockfish ladder is the final judge of strength but is too slow (~40 min on
beast) to iterate eval changes against. This plays a candidate engine binary
(A) against a baseline binary (B) head-to-head over N games from a set of
opening FENs, both colors, in parallel. Because both sides search at the same
fixed strength, the only variable is the eval, so the score isolates whether a
change actually wins games -- the validator the project insists on (GAMES, not
the tactical corpus).

Typical loop:
    make engine-build                      # build candidate -> build/engine_harness.prg
    cp build/engine_harness.prg /tmp/baseline.prg
    cp build/engine_harness.sym /tmp/baseline.sym
    # ... edit eval, rebuild ...
    python3 tools/run_selfplay_match.py \
        --engine-b-prg /tmp/baseline.prg --engine-b-sym /tmp/baseline.sym \
        --games 80 --jobs 8

A score >55% (lower Wilson bound > 50%) means A is the stronger eval; promote it
and re-confirm on the ladder.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from concurrent.futures import ProcessPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import chess  # noqa: E402

from run_stockfish_strength import DIFFICULTY, c64_encoded_move_to_uci, fen_to_c64  # noqa: E402
from sim6502_headless_runner import Sim6502HeadlessRunner, Sim6502BridgeError, repo_root_from_script  # noqa: E402

# Centipawn material values for max-plies adjudication (pawn=100).
_MATERIAL = {chess.PAWN: 100, chess.KNIGHT: 320, chess.BISHOP: 330, chess.ROOK: 500, chess.QUEEN: 900}


@dataclass
class GameOutcome:
    index: int
    a_color: str          # "white" or "black" -- which color engine A played
    result: str           # "1-0", "0-1", "1/2-1/2"
    a_score: float        # from A's perspective: 1.0 win, 0.5 draw, 0.0 loss
    plies: int
    termination: str


def material_cp(board: chess.Board) -> int:
    """White-POV material balance in centipawns."""
    total = 0
    for piece_type, value in _MATERIAL.items():
        total += value * len(board.pieces(piece_type, chess.WHITE))
        total -= value * len(board.pieces(piece_type, chess.BLACK))
    return total


def play_one_game(args_dict: dict) -> GameOutcome:
    repo_root = Path(args_dict["repo_root"])
    idx = args_dict["index"]
    start_fen = args_dict["start_fen"]
    a_color = args_dict["a_color"]          # color engine A plays this game
    difficulty = args_dict["difficulty"]
    difficulty_a = args_dict.get("difficulty_a") or difficulty
    difficulty_b = args_dict.get("difficulty_b") or difficulty
    timeout_cycles = args_dict["timeout_cycles"]
    max_plies = args_dict["max_plies"]
    adj_cp = args_dict["adjudicate_win_cp"]
    adj_streak = args_dict["adjudicate_streak"]

    runner_a = Sim6502HeadlessRunner(
        repo_root=repo_root,
        program_path=Path(args_dict["a_prg"]),
        symbols_path=Path(args_dict["a_sym"]),
    )
    runner_b = Sim6502HeadlessRunner(
        repo_root=repo_root,
        program_path=Path(args_dict["b_prg"]),
        symbols_path=Path(args_dict["b_sym"]),
    )

    board = chess.Board(start_fen)
    termination = "maxplies"
    decisive_streak = 0  # consecutive plies one side has held a >= adj_cp material lead
    try:
        with runner_a, runner_b:
            while not board.is_game_over(claim_draw=True) and board.fullmove_number * 2 < max_plies + 4:
                if board.ply() >= max_plies:
                    break
                white_to_move = board.turn == chess.WHITE
                a_is_white = a_color == "white"
                use_a = white_to_move == a_is_white
                runner = runner_a if use_a else runner_b
                side_difficulty = difficulty_a if use_a else difficulty_b
                resp = runner.best_move(fen_to_c64(board.fen()), DIFFICULTY[side_difficulty], timeout_cycles)
                uci = c64_encoded_move_to_uci(board.fen(), int(resp["encoded"]))
                move = None
                if uci is not None:
                    try:
                        move = chess.Move.from_uci(uci)
                    except ValueError:
                        move = None
                if move is None or move not in board.legal_moves:
                    # Engine produced no legal move -> it loses this game.
                    loser_white = white_to_move
                    termination = "illegal-or-no-move"
                    result = "0-1" if loser_white else "1-0"
                    return _outcome(idx, a_color, result, board.ply(), termination)
                board.push(move)

                # Early material adjudication. At depth-6 (LEVEL_BEAST) every move
                # costs billions of cycles, so grinding a decided game to max_plies
                # is the dominant wall-time cost. Once one side has held a decisive
                # material lead for adj_streak consecutive plies, call it. Both
                # engines share the adjudicator so the verdict is unbiased; disable
                # with --adjudicate-streak 0.
                if adj_streak > 0:
                    bal = material_cp(board)
                    if bal >= adj_cp or bal <= -adj_cp:
                        decisive_streak += 1
                        if decisive_streak >= adj_streak:
                            result = "1-0" if bal >= adj_cp else "0-1"
                            return _outcome(idx, a_color, result, board.ply(), "adjudicated-early")
                    else:
                        decisive_streak = 0
    except Sim6502BridgeError as exc:
        # Treat a bridge failure as a no-result draw rather than crashing the pool.
        return GameOutcome(idx, a_color, "1/2-1/2", 0.5, board.ply(), f"bridge-error:{exc}"[:60])

    if board.is_game_over(claim_draw=True):
        result = board.result(claim_draw=True)
        termination = board.outcome(claim_draw=True).termination.name.lower() if board.outcome(claim_draw=True) else "gameover"
    else:
        # Max plies reached -> adjudicate on material.
        bal = material_cp(board)
        if bal >= adj_cp:
            result, termination = "1-0", "adjudicated-material"
        elif bal <= -adj_cp:
            result, termination = "0-1", "adjudicated-material"
        else:
            result, termination = "1/2-1/2", "adjudicated-draw"

    return _outcome(idx, a_color, result, board.ply(), termination)


def _outcome(idx: int, a_color: str, result: str, plies: int, termination: str) -> GameOutcome:
    if result == "1/2-1/2":
        a_score = 0.5
    elif (result == "1-0") == (a_color == "white"):
        a_score = 1.0
    else:
        a_score = 0.0
    return GameOutcome(idx, a_color, result, a_score, plies, termination)


def wilson(score_sum: float, n: int, z: float = 1.96) -> tuple[float, float]:
    if n == 0:
        return (0.0, 1.0)
    p = score_sum / n
    denom = 1 + z * z / n
    center = (p + z * z / (2 * n)) / denom
    margin = (z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))) / denom
    return (max(0.0, center - margin), min(1.0, center + margin))


def elo_diff(rate: float) -> float | None:
    if rate <= 0.0 or rate >= 1.0:
        return None
    return -400.0 * math.log10(1.0 / rate - 1.0)


def _expected_score(elo: float) -> float:
    return 1.0 / (1.0 + 10.0 ** (-elo / 400.0))


def sprt_llr(scores: list[float], elo1: float) -> float:
    """Generalized SPRT log-likelihood ratio for H0: elo=0 vs H1: elo=elo1.

    Normal-approximation GSPRT on the per-game score (0/0.5/1), with the
    variance estimated from the sample. >0 favours H1 (A is better), <0 favours
    H0. Used to stop a match the moment the evidence is decisive either way.
    """
    n = len(scores)
    if n < 2:
        return 0.0
    mu0, mu1 = 0.5, _expected_score(elo1)
    mean = sum(scores) / n
    var = sum((s - mean) ** 2 for s in scores) / n
    # Floor the variance well above zero: an all-draws (zero-variance) start
    # must not blow the LLR up to +/-millions. 0.05 is a realistic minimum for a
    # game-score distribution and keeps the test stable on drawish samples.
    var = max(var, 0.05)
    total = sum(scores)
    return (mu1 - mu0) / var * (total - n * (mu0 + mu1) / 2.0)


def load_start_fens(path: Path) -> list[str]:
    return [ln.strip() for ln in path.read_text().splitlines() if ln.strip() and not ln.startswith("#")]


def main(argv: list[str]) -> int:
    repo_root = repo_root_from_script()
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--engine-a-prg", type=Path, default=repo_root / "build" / "engine_harness.prg")
    p.add_argument("--engine-a-sym", type=Path, default=repo_root / "build" / "engine_harness.sym")
    p.add_argument("--engine-b-prg", type=Path, default=repo_root / "build" / "engine_harness.prg")
    p.add_argument("--engine-b-sym", type=Path, default=repo_root / "build" / "engine_harness.sym")
    p.add_argument("--games", type=int, default=40, help="total games (rounded up to an even number of color-balanced pairs)")
    p.add_argument("--difficulty", default="hard", choices=sorted(DIFFICULTY))
    p.add_argument("--difficulty-a", default=None, choices=sorted(DIFFICULTY),
                   help="override search depth for engine A only (e.g. beast vs hard to test whether depth -> strength)")
    p.add_argument("--difficulty-b", default=None, choices=sorted(DIFFICULTY))
    p.add_argument("--c64-timeout", type=int, default=80_000_000, help="per-move cycle cap (committed-best returned on overrun)")
    p.add_argument("--max-plies", type=int, default=160)
    p.add_argument("--adjudicate-win-cp", type=int, default=300)
    p.add_argument("--adjudicate-streak", type=int, default=6,
                   help="adjudicate a win after this many consecutive plies of a >= win-cp material lead (0 disables); cuts decided games short, key for depth-6 wall time")
    p.add_argument("--start-fen-file", type=Path, default=repo_root / "tools" / "stockfish_opening_fens.txt")
    p.add_argument("--jobs", type=int, default=6)
    p.add_argument("--sprt", action="store_true",
                   help="stop early when the result is decisive (GSPRT, H0: elo=0 vs H1: elo=sprt-elo1)")
    p.add_argument("--sprt-elo1", type=float, default=30.0,
                   help="H1 Elo threshold for SPRT (the smallest gain worth keeping; bigger -> decides faster but only catches bigger effects)")
    p.add_argument("--sprt-alpha", type=float, default=0.05, help="SPRT alpha=beta error rate")
    p.add_argument("--sprt-min", type=int, default=16, help="minimum games before SPRT can stop")
    p.add_argument("--json", type=Path, default=None)
    p.add_argument("--label", default="A=candidate vs B=baseline")
    args = p.parse_args(argv)

    fens = load_start_fens(args.start_fen_file)
    if not fens:
        print("No start FENs.", file=sys.stderr)
        return 2

    # Build the schedule: color-balanced pairs over the FEN set.
    pairs = max(1, args.games // 2)
    tasks = []
    for i in range(pairs):
        fen = fens[i % len(fens)]
        for a_color in ("white", "black"):
            tasks.append({
                "repo_root": str(repo_root),
                "index": len(tasks),
                "start_fen": fen,
                "a_color": a_color,
                "difficulty": args.difficulty,
                "difficulty_a": args.difficulty_a,
                "difficulty_b": args.difficulty_b,
                "timeout_cycles": args.c64_timeout,
                "max_plies": args.max_plies,
                "adjudicate_win_cp": args.adjudicate_win_cp,
                "adjudicate_streak": args.adjudicate_streak,
                "a_prg": str(args.engine_a_prg), "a_sym": str(args.engine_a_sym),
                "b_prg": str(args.engine_b_prg), "b_sym": str(args.engine_b_sym),
            })

    sprt_bound = math.log((1 - args.sprt_alpha) / args.sprt_alpha) if args.sprt else None
    sprt_result = None
    print(f"{args.label}: {len(tasks)} games, difficulty={args.difficulty}, "
          f"timeout={args.c64_timeout:,} cyc, jobs={args.jobs}"
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
                  f"plies={o.plies:3} | A {score:.1f}/{done}{llr_str}")
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
            "sprt": sprt_result, "difficulty": args.difficulty, "timeout_cycles": args.c64_timeout,
            "outcomes": [vars(o) for o in sorted(outcomes, key=lambda x: x.index)],
        }, indent=2))
        print(f"wrote {args.json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
