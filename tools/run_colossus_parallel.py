#!/usr/bin/env python3
"""Run many independent raw Colossus matches in parallel.

One Colossus move is a serial 6502 timeline, so a single match uses one core.
This launcher keeps large machines busy by running different opening lanes at
the same time, each with its own raw Colossus state/output directory.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path
from typing import Any


DEFAULT_OPENINGS = (
    "engine",
    "e2e4",
    "d2d4",
    "c2c4",
    "g1f3",
    "b1c3",
    "e2e3",
    "d2d3",
    "g2g3",
    "b2b3",
    "c2c3",
    "f2f4",
)


@dataclass(frozen=True)
class Lane:
    index: int
    opening: str
    moves: tuple[str, ...]

    @property
    def name(self) -> str:
        if not self.moves:
            return f"{self.index:02d}_engine"
        return f"{self.index:02d}_{'_'.join(self.moves)}"


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output-dir", type=Path, default=Path("build") / "colossus_parallel")
    parser.add_argument("--profile", default="beast")
    parser.add_argument("--engine-color", choices=("white", "black"), default="white")
    parser.add_argument("--max-plies", type=int, default=8)
    parser.add_argument("--workers", type=int, default=os.cpu_count() or 1)
    parser.add_argument(
        "--openings",
        nargs="*",
        default=list(DEFAULT_OPENINGS),
        help="Opening lanes. Use comma-separated UCI moves for multi-move lanes, or 'engine' for no forced moves.",
    )
    parser.add_argument(
        "--difficulty",
        default=None,
        help="Engine difficulty passed through to run_colossus_match.py (e.g. hard, beast).",
    )
    parser.add_argument(
        "--c64-timeout",
        type=int,
        default=None,
        help="Per-move engine timeout cycles passed through to run_colossus_match.py.",
    )
    parser.add_argument(
        "--colossus-move-now-after-cycles",
        type=int,
        default=0,
        help="Per-move Colossus think budget in cycles before injecting its move-now command. 0 disables.",
    )
    parser.add_argument("--colossus-raw-cycles", type=int)
    parser.add_argument(
        "--colossus-raw-force-move-after-seconds",
        type=float,
        default=0.0,
        help="Safety wall stop for raw Colossus moves; no/illegal move is classified as opponent-failure and excluded from blunders.",
    )
    parser.add_argument("--colossus-raw-input", choices=("queued", "bulk"), default="queued")
    parser.add_argument("--colossus-raw-input-gap-cycles", type=int, default=250_000)
    parser.add_argument("--lane-timeout-seconds", type=float, default=0.0)
    parser.add_argument("--reuse-existing", action="store_true", help="Skip match execution for lanes with result.json.")
    parser.add_argument("--analyze-blunders", action="store_true")
    parser.add_argument(
        "--valid-blunders-only",
        action="store_true",
        help="Analyze only lanes with clean chess data: game-over or max-plies, no lane timeout, no Colossus timeout/illegal move.",
    )
    parser.add_argument(
        "--analyze-timeout-partials",
        dest="analyze_timeout_partials",
        action="store_true",
        default=False,
        help="With --valid-blunders-only, analyze legal partial result.json files written before a timeout.",
    )
    parser.add_argument(
        "--skip-timeout-partials",
        dest="analyze_timeout_partials",
        action="store_false",
        help="Do not analyze legal partial games when Colossus hits a lane or cycle timeout.",
    )
    parser.add_argument(
        "--completed-blunders-only",
        action="store_true",
        help="Analyze only lanes that ended in a legal game-over result.",
    )
    parser.add_argument(
        "--retry-partial-timeouts",
        action="store_true",
        help="Rerun useful partial-timeout lanes with a larger raw cycle cap.",
    )
    parser.add_argument("--retry-colossus-raw-cycles", type=int)
    parser.add_argument("--retry-lane-timeout-seconds", type=float, default=0.0)
    parser.add_argument("--retry-min-plies", type=int, default=2)
    parser.add_argument("--retry-workers", type=int)
    parser.add_argument("--retry-output-dir", type=Path)
    parser.add_argument("--stockfish-depth", type=int, default=10)
    parser.add_argument("--multipv", type=int, default=3)
    parser.add_argument("--threshold", type=int, default=20)
    parser.add_argument("--merged-corpus", type=Path)
    parser.add_argument("--python", default=sys.executable)
    return parser.parse_args(argv)


def parse_lane(index: int, opening: str) -> Lane:
    text = opening.strip().lower()
    if not text or text == "engine":
        return Lane(index, "engine", ())
    return Lane(index, text, tuple(part for part in text.split(",") if part))


def classify_lane_result(lane_result: dict[str, Any], engine_color: str) -> dict[str, Any]:
    termination = str(lane_result.get("termination") or "")
    result = str(lane_result.get("result") or "*")
    return_code = lane_result.get("returnCode")
    timed_out = bool(lane_result.get("timedOut"))
    has_error = bool(lane_result.get("error"))
    plies = int(lane_result.get("plies") or 0)

    if has_error:
        execution_status = "error"
    elif timed_out:
        execution_status = "lane-timeout"
    elif return_code not in (None, 0):
        execution_status = "nonzero-exit"
    elif plies <= 0:
        execution_status = "no-game-data"
    else:
        execution_status = "ok"

    if termination.startswith("colossus-illegal-move:"):
        termination_class = "colossus-illegal-move"
    elif termination:
        termination_class = termination
    else:
        termination_class = "missing-termination"

    timeout_phase = ""
    if timed_out:
        last_actor = str(lane_result.get("lastActor") or "")
        if last_actor == "c64":
            timeout_phase = "awaiting-colossus"
        elif last_actor == "colossus":
            timeout_phase = "awaiting-engine"
        elif plies <= 0:
            timeout_phase = "before-first-move"
        else:
            timeout_phase = "unknown"

    opponent_failure = termination_class in {"colossus-forfeit-time", "colossus-illegal-move"}
    clean_chess_data = execution_status == "ok" and termination_class in {"game-over", "max-plies"}
    partial_chess_data = (
        execution_status == "lane-timeout"
        and plies > 0
        and termination_class == "in-progress"
    ) or (
        execution_status in {"ok", "nonzero-exit"}
        and plies > 1
        and termination_class == "in-progress"
    ) or (
        execution_status == "ok"
        and plies > 1
        and termination_class == "colossus-timeout"
    )
    completed_game = clean_chess_data and termination_class == "game-over" and result != "*"
    engine_win_result = "1-0" if engine_color == "white" else "0-1"

    if opponent_failure:
        outcome = "opponent-failure"
    elif partial_chess_data:
        outcome = "partial-timeout"
    elif not clean_chess_data:
        outcome = "harness-failure"
    elif not completed_game:
        outcome = "unfinished"
    elif result == "1/2-1/2":
        outcome = "draw"
    elif result == engine_win_result:
        outcome = "engine-win"
    else:
        outcome = "colossus-win"

    lane_result["executionStatus"] = execution_status
    lane_result["terminationClass"] = termination_class
    lane_result["timeoutPhase"] = timeout_phase
    lane_result["cleanChessData"] = clean_chess_data
    lane_result["partialChessData"] = partial_chess_data
    lane_result["completedGame"] = completed_game
    lane_result["outcome"] = outcome
    return lane_result


def summarize_results(results: list[dict[str, Any]]) -> dict[str, Any]:
    execution = Counter(str(item.get("executionStatus") or "unknown") for item in results)
    terminations = Counter(str(item.get("terminationClass") or "unknown") for item in results)
    outcomes = Counter(str(item.get("outcome") or "unknown") for item in results)
    timeout_phases = Counter(
        str(item.get("timeoutPhase") or "none")
        for item in results
        if item.get("executionStatus") == "lane-timeout"
    )
    return {
        "lanes": len(results),
        "clean_chess_data": sum(1 for item in results if item.get("cleanChessData")),
        "partial_chess_data": sum(1 for item in results if item.get("partialChessData")),
        "completed_games": sum(1 for item in results if item.get("completedGame")),
        "execution": dict(sorted(execution.items())),
        "terminations": dict(sorted(terminations.items())),
        "outcomes": dict(sorted(outcomes.items())),
        "timeout_phases": dict(sorted(timeout_phases.items())),
    }


def output_text(value: str | bytes | None) -> str:
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return value


def last_actor_from_result(result: dict[str, Any]) -> str:
    moves = result.get("moves") if isinstance(result, dict) else None
    if not isinstance(moves, list) or not moves:
        return ""
    last = moves[-1]
    if not isinstance(last, dict):
        return ""
    return str(last.get("actor") or "")


def run_lane(args: argparse.Namespace, lane: Lane) -> dict[str, Any]:
    repo_root = args.repo_root.resolve()
    lane_dir = (repo_root / args.output_dir / lane.name).resolve()
    lane_dir.mkdir(parents=True, exist_ok=True)
    result_path = lane_dir / "result.json"
    if args.reuse_existing and result_path.exists():
        result = json.loads(result_path.read_text(encoding="utf-8"))
        return {
            "lane": lane.name,
            "opening": lane.opening,
            "moves": list(lane.moves),
            "elapsedSeconds": 0.0,
            "timedOut": False,
            "returnCode": 0,
            "resultPath": str(result_path),
            "pgnPath": str(lane_dir / "result.pgn"),
            "termination": result.get("termination"),
            "result": result.get("result"),
            "plies": len(result.get("moves", [])) if result else 0,
            "lastActor": last_actor_from_result(result),
            "ponder": result.get("ponder"),
            "stdoutTail": "reused existing result.json",
        }
    command = [
        args.python,
        str(repo_root / "tools" / "run_colossus_match.py"),
        "--colossus-backend",
        "raw",
        "--engine-color",
        args.engine_color,
        "--colossus-profile",
        args.profile,
        "--max-plies",
        str(args.max_plies),
        "--colossus-raw-output-dir",
        str(lane_dir / "raw"),
        "--json",
        str(lane_dir / "result.json"),
        "--pgn",
        str(lane_dir / "result.pgn"),
        "--colossus-raw-input",
        args.colossus_raw_input,
        "--colossus-raw-input-gap-cycles",
        str(args.colossus_raw_input_gap_cycles),
    ]
    if args.difficulty is not None:
        command.extend(["--difficulty", args.difficulty])
    if args.c64_timeout is not None:
        command.extend(["--c64-timeout", str(args.c64_timeout)])
    if args.colossus_move_now_after_cycles > 0:
        command.extend(["--colossus-move-now-after-cycles", str(args.colossus_move_now_after_cycles)])
    if args.colossus_raw_cycles is not None:
        command.extend(["--colossus-raw-cycles", str(args.colossus_raw_cycles)])
    if args.colossus_raw_force_move_after_seconds > 0:
        command.extend(
            [
                "--colossus-raw-force-move-after-seconds",
                f"{args.colossus_raw_force_move_after_seconds:g}",
            ]
        )
    if lane.moves:
        command.append("--force-white-moves")
        command.extend(lane.moves)

    started = time.monotonic()
    try:
        completed = subprocess.run(
            command,
            cwd=repo_root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=args.lane_timeout_seconds or None,
        )
        timed_out = False
    except subprocess.TimeoutExpired as exc:
        completed = None
        timed_out = True
        stdout = output_text(exc.stdout)
    else:
        stdout = output_text(completed.stdout)

    elapsed = time.monotonic() - started
    result: dict[str, Any] = {}
    if result_path.exists():
        result = json.loads(result_path.read_text(encoding="utf-8"))

    return {
        "lane": lane.name,
        "opening": lane.opening,
        "moves": list(lane.moves),
        "elapsedSeconds": elapsed,
        "timedOut": timed_out,
        "returnCode": None if completed is None else completed.returncode,
        "resultPath": str(result_path),
        "pgnPath": str(lane_dir / "result.pgn"),
        "termination": result.get("termination"),
        "result": result.get("result"),
        "plies": len(result.get("moves", [])) if result else 0,
        "lastActor": last_actor_from_result(result),
        "ponder": result.get("ponder"),
        "stdoutTail": "\n".join(stdout.splitlines()[-20:]),
    }


def extract_lane_blunders(args: argparse.Namespace, lane_result: dict[str, Any]) -> dict[str, Any]:
    result_path = Path(str(lane_result.get("resultPath") or ""))
    if lane_result.get("outcome") == "opponent-failure":
        lane_result["blunderCount"] = 0
        lane_result["blunderSkipped"] = "opponent-failure"
        return lane_result
    if args.completed_blunders_only and not lane_result.get("completedGame"):
        lane_result["blunderCount"] = 0
        lane_result["blunderSkipped"] = "not-completed-game"
        return lane_result
    allow_partial = bool(args.analyze_timeout_partials and lane_result.get("partialChessData"))
    if args.valid_blunders_only and not lane_result.get("cleanChessData") and not allow_partial:
        lane_result["blunderCount"] = 0
        lane_result["blunderSkipped"] = "not-clean-chess-data"
        return lane_result
    if not result_path.exists() or int(lane_result.get("plies") or 0) <= 0:
        lane_result["blunderCount"] = 0
        lane_result["blunderSkipped"] = "missing-result"
        return lane_result

    lane_dir = result_path.parent
    blunders_path = lane_dir / "blunders.json"
    analysis_path = lane_dir / "analysis.json"
    command = [
        args.python,
        str(args.repo_root.resolve() / "tools" / "extract_colossus_blunders.py"),
        str(result_path),
        "--stockfish-depth",
        str(args.stockfish_depth),
        "--multipv",
        str(args.multipv),
        "--threshold",
        str(args.threshold),
        "--json",
        str(blunders_path),
        "--analysis-json",
        str(analysis_path),
    ]
    completed = subprocess.run(
        command,
        cwd=args.repo_root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    lane_result["blunderExtractorReturnCode"] = completed.returncode
    lane_result["blunderExtractorTail"] = "\n".join(completed.stdout.splitlines()[-10:])
    lane_result["blundersPath"] = str(blunders_path)
    lane_result["analysisPath"] = str(analysis_path)
    if completed.returncode != 0 or not blunders_path.exists():
        lane_result["blunderCount"] = 0
        return lane_result

    corpus = json.loads(blunders_path.read_text(encoding="utf-8"))
    positions = corpus.get("positions", [])
    lane_result["blunderCount"] = len(positions)
    lane_result["worstBlunderLoss"] = max((int(item.get("centipawn_loss") or 0) for item in positions), default=0)
    return lane_result


def merge_blunder_corpora(args: argparse.Namespace, results: list[dict[str, Any]], output_dir: Path) -> Path:
    merged_by_fen: dict[str, dict[str, Any]] = {}
    for lane_result in results:
        blunders_path_text = lane_result.get("blundersPath")
        if not blunders_path_text:
            continue
        blunders_path = Path(str(blunders_path_text))
        if not blunders_path.exists():
            continue
        corpus = json.loads(blunders_path.read_text(encoding="utf-8"))
        for position in corpus.get("positions", []):
            fen = str(position.get("fen") or "")
            if not fen:
                continue
            previous = merged_by_fen.get(fen)
            if previous is None or int(position.get("centipawn_loss") or 0) > int(previous.get("centipawn_loss") or 0):
                merged_by_fen[fen] = position

    positions = sorted(
        merged_by_fen.values(),
        key=lambda item: (-int(item.get("centipawn_loss") or 0), str(item.get("name") or "")),
    )
    merged = {
        "generated_by": "tools/run_colossus_parallel.py",
        "source": str(output_dir),
        "stockfish_depth": args.stockfish_depth,
        "blunder_threshold": args.threshold,
        "valid_blunders_only": bool(args.valid_blunders_only),
        "analyze_timeout_partials": bool(args.analyze_timeout_partials),
        "completed_blunders_only": bool(args.completed_blunders_only),
        "retry_partial_timeouts": bool(args.retry_partial_timeouts or args.retry_colossus_raw_cycles is not None),
        "retry_colossus_raw_cycles": args.retry_colossus_raw_cycles,
        "positions": positions,
    }
    merged_path = args.merged_corpus or (output_dir / "blunders.json")
    merged_path.parent.mkdir(parents=True, exist_ok=True)
    merged_path.write_text(json.dumps(merged, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return merged_path


def run_lanes(args: argparse.Namespace, lanes: list[Lane], workers: int, label: str) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(run_lane, args, lane): lane for lane in lanes}
        for future in as_completed(futures):
            lane = futures[future]
            try:
                result = future.result()
            except Exception as exc:
                result = {
                    "lane": lane.name,
                    "opening": lane.opening,
                    "moves": list(lane.moves),
                    "error": str(exc),
                }
            result = classify_lane_result(result, args.engine_color)
            result["phase"] = label
            results.append(result)
            ponder = result.get("ponder") or {}
            ponder_text = ""
            if ponder:
                ponder_text = (
                    f" ponder={int(ponder.get('hits') or 0)}/"
                    f"{int(ponder.get('cached') or 0)}"
                )
            print(
                f"{label} {result['lane']}: plies={result.get('plies', 0)} "
                f"termination={result.get('termination') or 'error'} "
                f"outcome={result.get('outcome')} "
                f"timeout={result.get('timeoutPhase') or '-'} "
                f"elapsed={float(result.get('elapsedSeconds', 0.0)):.1f}s"
                f"{ponder_text}",
                flush=True,
            )

    results.sort(key=lambda item: item["lane"])
    return results


def result_quality(result: dict[str, Any]) -> tuple[int, int]:
    if result.get("completedGame"):
        class_score = 4
    elif result.get("cleanChessData"):
        class_score = 3
    elif result.get("partialChessData"):
        class_score = 2
    elif result.get("executionStatus") == "ok":
        class_score = 1
    else:
        class_score = 0
    return (class_score, int(result.get("plies") or 0))


def merge_retry_results(primary: list[dict[str, Any]], retry: list[dict[str, Any]]) -> list[dict[str, Any]]:
    best_by_lane = {str(result["lane"]): result for result in primary}
    for result in retry:
        lane = str(result["lane"])
        previous = best_by_lane.get(lane)
        if previous is None or result_quality(result) >= result_quality(previous):
            result["retrySelected"] = True
            best_by_lane[lane] = result
        elif previous is not None:
            previous["retryAvailable"] = True
    return [best_by_lane[key] for key in sorted(best_by_lane)]


def retry_args_for(args: argparse.Namespace) -> argparse.Namespace:
    retry_output_dir = args.retry_output_dir
    if retry_output_dir is None:
        retry_output_dir = Path(str(args.output_dir) + "_retry")
    retry_args = argparse.Namespace(**vars(args))
    retry_args.output_dir = retry_output_dir
    retry_args.colossus_raw_cycles = args.retry_colossus_raw_cycles
    retry_args.lane_timeout_seconds = args.retry_lane_timeout_seconds or args.lane_timeout_seconds
    return retry_args


def lanes_to_retry(args: argparse.Namespace, lanes_by_name: dict[str, Lane], results: list[dict[str, Any]]) -> list[Lane]:
    selected: list[Lane] = []
    seen: set[str] = set()
    for result in results:
        lane_name = str(result.get("lane") or "")
        if lane_name in seen:
            continue
        if not result.get("partialChessData"):
            continue
        if int(result.get("plies") or 0) < args.retry_min_plies:
            continue
        lane = lanes_by_name.get(lane_name)
        if lane is None:
            continue
        selected.append(lane)
        seen.add(lane_name)
    return selected


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    lanes = [parse_lane(index, opening) for index, opening in enumerate(args.openings, start=1)]
    if args.engine_color == "black" and any(lane.moves for lane in lanes):
        print("--engine-color black does not support forced white opening lanes.", file=sys.stderr)
        return 2
    output_dir = args.repo_root.resolve() / args.output_dir
    output_dir.mkdir(parents=True, exist_ok=True)

    workers = max(1, min(args.workers, len(lanes)))
    primary_results = run_lanes(args, lanes, workers, "lane")
    retry_results: list[dict[str, Any]] = []
    retry_requested = args.retry_partial_timeouts or args.retry_colossus_raw_cycles is not None
    if retry_requested:
        if args.retry_colossus_raw_cycles is None:
            print("--retry-partial-timeouts requires --retry-colossus-raw-cycles.", file=sys.stderr)
            return 2
        lanes_by_name = {lane.name: lane for lane in lanes}
        retry_lanes = lanes_to_retry(args, lanes_by_name, primary_results)
        if retry_lanes:
            retry_args = retry_args_for(args)
            retry_output_dir = args.repo_root.resolve() / retry_args.output_dir
            retry_output_dir.mkdir(parents=True, exist_ok=True)
            retry_workers = max(1, min(args.retry_workers or workers, len(retry_lanes)))
            print(
                f"retrying {len(retry_lanes)} partial lanes with "
                f"{args.retry_colossus_raw_cycles:,} raw cycles",
                flush=True,
            )
            retry_results = run_lanes(retry_args, retry_lanes, retry_workers, "retry")
        else:
            print("retrying 0 partial lanes", flush=True)

    results = merge_retry_results(primary_results, retry_results)
    outcome_summary = summarize_results(results)
    print(
        "outcomes: "
        f"clean={outcome_summary['clean_chess_data']}/{outcome_summary['lanes']} "
        f"partial={outcome_summary['partial_chess_data']} "
        f"completed={outcome_summary['completed_games']} "
        f"engine_wins={outcome_summary['outcomes'].get('engine-win', 0)} "
        f"colossus_wins={outcome_summary['outcomes'].get('colossus-win', 0)} "
        f"draws={outcome_summary['outcomes'].get('draw', 0)} "
        f"unfinished={outcome_summary['outcomes'].get('unfinished', 0)} "
        f"partial_timeouts={outcome_summary['outcomes'].get('partial-timeout', 0)} "
        f"harness_failures={outcome_summary['outcomes'].get('harness-failure', 0)}"
    )
    ponder_totals: dict[str, int] = {}
    for result in results:
        ponder = result.get("ponder") or {}
        for key, value in ponder.items():
            if isinstance(value, bool):
                continue
            if isinstance(value, int):
                ponder_totals[key] = ponder_totals.get(key, 0) + value
    if ponder_totals:
        print(
            "ponder: "
            f"live_samples={ponder_totals.get('live_samples', 0)} "
            f"searches={ponder_totals.get('searches', 0)} "
            f"cached={ponder_totals.get('cached', 0)} "
            f"hits={ponder_totals.get('hits', 0)} "
            f"misses={ponder_totals.get('misses', 0)} "
            f"replaced={ponder_totals.get('replaced', 0)} "
            f"repeat_skips={ponder_totals.get('repeat_skips', 0)} "
            f"cycles_hit={ponder_totals.get('cycles_hit', 0):,} "
            f"cycles_invested={ponder_totals.get('cycles_invested', 0):,} "
            f"cycles_aborted={ponder_totals.get('cycles_aborted', 0):,}"
        )
    if args.analyze_blunders:
        for index, result in enumerate(results):
            results[index] = extract_lane_blunders(args, result)
        merged_path = merge_blunder_corpora(args, results, output_dir)
        total_blunders = sum(int(item.get("blunderCount") or 0) for item in results)
        print(f"blunders: {total_blunders}, merged: {merged_path}")

    summary_path = output_dir / "summary.json"
    summary = {
        "generated_by": "tools/run_colossus_parallel.py",
        "output_dir": str(output_dir),
        "profile": args.profile,
        "engine_color": args.engine_color,
        "max_plies": args.max_plies,
        "workers": workers,
        "colossus_raw_input": args.colossus_raw_input,
        "colossus_raw_input_gap_cycles": args.colossus_raw_input_gap_cycles,
        "retry_partial_timeouts": bool(retry_requested),
        "retry_colossus_raw_cycles": args.retry_colossus_raw_cycles,
        "retry_min_plies": args.retry_min_plies,
        "valid_blunders_only": bool(args.valid_blunders_only),
        "analyze_timeout_partials": bool(args.analyze_timeout_partials),
        "completed_blunders_only": bool(args.completed_blunders_only),
        "outcomes": outcome_summary,
        "ponder": ponder_totals,
        "primary_results": primary_results,
        "retry_results": retry_results,
        "results": results,
    }
    summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"summary: {summary_path}")
    return 1 if any(item.get("error") for item in results) else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
