#!/usr/bin/env python3
"""Estimate C64 AI Elo by playing a limited-strength Stockfish ladder."""

from __future__ import annotations

import argparse
import json
import math
import os
import shutil
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import asdict, dataclass
from pathlib import Path

from run_stockfish_games import GameResult, play_game, side_schedule
from run_stockfish_strength import (
    C64_BACKENDS,
    DEFAULT_IMAGE,
    DEFAULT_PULL,
    DIFFICULTY,
    RUNNER_TARGETS,
    Stockfish,
    chess,
    create_sim6502_runner,
    require_chess,
    repo_root_from_script,
    runner_required_files,
    stockfish_identity_for_path,
)

STOCKFISH_UCI_ELO_MIN = 1320
STOCKFISH_UCI_ELO_MAX = 3190


@dataclass
class RatingSummary:
    stockfish_elo: int
    games: int
    c64_score: float
    score_rate: float
    point_score_rate: float
    elo_diff: float | None
    point_elo_diff: float
    estimated_c64_elo: float
    ci_low_rate: float
    ci_high_rate: float
    ci_low_elo: float | None
    ci_high_elo: float | None
    average_loss: float | None
    max_loss: int | None
    average_cycles: float | None
    failures: int
    terminations: dict[str, int]


@dataclass(frozen=True)
class ScheduledGame:
    stockfish_elo: int
    start_index: int
    start_fen: str
    c64_color: str
    game_number: int


@dataclass
class LadderWorkerResources:
    opponent: Stockfish
    analysis_engine: Stockfish
    sim6502_runner: object | None
    stockfish_elo: int | None = None

    def close(self) -> None:
        if self.sim6502_runner is not None:
            self.sim6502_runner.close()
        self.opponent.close()
        self.analysis_engine.close()


class LadderWorkerPool:
    """Thread-local Stockfish and sim6502 processes for parallel ladder games."""

    def __init__(self, args: argparse.Namespace, repo_root: Path) -> None:
        self.args = args
        self.repo_root = repo_root
        self._local = threading.local()
        self._lock = threading.Lock()
        self._workers: list[LadderWorkerResources] = []

    def get(self) -> LadderWorkerResources:
        worker = getattr(self._local, "worker", None)
        if worker is not None:
            return worker

        opponent = Stockfish(self.args.stockfish_path)
        analysis_engine = Stockfish(self.args.stockfish_path)
        sim6502_runner = None
        if self.args.c64_backend == "sim6502":
            sim6502_runner = create_sim6502_runner(self.repo_root, self.args.runner_target)
            sim6502_runner.start()

        worker = LadderWorkerResources(
            opponent=opponent,
            analysis_engine=analysis_engine,
            sim6502_runner=sim6502_runner,
        )
        self._local.worker = worker
        with self._lock:
            self._workers.append(worker)
        return worker

    def close(self) -> None:
        with self._lock:
            workers = list(self._workers)
            self._workers.clear()
        for worker in workers:
            worker.close()


def elo_diff_from_rate(rate: float) -> float | None:
    if rate <= 0.0 or rate >= 1.0:
        return None
    return -400.0 * math.log10((1.0 / rate) - 1.0)


def smoothed_score_rate(score: float, games: int) -> float:
    return (score + 0.5) / (games + 1.0)


def wilson_interval(score: float, games: int, z: float = 1.96) -> tuple[float, float]:
    if games <= 0:
        return 0.0, 1.0
    rate = score / games
    denom = 1.0 + (z * z / games)
    center = (rate + (z * z / (2.0 * games))) / denom
    margin = (
        z
        * math.sqrt((rate * (1.0 - rate) / games) + (z * z / (4.0 * games * games)))
        / denom
    )
    return max(0.0, center - margin), min(1.0, center + margin)


def finite_elo_at_rate(stockfish_elo: int, rate: float) -> float | None:
    diff = elo_diff_from_rate(rate)
    return None if diff is None else stockfish_elo + diff


def summarize_rating(stockfish_elo: int, results: list[GameResult]) -> RatingSummary:
    scores = [result.c64_score for result in results if result.c64_score is not None]
    games = len(scores)
    c64_score = sum(scores)
    score_rate = c64_score / games if games else 0.0
    point_rate = score_rate
    raw_diff = elo_diff_from_rate(score_rate)
    if raw_diff is None:
        point_rate = smoothed_score_rate(c64_score, games)
    point_diff = elo_diff_from_rate(point_rate)
    assert point_diff is not None

    losses = [result.c64_average_loss for result in results if result.c64_average_loss is not None]
    max_losses = [result.c64_max_loss for result in results if result.c64_max_loss is not None]
    cycles = [result.c64_total_cycles for result in results]
    failures = sum(
        1
        for result in results
        if "illegal" in result.termination
        or "no-move" in result.termination
        or "runner-error" in result.termination
    )
    terminations: dict[str, int] = {}
    for result in results:
        terminations[result.termination] = terminations.get(result.termination, 0) + 1

    ci_low_rate, ci_high_rate = wilson_interval(c64_score, games)
    return RatingSummary(
        stockfish_elo=stockfish_elo,
        games=games,
        c64_score=c64_score,
        score_rate=score_rate,
        point_score_rate=point_rate,
        elo_diff=raw_diff,
        point_elo_diff=point_diff,
        estimated_c64_elo=stockfish_elo + point_diff,
        ci_low_rate=ci_low_rate,
        ci_high_rate=ci_high_rate,
        ci_low_elo=finite_elo_at_rate(stockfish_elo, ci_low_rate),
        ci_high_elo=finite_elo_at_rate(stockfish_elo, ci_high_rate),
        average_loss=(sum(losses) / len(losses)) if losses else None,
        max_loss=max(max_losses) if max_losses else None,
        average_cycles=(sum(cycles) / len(cycles)) if cycles else None,
        failures=failures,
        terminations=terminations,
    )


def is_c64_loss(result: GameResult) -> bool:
    return result.c64_score == 0.0


def parse_rating_list(value: str) -> list[int]:
    ratings = []
    for part in value.split(","):
        part = part.strip()
        if not part:
            continue
        ratings.append(int(part))
    if not ratings:
        raise argparse.ArgumentTypeError("rating list cannot be empty")
    return ratings


def rating_values(args: argparse.Namespace) -> list[int]:
    if args.stockfish_elos:
        ratings = args.stockfish_elos
    else:
        if args.stockfish_elo_step <= 0:
            raise SystemExit("--stockfish-elo-step must be positive")
        if args.stockfish_elo_stop < args.stockfish_elo_start:
            raise SystemExit("--stockfish-elo-stop must be >= --stockfish-elo-start")
        ratings = list(range(args.stockfish_elo_start, args.stockfish_elo_stop + 1, args.stockfish_elo_step))

    invalid = [
        rating
        for rating in ratings
        if rating < STOCKFISH_UCI_ELO_MIN or rating > STOCKFISH_UCI_ELO_MAX
    ]
    if invalid:
        raise SystemExit(
            "Stockfish UCI_Elo anchors must be between "
            f"{STOCKFISH_UCI_ELO_MIN} and {STOCKFISH_UCI_ELO_MAX}: {invalid}"
        )
    return ratings


def start_fens(args: argparse.Namespace) -> list[str]:
    if not args.start_fen_file:
        return [args.start_fen]

    fens = []
    for line in args.start_fen_file.read_text(encoding="utf-8").splitlines():
        value = line.strip()
        if not value or value.startswith("#"):
            continue
        fens.append(value)
    if not fens:
        raise SystemExit(f"No FEN positions found in {args.start_fen_file}")
    return fens


def configure_limited_stockfish(stockfish: Stockfish, elo: int) -> None:
    stockfish.set_option("UCI_LimitStrength", "true")
    stockfish.set_option("UCI_Elo", str(elo))
    stockfish.is_ready()


def apply_shard(schedule: list[ScheduledGame], shard_index: int, shard_count: int) -> list[ScheduledGame]:
    if shard_count == 1:
        return schedule
    return [
        scheduled
        for scheduled in schedule
        if (scheduled.game_number - 1) % shard_count == shard_index
    ]


def scheduled_games_for_rating(
    *,
    stockfish_elo: int,
    starts: list[str],
    c64_side: str,
    games_per_side: int,
    first_game_number: int,
) -> list[ScheduledGame]:
    return [
        ScheduledGame(stockfish_elo, start_index, start_fen, c64_color, first_game_number + offset)
        for offset, (start_index, start_fen, c64_color) in enumerate(
            (
                (start_index, start_fen, c64_color)
                for start_index, start_fen in enumerate(starts, start=1)
                for c64_color in side_schedule(c64_side, games_per_side)
            )
        )
    ]


def choose_anchor(summaries: list[RatingSummary]) -> RatingSummary | None:
    if not summaries:
        return None
    return min(summaries, key=lambda item: (abs(item.score_rate - 0.5), item.failures, -item.games))


def ladder_status(summaries: list[RatingSummary]) -> str:
    if not summaries:
        return "no-results"
    rates = [summary.score_rate for summary in summaries]
    if all(rate < 0.5 for rate in rates):
        return "below-tested-range"
    if all(rate > 0.5 for rate in rates):
        return "above-tested-range"
    return "bracketed"


def fmt(value: float | None, digits: int = 0) -> str:
    if value is None:
        return "-"
    return f"{value:.{digits}f}"


def print_ladder_summary(
    summaries: list[RatingSummary],
    *,
    runner_target: str,
    c64_backend: str,
    difficulty: str,
    stockfish_depth: int,
    stockfish_movetime_ms: int | None,
    analysis_depth: int,
) -> None:
    anchor = choose_anchor(summaries)
    status = ladder_status(summaries)

    print(f"Elo ladder: {len(summaries)} rating point(s)")
    print(
        "  "
        f"runner={runner_target} c64_backend={c64_backend} difficulty={difficulty} "
        f"stockfish_depth={stockfish_depth} "
        f"stockfish_movetime_ms={stockfish_movetime_ms or '-'} "
        f"analysis_depth={analysis_depth}"
    )
    print("  elo   score      rate   diff   estimate   95pct-elo      avg-loss max-loss failures")
    for summary in summaries:
        raw_diff = "-" if summary.elo_diff is None else f"{summary.elo_diff:+.0f}"
        ci = (
            "-"
            if summary.ci_low_elo is None or summary.ci_high_elo is None
            else f"{summary.ci_low_elo:.0f}-{summary.ci_high_elo:.0f}"
        )
        print(
            f"  {summary.stockfish_elo:4d} "
            f"{summary.c64_score:5.1f}/{summary.games:<3d} "
            f"{summary.score_rate * 100.0:5.1f}% "
            f"{raw_diff:>6} "
            f"{summary.estimated_c64_elo:9.0f} "
            f"{ci:>12} "
            f"{fmt(summary.average_loss, 1):>8} "
            f"{fmt(summary.max_loss):>8} "
            f"{summary.failures:>8}"
        )

    if anchor:
        print(
            "  "
            f"best_estimate={anchor.estimated_c64_elo:.0f} "
            f"anchor={anchor.stockfish_elo} "
            f"score={anchor.c64_score:g}/{anchor.games} "
            f"status={status}"
        )


def write_json_payload(
    path: Path,
    *,
    args: argparse.Namespace,
    summaries: list[RatingSummary],
    all_games: list[dict[str, object]],
) -> None:
    anchor = choose_anchor(summaries)
    payload = {
        "generated_by": "tools/run_elo_ladder.py",
        "complete": False,
        "runner_target": args.runner_target,
        "c64_backend": args.c64_backend,
        "difficulty": args.difficulty,
        "stockfish_path": args.stockfish_path,
        "stockfish_identity": getattr(args, "stockfish_identity", "unknown"),
        "stockfish_depth": args.stockfish_depth,
        "stockfish_movetime_ms": args.stockfish_movetime_ms,
        "analysis_depth": args.analysis_depth,
        "analysis_multipv": args.analysis_multipv,
        "max_plies": args.max_plies,
        "adjudicate_max_plies": args.adjudicate_max_plies,
        "adjudicate_win_cp": args.adjudicate_win_cp,
        "shard_index": args.shard_index,
        "shard_count": args.shard_count,
        "stopped_early": getattr(args, "stopped_early", False),
        "status": ladder_status(summaries),
        "best_estimate": asdict(anchor) if anchor else None,
        "ratings": [asdict(summary) for summary in summaries],
        "games": sorted(all_games, key=lambda item: int(item["game"]["game"])),  # type: ignore[index]
    }
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def play_scheduled_game_with_worker(
    args: argparse.Namespace,
    pool: LadderWorkerPool,
    scheduled: ScheduledGame,
) -> tuple[GameResult, float]:
    """Run one ladder game on a thread-local persistent worker."""
    worker = pool.get()
    started = time.monotonic()
    if worker.stockfish_elo != scheduled.stockfish_elo:
        configure_limited_stockfish(worker.opponent, scheduled.stockfish_elo)
        worker.stockfish_elo = scheduled.stockfish_elo
    worker.opponent.new_game()
    worker.analysis_engine.new_game()
    result = play_game(
        stockfish=worker.opponent,
        analysis_stockfish=worker.analysis_engine,
        repo_root=pool.repo_root,
        image=args.sim6502_image,
        pull=args.sim6502_pull,
        runner_target=args.runner_target,
        c64_backend=args.c64_backend,
        sim6502_runner=worker.sim6502_runner,
        game_number=scheduled.game_number,
        start_fen=scheduled.start_fen,
        c64_color=scheduled.c64_color,
        difficulty=args.difficulty,
        stockfish_depth=args.stockfish_depth,
        stockfish_movetime_ms=args.stockfish_movetime_ms,
        analysis_depth=args.analysis_depth,
        analysis_multipv=args.analysis_multipv,
        max_plies=args.max_plies,
        c64_timeout=args.c64_timeout,
        c64_book=args.book == "on",
        adjudicate_max_plies=args.adjudicate_max_plies,
        adjudicate_win_cp=args.adjudicate_win_cp,
    )
    return result, time.monotonic() - started


def run_self_test() -> int:
    assert round(elo_diff_from_rate(0.75) or 0) == 191
    assert round(elo_diff_from_rate(0.25) or 0) == -191
    lo, hi = wilson_interval(1.0, 2)
    assert 0.09 < lo < 0.1
    assert 0.9 < hi < 0.91

    results = [
        GameResult(1, "white", "1-0", 1.0, "checkmate", 20, 10, 12.0, 30, 1000, [], ""),
        GameResult(2, "black", "1/2-1/2", 0.5, "adjudicated-draw", 20, 10, 20.0, 40, 2000, [], ""),
    ]
    summary = summarize_rating(1400, results)
    assert summary.c64_score == 1.5
    assert round(summary.estimated_c64_elo) == 1591
    assert summary.average_loss == 16.0
    assert parse_rating_list("1320, 1400") == [1320, 1400]
    built_schedule = scheduled_games_for_rating(
        stockfish_elo=1320,
        starts=["fen-a", "fen-b"],
        c64_side="both",
        games_per_side=1,
        first_game_number=5,
    )
    assert [game.game_number for game in built_schedule] == [5, 6, 7, 8]
    assert [game.start_index for game in built_schedule] == [1, 1, 2, 2]
    schedule = [
        ScheduledGame(1320, 1, "fen", "white", 1),
        ScheduledGame(1320, 1, "fen", "black", 2),
        ScheduledGame(1320, 2, "fen", "white", 3),
        ScheduledGame(1320, 2, "fen", "black", 4),
    ]
    assert [game.game_number for game in apply_shard(schedule, 0, 2)] == [1, 3]
    assert [game.game_number for game in apply_shard(schedule, 1, 2)] == [2, 4]
    assert not is_c64_loss(results[0])
    assert is_c64_loss(GameResult(3, "black", "1-0", 0.0, "adjudicated-loss", 20, 10, 50.0, 200, 3000, [], ""))
    print("Self-test passed.")
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Estimate C64 AI Elo against Stockfish UCI_Elo anchors.")
    parser.add_argument("--stockfish-path", default=os.environ.get("STOCKFISH_PATH") or shutil.which("stockfish"))
    parser.add_argument("--repo-root", type=Path, default=repo_root_from_script())
    parser.add_argument("--sim6502-image", default=DEFAULT_IMAGE)
    parser.add_argument("--sim6502-pull", choices=["always", "missing", "never"], default=DEFAULT_PULL)
    parser.add_argument("--runner-target", choices=sorted(RUNNER_TARGETS), default="headless")
    parser.add_argument("--c64-backend", choices=C64_BACKENDS, default="sim6502")
    parser.add_argument("--difficulty", choices=sorted(DIFFICULTY), default="hard")
    parser.add_argument("--stockfish-elo-start", type=int, default=1320)
    parser.add_argument("--stockfish-elo-stop", type=int, default=1720)
    parser.add_argument("--stockfish-elo-step", type=int, default=200)
    parser.add_argument("--stockfish-elos", type=parse_rating_list, help="Comma-separated Stockfish UCI_Elo anchors.")
    parser.add_argument("--stockfish-depth", type=int, default=6)
    parser.add_argument("--stockfish-movetime-ms", type=int, default=None, help="Use go movetime for Stockfish opponent moves instead of depth-only play.")
    parser.add_argument("--analysis-depth", type=int, default=6)
    parser.add_argument("--analysis-multipv", type=int, default=3)
    parser.add_argument("--c64-side", choices=["white", "black", "both"], default="both")
    parser.add_argument("--games-per-side", type=int, default=1)
    parser.add_argument("--jobs", type=int, default=1, help="Run independent ladder games in parallel.")
    parser.add_argument("--shard-index", type=int, default=0, help="Run only this zero-based game shard.")
    parser.add_argument("--shard-count", type=int, default=1, help="Split scheduled games across this many shards.")
    parser.add_argument("--start-fen", default=chess.STARTING_FEN if chess else None)
    parser.add_argument("--start-fen-file", type=Path, help="Read starting FENs, one per line, ignoring blank lines and # comments.")
    parser.add_argument("--max-plies", type=int, default=80)
    parser.add_argument("--c64-timeout", type=int, default=20_000_000_000)
    parser.add_argument(
        "--adjudicate-max-plies",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Use full-strength Stockfish eval to score games that hit --max-plies.",
    )
    parser.add_argument("--adjudicate-win-cp", type=int, default=500)
    parser.add_argument("--book", choices=["on", "off"], default="off", help="Use the C64 opening book with --runner-target=app.")
    parser.add_argument("--json", type=Path, help="Write machine-readable ladder and game results.")
    parser.add_argument("--pgn", type=Path, help="Write PGN for all games.")
    parser.add_argument(
        "--fail-on-c64-loss",
        action="store_true",
        help="Stop candidate runs and return nonzero as soon as a completed game is a C64 loss.",
    )
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        return run_self_test()
    if args.jobs < 1:
        raise SystemExit("--jobs must be >= 1")
    if args.shard_count < 1:
        raise SystemExit("--shard-count must be >= 1")
    if args.shard_index < 0 or args.shard_index >= args.shard_count:
        raise SystemExit("--shard-index must be between 0 and --shard-count - 1")

    require_chess()
    if not args.stockfish_path:
        print("Could not find Stockfish. Set STOCKFISH_PATH or pass --stockfish-path.", file=sys.stderr)
        return 2
    args.stockfish_identity = stockfish_identity_for_path(args.stockfish_path)

    repo_root = args.repo_root.resolve()
    for required_name in runner_required_files(args.runner_target):
        required = repo_root / required_name
        if not required.exists():
            target = "make engine-build" if args.runner_target == "headless" else "make build"
            print(f"Missing required file: {required}. Run `{target}` first.", file=sys.stderr)
            return 2

    ratings = rating_values(args)
    starts = start_fens(args)
    all_games: list[dict[str, object]] = []
    summaries: list[RatingSummary] = []
    pgns: list[tuple[int, str]] = []
    game_number = 1
    args.stopped_early = False
    saw_c64_loss = False

    opponent = None
    analysis_engine = None
    sim6502_runner = None
    worker_pool = None
    executor = None
    try:
        if args.jobs > 1:
            worker_pool = LadderWorkerPool(args, repo_root)
            executor = ThreadPoolExecutor(max_workers=args.jobs)
        if args.jobs == 1:
            opponent = Stockfish(args.stockfish_path)
            analysis_engine = Stockfish(args.stockfish_path)
        if args.jobs == 1 and args.c64_backend == "sim6502":
            sim6502_runner = create_sim6502_runner(repo_root, args.runner_target)
            sim6502_runner.start()
        if args.jobs > 1:
            assert worker_pool is not None
            assert executor is not None
            full_schedule: list[ScheduledGame] = []
            for stockfish_elo in ratings:
                rating_schedule = scheduled_games_for_rating(
                    stockfish_elo=stockfish_elo,
                    starts=starts,
                    c64_side=args.c64_side,
                    games_per_side=args.games_per_side,
                    first_game_number=game_number,
                )
                full_schedule.extend(rating_schedule)
                game_number += len(rating_schedule)

            schedule = apply_shard(full_schedule, args.shard_index, args.shard_count)
            if args.shard_count > 1:
                print(
                    f"shard={args.shard_index}/{args.shard_count} games={len(schedule)}/{len(full_schedule)}",
                    flush=True,
                )

            results_by_elo: dict[int, list[GameResult]] = {stockfish_elo: [] for stockfish_elo in ratings}
            futures = {
                executor.submit(play_scheduled_game_with_worker, args, worker_pool, scheduled): scheduled
                for scheduled in schedule
            }
            for future in as_completed(futures):
                scheduled = futures[future]
                result, elapsed = future.result()
                if is_c64_loss(result):
                    saw_c64_loss = True
                results_by_elo[scheduled.stockfish_elo].append(result)
                all_games.append(
                    {
                        "stockfish_elo": scheduled.stockfish_elo,
                        "start_index": scheduled.start_index,
                        "game": asdict(result),
                    }
                )
                pgns.append((result.game, result.pgn))
                print(
                    f"game={result.game:03d} elo={scheduled.stockfish_elo} c64={scheduled.c64_color:5} "
                    f"start={scheduled.start_index:02d} result={result.result:7} term={result.termination} "
                    f"elapsed={elapsed:.1f}s",
                    flush=True,
                )
                if args.json:
                    write_json_payload(args.json, args=args, summaries=summaries, all_games=all_games)
                if args.fail_on_c64_loss and is_c64_loss(result):
                    args.stopped_early = True
                    for pending in futures:
                        if pending is not future:
                            pending.cancel()
                    break

            summaries = [
                summarize_rating(stockfish_elo, sorted(results_by_elo[stockfish_elo], key=lambda result: result.game))
                for stockfish_elo in ratings
            ]
            if args.json:
                write_json_payload(args.json, args=args, summaries=summaries, all_games=all_games)
        else:
            for stockfish_elo in ratings:
                rating_results: list[GameResult] = []
                schedule = scheduled_games_for_rating(
                    stockfish_elo=stockfish_elo,
                    starts=starts,
                    c64_side=args.c64_side,
                    games_per_side=args.games_per_side,
                    first_game_number=game_number,
                )
                full_schedule_count = len(schedule)
                schedule = apply_shard(schedule, args.shard_index, args.shard_count)
                if args.shard_count > 1:
                    print(
                        f"elo={stockfish_elo} shard={args.shard_index}/{args.shard_count} "
                        f"games={len(schedule)}/{full_schedule_count}",
                        flush=True,
                    )
                assert opponent is not None
                assert analysis_engine is not None
                configure_limited_stockfish(opponent, stockfish_elo)
                for scheduled in schedule:
                    started = time.monotonic()
                    opponent.new_game()
                    analysis_engine.new_game()
                    result = play_game(
                        stockfish=opponent,
                        analysis_stockfish=analysis_engine,
                        repo_root=repo_root,
                        image=args.sim6502_image,
                        pull=args.sim6502_pull,
                        runner_target=args.runner_target,
                        c64_backend=args.c64_backend,
                        sim6502_runner=sim6502_runner,
                        game_number=scheduled.game_number,
                        start_fen=scheduled.start_fen,
                        c64_color=scheduled.c64_color,
                        difficulty=args.difficulty,
                        stockfish_depth=args.stockfish_depth,
                        stockfish_movetime_ms=args.stockfish_movetime_ms,
                        analysis_depth=args.analysis_depth,
                        analysis_multipv=args.analysis_multipv,
                        max_plies=args.max_plies,
                        c64_timeout=args.c64_timeout,
                        c64_book=args.book == "on",
                        adjudicate_max_plies=args.adjudicate_max_plies,
                        adjudicate_win_cp=args.adjudicate_win_cp,
                    )
                    if is_c64_loss(result):
                        saw_c64_loss = True
                    rating_results.append(result)
                    all_games.append(
                        {
                            "stockfish_elo": stockfish_elo,
                            "start_index": scheduled.start_index,
                            "game": asdict(result),
                        }
                    )
                    pgns.append((result.game, result.pgn))
                    print(
                        f"game={result.game:03d} elo={stockfish_elo} c64={scheduled.c64_color:5} "
                        f"start={scheduled.start_index:02d} result={result.result:7} term={result.termination} "
                        f"elapsed={time.monotonic() - started:.1f}s",
                        flush=True,
                    )
                    if args.json:
                        write_json_payload(args.json, args=args, summaries=summaries, all_games=all_games)
                    if args.fail_on_c64_loss and is_c64_loss(result):
                        args.stopped_early = True
                        break
                game_number += full_schedule_count

                summaries.append(summarize_rating(stockfish_elo, rating_results))
                if args.json:
                    write_json_payload(args.json, args=args, summaries=summaries, all_games=all_games)
                if args.stopped_early:
                    break
    finally:
        if executor is not None:
            executor.shutdown(wait=True)
        if worker_pool is not None:
            worker_pool.close()
        if sim6502_runner is not None:
            sim6502_runner.close()
        if opponent is not None:
            opponent.close()
        if analysis_engine is not None:
            analysis_engine.close()

    print_ladder_summary(
        summaries,
        runner_target=args.runner_target,
        c64_backend=args.c64_backend,
        difficulty=args.difficulty,
        stockfish_depth=args.stockfish_depth,
        stockfish_movetime_ms=args.stockfish_movetime_ms,
        analysis_depth=args.analysis_depth,
    )

    if args.json:
        anchor = choose_anchor(summaries)
        payload = {
            "generated_by": "tools/run_elo_ladder.py",
            "complete": True,
            "runner_target": args.runner_target,
            "c64_backend": args.c64_backend,
            "difficulty": args.difficulty,
            "stockfish_path": args.stockfish_path,
            "stockfish_identity": args.stockfish_identity,
            "stockfish_depth": args.stockfish_depth,
            "stockfish_movetime_ms": args.stockfish_movetime_ms,
            "analysis_depth": args.analysis_depth,
            "analysis_multipv": args.analysis_multipv,
            "max_plies": args.max_plies,
            "adjudicate_max_plies": args.adjudicate_max_plies,
            "adjudicate_win_cp": args.adjudicate_win_cp,
            "shard_index": args.shard_index,
            "shard_count": args.shard_count,
            "stopped_early": args.stopped_early,
            "status": ladder_status(summaries),
            "best_estimate": asdict(anchor) if anchor else None,
            "ratings": [asdict(summary) for summary in summaries],
            "games": sorted(all_games, key=lambda item: int(item["game"]["game"])),  # type: ignore[index]
        }
        args.json.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if args.pgn:
        args.pgn.write_text("\n\n".join(pgn for _, pgn in sorted(pgns)) + "\n", encoding="utf-8")

    if args.fail_on_c64_loss and saw_c64_loss:
        return 1
    return 1 if any(summary.failures for summary in summaries) else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
