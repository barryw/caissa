#!/usr/bin/env python3
"""Play measured games between the C64 AI and a local Stockfish process.

This runner is intentionally external to the simulator test suite. It is useful
for strength tracking, move-quality tuning, and catching illegal/no-move
regressions over whole games without running a Stockfish server.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import shutil
import sys
from dataclasses import asdict, dataclass
from pathlib import Path

from run_stockfish_strength import (
    C64_BACKENDS,
    DEFAULT_IMAGE,
    DEFAULT_PULL,
    DIFFICULTY,
    ProbePosition,
    RUNNER_TARGETS,
    RunnerError,
    Stockfish,
    StockfishLine,
    chess,
    create_sim6502_runner,
    require_chess,
    repo_root_from_script,
    runner_required_files,
    run_c64_ai,
)


@dataclass
class MoveRecord:
    ply: int
    side: str
    actor: str
    fen: str
    move: str | None
    san: str | None
    legal: bool
    c64_cycles: int | None
    stockfish_best: str | None
    stockfish_score: int | None
    c64_score: int | None
    stockfish_rank: int | None
    centipawn_loss: int | None
    note: str


@dataclass
class GameResult:
    game: int
    c64_color: str
    result: str
    c64_score: float | None
    termination: str
    plies: int
    c64_moves: int
    c64_average_loss: float | None
    c64_max_loss: int | None
    c64_total_cycles: int
    moves: list[MoveRecord]
    pgn: str
    final_score_cp: int | None = None


def normalize_side(side: bool) -> str:
    return "white" if side == chess.WHITE else "black"


def c64_score_from_result(result: str, c64_color: str) -> float | None:
    if result == "1/2-1/2":
        return 0.5
    if result == "1-0":
        return 1.0 if c64_color == "white" else 0.0
    if result == "0-1":
        return 1.0 if c64_color == "black" else 0.0
    return None


def elo_diff_from_score(score: float, games: int) -> float | None:
    if games <= 0:
        return None
    rate = score / games
    if rate <= 0.0 or rate >= 1.0:
        return None
    return -400.0 * math.log10((1.0 / rate) - 1.0)


def c64_loss_for_move(
    stockfish: Stockfish,
    fen: str,
    c64_move: str,
    depth: int,
    multipv: int,
) -> tuple[str | None, int | None, int | None, int | None, int | None]:
    """Return best move, best score, C64 score, rank, and centipawn loss."""

    lines = stockfish.analyze(fen, depth=depth, multipv=multipv)
    if not lines:
        return None, None, None, None, None

    best = lines[0]
    for index, line in enumerate(lines, start=1):
        if line.move == c64_move:
            return best.move, best.score_cp, line.score_cp, index, max(0, best.score_cp - line.score_cp)

    reply_lines = stockfish.analyze(fen, depth=depth, multipv=1, moves=[c64_move])
    if not reply_lines:
        return best.move, best.score_cp, None, None, None

    c64_score = -reply_lines[0].score_cp
    return best.move, best.score_cp, c64_score, None, max(0, best.score_cp - c64_score)


def summarize_runner_error(exc: RunnerError) -> str:
    lines = [line.strip() for line in str(exc).splitlines() if line.strip()]
    if not lines:
        return "C64 runner error"
    for line in reversed(lines[1:]):
        if "FATAL" in line or "ERROR" in line or "timeout" in line.lower() or "permission denied" in line.lower():
            return f"{lines[0]} {line}"
    return f"{lines[0]} {lines[-1]}" if len(lines) > 1 else lines[0]


def stockfish_best_move(
    stockfish: Stockfish,
    fen: str,
    depth: int,
    movetime_ms: int | None = None,
) -> StockfishLine:
    lines = stockfish.analyze(fen, depth=depth, multipv=1, movetime_ms=movetime_ms)
    if not lines:
        raise RunnerError("Stockfish did not return a principal variation")
    return lines[0]


def c64_result_from_score(score_cp: int, c64_color: str, win_cp: int) -> tuple[str, str]:
    if score_cp >= win_cp:
        return ("1-0" if c64_color == "white" else "0-1", "adjudicated-win")
    if score_cp <= -win_cp:
        return ("0-1" if c64_color == "white" else "1-0", "adjudicated-loss")
    return "1/2-1/2", "adjudicated-draw"


def pgn_for_game(start_fen: str, moves: list[MoveRecord], result: str, c64_color: str, stockfish_depth: int) -> str:
    import chess.pgn

    game = chess.pgn.Game()
    game.headers["Event"] = "C64 AI vs Stockfish"
    game.headers["White"] = "C64 AI" if c64_color == "white" else "Stockfish"
    game.headers["Black"] = "C64 AI" if c64_color == "black" else "Stockfish"
    game.headers["Result"] = result
    game.headers["StockfishDepth"] = str(stockfish_depth)
    if start_fen != chess.STARTING_FEN:
        game.headers["SetUp"] = "1"
        game.headers["FEN"] = start_fen

    board = chess.Board(start_fen)
    node = game
    for record in moves:
        if not record.legal or not record.move:
            break
        move = chess.Move.from_uci(record.move)
        node = node.add_variation(move)
        board.push(move)

    return str(game)


def safe_name(value: str) -> str:
    return re.sub(r"[^a-zA-Z0-9_-]+", "-", value).strip("-") or "position"


def blunder_bucket(loss: int) -> str:
    if loss >= 500:
        return "500-plus"
    if loss >= 300:
        return "300-plus"
    if loss >= 150:
        return "150-plus"
    return "minor"


def build_blunder_corpus(results: list[GameResult], threshold: int) -> dict[str, object]:
    positions = []
    seen_fens = set()
    for result in results:
        for move in result.moves:
            if move.actor != "c64" or not move.legal or not move.move:
                continue
            if move.centipawn_loss is None or move.centipawn_loss < threshold:
                continue
            if move.fen in seen_fens:
                continue
            seen_fens.add(move.fen)

            best = move.stockfish_best or "unknown"
            c64_played = move.san or move.move
            name = safe_name(f"game-{result.game:02d}-ply-{move.ply:03d}-{move.side}-loss-{move.centipawn_loss}")
            positions.append(
                {
                    "name": name,
                    "fen": move.fen,
                    "description": (
                        f"{move.side} to move: C64 played {c64_played}, "
                        f"Stockfish preferred {best}, loss {move.centipawn_loss}cp"
                    ),
                    "category": "game-blunder",
                    "tags": [
                        "game",
                        "blunder",
                        result.c64_color,
                        move.side,
                        f"loss-{blunder_bucket(move.centipawn_loss)}",
                    ],
                    "c64_move": move.move,
                    "c64_san": move.san,
                    "stockfish_best": move.stockfish_best,
                    "stockfish_rank": move.stockfish_rank,
                    "centipawn_loss": move.centipawn_loss,
                    "c64_cycles": move.c64_cycles,
                    "game": result.game,
                    "ply": move.ply,
                    "c64_color": result.c64_color,
                }
            )

    positions.sort(key=lambda item: (-int(item["centipawn_loss"]), str(item["name"])))
    return {
        "generated_by": "tools/run_stockfish_games.py",
        "blunder_threshold": threshold,
        "positions": positions,
    }


def run_self_test() -> int:
    high_loss = MoveRecord(
        ply=7,
        side="white",
        actor="c64",
        fen="8/8/8/8/8/8/8/K6k w - - 0 1",
        move="a1a2",
        san="Ka2",
        legal=True,
        c64_cycles=1234,
        stockfish_best="a1b1",
        stockfish_score=40,
        c64_score=-160,
        stockfish_rank=None,
        centipawn_loss=200,
        note="ok",
    )
    low_loss = MoveRecord(
        ply=9,
        side="white",
        actor="c64",
        fen="8/8/8/8/8/8/K7/7k w - - 0 1",
        move="a2a3",
        san="Ka3",
        legal=True,
        c64_cycles=5678,
        stockfish_best="a2b2",
        stockfish_score=20,
        c64_score=-20,
        stockfish_rank=2,
        centipawn_loss=40,
        note="ok",
    )
    result = GameResult(
        game=1,
        c64_color="white",
        result="*",
        c64_score=None,
        termination="max-plies",
        plies=9,
        c64_moves=2,
        c64_average_loss=120,
        c64_max_loss=200,
        c64_total_cycles=6912,
        moves=[high_loss, low_loss],
        pgn="",
    )
    corpus = build_blunder_corpus([result], threshold=150)
    positions = corpus["positions"]
    assert isinstance(positions, list)
    assert len(positions) == 1
    assert positions[0]["name"] == "game-01-ply-007-white-loss-200"
    assert positions[0]["stockfish_best"] == "a1b1"
    assert positions[0]["tags"][-1] == "loss-150-plus"
    print("Self-test passed.")
    return 0


def play_game(
    *,
    stockfish: Stockfish,
    analysis_stockfish: Stockfish | None = None,
    repo_root: Path,
    image: str,
    pull: str,
    runner_target: str,
    c64_backend: str,
    game_number: int,
    start_fen: str,
    c64_color: str,
    difficulty: str,
    stockfish_depth: int,
    stockfish_movetime_ms: int | None,
    analysis_depth: int,
    analysis_multipv: int,
    max_plies: int,
    c64_timeout: int,
    c64_book: bool,
    adjudicate_max_plies: bool,
    adjudicate_win_cp: int,
    sim6502_runner: object | None = None,
) -> GameResult:
    analysis_engine = analysis_stockfish or stockfish
    board = chess.Board(start_fen)
    c64_side = chess.WHITE if c64_color == "white" else chess.BLACK
    moves: list[MoveRecord] = []
    termination = "max-plies"
    final_score_cp = None

    for ply in range(1, max_plies + 1):
        if board.is_game_over(claim_draw=True):
            termination = board.outcome(claim_draw=True).termination.name.lower()
            break

        fen = board.fen()
        side_name = normalize_side(board.turn)
        actor = "c64" if board.turn == c64_side else "stockfish"

        if actor == "c64":
            position = ProbePosition(
                name=f"game-{game_number}-ply-{ply}",
                fen=fen,
                description=f"C64 move at game {game_number}, ply {ply}",
                category="game",
                tags=["game", c64_color],
            )
            try:
                move_uci, cycles, _ = run_c64_ai(
                    repo_root=repo_root,
                    image=image,
                    pull=pull,
                    position=position,
                    difficulty=difficulty,
                    timeout=c64_timeout,
                    book_enabled=c64_book,
                    runner_target=runner_target,
                    c64_backend=c64_backend,
                    sim6502_runner=sim6502_runner,
                )
            except RunnerError as exc:
                note = summarize_runner_error(exc)
                moves.append(
                    MoveRecord(
                        ply=ply,
                        side=side_name,
                        actor=actor,
                        fen=fen,
                        move=None,
                        san=None,
                        legal=False,
                        c64_cycles=None,
                        stockfish_best=None,
                        stockfish_score=None,
                        c64_score=None,
                        stockfish_rank=None,
                        centipawn_loss=None,
                        note=note,
                    )
                )
                termination = "c64-runner-error"
                break

            if not move_uci:
                moves.append(
                    MoveRecord(
                        ply=ply,
                        side=side_name,
                        actor=actor,
                        fen=fen,
                        move=None,
                        san=None,
                        legal=False,
                        c64_cycles=cycles,
                        stockfish_best=None,
                        stockfish_score=None,
                        c64_score=None,
                        stockfish_rank=None,
                        centipawn_loss=None,
                        note="C64 AI returned no move",
                    )
                )
                termination = "c64-no-move"
                break

            try:
                move = chess.Move.from_uci(move_uci)
            except ValueError:
                move = None

            legal = move in board.legal_moves if move else False
            if not legal or move is None:
                moves.append(
                    MoveRecord(
                        ply=ply,
                        side=side_name,
                        actor=actor,
                        fen=fen,
                        move=move_uci,
                        san=None,
                        legal=False,
                        c64_cycles=cycles,
                        stockfish_best=None,
                        stockfish_score=None,
                        c64_score=None,
                        stockfish_rank=None,
                        centipawn_loss=None,
                        note="illegal C64 move",
                    )
                )
                termination = "c64-illegal-move"
                break

            san = board.san(move)
            best, best_score, c64_score, rank, loss = c64_loss_for_move(
                stockfish=analysis_engine,
                fen=fen,
                c64_move=move_uci,
                depth=analysis_depth,
                multipv=analysis_multipv,
            )
            moves.append(
                MoveRecord(
                    ply=ply,
                    side=side_name,
                    actor=actor,
                    fen=fen,
                    move=move_uci,
                    san=san,
                    legal=True,
                    c64_cycles=cycles,
                    stockfish_best=best,
                    stockfish_score=best_score,
                    c64_score=c64_score,
                    stockfish_rank=rank,
                    centipawn_loss=loss,
                    note="ok",
                )
            )
            board.push(move)
            continue

        line = stockfish_best_move(
            stockfish,
            fen=fen,
            depth=stockfish_depth,
            movetime_ms=stockfish_movetime_ms,
        )
        move = chess.Move.from_uci(line.move)
        if move not in board.legal_moves:
            moves.append(
                MoveRecord(
                    ply=ply,
                    side=side_name,
                    actor=actor,
                    fen=fen,
                    move=line.move,
                    san=None,
                    legal=False,
                    c64_cycles=None,
                    stockfish_best=line.move,
                    stockfish_score=line.score_cp,
                    c64_score=None,
                    stockfish_rank=1,
                    centipawn_loss=None,
                    note="illegal Stockfish move",
                )
            )
            termination = "stockfish-illegal-move"
            break

        san = board.san(move)
        moves.append(
            MoveRecord(
                ply=ply,
                side=side_name,
                actor=actor,
                fen=fen,
                move=line.move,
                san=san,
                legal=True,
                c64_cycles=None,
                stockfish_best=line.move,
                stockfish_score=line.score_cp,
                c64_score=None,
                stockfish_rank=1,
                centipawn_loss=None,
                note="ok",
            )
        )
        board.push(move)

    if board.is_game_over(claim_draw=True):
        outcome = board.outcome(claim_draw=True)
        assert outcome is not None
        result = board.result(claim_draw=True)
        termination = outcome.termination.name.lower()
    elif termination == "max-plies" and adjudicate_max_plies:
        line = stockfish_best_move(analysis_engine, fen=board.fen(), depth=analysis_depth)
        white_score = line.score_cp if board.turn == chess.WHITE else -line.score_cp
        final_score_cp = white_score if c64_color == "white" else -white_score
        result, termination = c64_result_from_score(final_score_cp, c64_color, adjudicate_win_cp)
    elif termination == "c64-illegal-move":
        result = "0-1" if c64_color == "white" else "1-0"
    elif termination in ("c64-no-move", "c64-runner-error"):
        result = "0-1" if c64_color == "white" else "1-0"
    elif termination == "stockfish-illegal-move":
        result = "1-0" if c64_color == "white" else "0-1"
    else:
        result = "*"

    c64_losses = [move.centipawn_loss for move in moves if move.actor == "c64" and move.centipawn_loss is not None]
    c64_cycles = [move.c64_cycles for move in moves if move.actor == "c64" and move.c64_cycles is not None]
    pgn = pgn_for_game(start_fen, moves, result, c64_color, stockfish_depth)

    return GameResult(
        game=game_number,
        c64_color=c64_color,
        result=result,
        c64_score=c64_score_from_result(result, c64_color),
        termination=termination,
        plies=sum(1 for move in moves if move.legal),
        c64_moves=sum(1 for move in moves if move.actor == "c64"),
        c64_average_loss=(sum(c64_losses) / len(c64_losses)) if c64_losses else None,
        c64_max_loss=max(c64_losses) if c64_losses else None,
        c64_total_cycles=sum(c64_cycles),
        moves=moves,
        pgn=pgn,
        final_score_cp=final_score_cp,
    )


def side_schedule(c64_side: str, games_per_side: int) -> list[str]:
    if c64_side == "both":
        return [side for _ in range(games_per_side) for side in ("white", "black")]
    return [c64_side] * games_per_side


def print_summary(
    results: list[GameResult],
    stockfish_depth: int,
    analysis_depth: int,
    runner_target: str,
    c64_backend: str,
) -> None:
    score_values = [result.c64_score for result in results if result.c64_score is not None]
    c64_score = sum(score_values)
    decided = len(score_values)
    elo_diff = elo_diff_from_score(c64_score, decided)
    losses = [result.c64_average_loss for result in results if result.c64_average_loss is not None]
    max_losses = [result.c64_max_loss for result in results if result.c64_max_loss is not None]
    failed = [
        result
        for result in results
        if "illegal" in result.termination
        or "no-move" in result.termination
        or "runner-error" in result.termination
    ]
    average_loss = f"{(sum(losses) / len(losses)):.1f}" if losses else "-"
    max_loss = str(max(max_losses)) if max_losses else "-"
    elo_text = "-" if elo_diff is None else f"{elo_diff:+.0f}"

    print(f"Stockfish game runner: {len(results)} game(s)")
    print(
        f"  runner={runner_target} c64_backend={c64_backend} "
        f"stockfish_depth={stockfish_depth} analysis_depth={analysis_depth}"
    )
    print(
        "  "
        f"c64_score={c64_score:g}/{decided} "
        f"elo_diff={elo_text} "
        f"avg_loss={average_loss} "
        f"max_loss={max_loss} "
        f"failures={len(failed)}"
    )

    for result in results:
        avg_loss = "-" if result.c64_average_loss is None else f"{result.c64_average_loss:.1f}"
        max_loss = "-" if result.c64_max_loss is None else str(result.c64_max_loss)
        print(
            f"  game={result.game:02d} c64={result.c64_color:5} "
            f"result={result.result:7} plies={result.plies:3} "
            f"term={result.termination:18} avg_loss={avg_loss:>6} "
            f"max_loss={max_loss:>6} cycles={result.c64_total_cycles:,}"
        )
        if result.final_score_cp is not None:
            print(f"    adjudicated_score={result.final_score_cp:+}cp from C64 perspective")

        for move in result.moves:
            rank = "-" if move.stockfish_rank is None else str(move.stockfish_rank)
            loss = "-" if move.centipawn_loss is None else str(move.centipawn_loss)
            prefix = "C64" if move.actor == "c64" else "SF "
            print(
                f"    {prefix} ply={move.ply:3} {move.side:5} "
                f"move={move.move or '-':7} san={move.san or '-':8} "
                f"sf={move.stockfish_best or '-':7} rank={rank:>2} loss={loss:>6} "
                f"cycles={move.c64_cycles or 0:,} {move.note}"
            )


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Play measured games between the C64 AI and local Stockfish.")
    parser.add_argument("--stockfish-path", default=os.environ.get("STOCKFISH_PATH") or shutil.which("stockfish"))
    parser.add_argument("--repo-root", type=Path, default=repo_root_from_script())
    parser.add_argument("--sim6502-image", default=DEFAULT_IMAGE)
    parser.add_argument("--sim6502-pull", choices=["always", "missing", "never"], default=DEFAULT_PULL)
    parser.add_argument("--runner-target", choices=sorted(RUNNER_TARGETS), default="headless")
    parser.add_argument("--c64-backend", choices=C64_BACKENDS, default="sim6502")
    parser.add_argument("--difficulty", choices=sorted(DIFFICULTY), default="hard")
    parser.add_argument("--stockfish-depth", type=int, default=3)
    parser.add_argument("--stockfish-movetime-ms", type=int, default=None, help="Use go movetime for Stockfish opponent moves instead of depth-only play.")
    parser.add_argument("--analysis-depth", type=int, default=6)
    parser.add_argument("--analysis-multipv", type=int, default=3)
    parser.add_argument("--stockfish-skill", type=int, default=None, help="Optional Stockfish Skill Level, 0-20.")
    parser.add_argument("--c64-side", choices=["white", "black", "both"], default="both")
    parser.add_argument("--games-per-side", type=int, default=1)
    parser.add_argument("--start-fen", default=chess.STARTING_FEN if chess else None)
    parser.add_argument("--max-plies", type=int, default=160)
    parser.add_argument("--c64-timeout", type=int, default=20_000_000_000)
    parser.add_argument("--adjudicate-max-plies", action="store_true", help="Use Stockfish eval to score games that hit --max-plies.")
    parser.add_argument("--adjudicate-win-cp", type=int, default=500, help="Centipawn edge from C64 perspective needed to adjudicate a win/loss; otherwise draw.")
    parser.add_argument("--book", choices=["on", "off"], default="off", help="Use the C64 opening book for C64 moves when --runner-target=app.")
    parser.add_argument("--json", type=Path, help="Write machine-readable game results.")
    parser.add_argument("--pgn", type=Path, help="Write PGN for completed/partial games.")
    parser.add_argument("--blunder-corpus", type=Path, help="Write high-loss C64 moves as a Stockfish corpus JSON file.")
    parser.add_argument("--blunder-threshold", type=int, default=150, help="Centipawn loss needed for --blunder-corpus.")
    parser.add_argument("--max-average-loss", type=float, default=None, help="Fail if C64 average move loss exceeds this.")
    parser.add_argument("--min-score", type=float, default=None, help="Fail if C64 match score is below this.")
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        return run_self_test()

    require_chess()
    if not args.stockfish_path:
        print("Could not find Stockfish. Set STOCKFISH_PATH or pass --stockfish-path.", file=sys.stderr)
        return 2

    repo_root = args.repo_root.resolve()
    for required_name in runner_required_files(args.runner_target):
        required = repo_root / required_name
        if not required.exists():
            target = "make engine-build" if args.runner_target == "headless" else "make build"
            print(f"Missing required file: {required}. Run `{target}` first.", file=sys.stderr)
            return 2

    stockfish = Stockfish(args.stockfish_path)
    sim6502_runner = None
    if args.stockfish_skill is not None:
        stockfish.set_option("Skill Level", str(args.stockfish_skill))
        stockfish.is_ready()

    try:
        if args.c64_backend == "sim6502":
            sim6502_runner = create_sim6502_runner(repo_root, args.runner_target)
            sim6502_runner.start()
        results = [
            play_game(
                stockfish=stockfish,
                repo_root=repo_root,
                image=args.sim6502_image,
                pull=args.sim6502_pull,
                runner_target=args.runner_target,
                c64_backend=args.c64_backend,
                sim6502_runner=sim6502_runner,
                game_number=index,
                start_fen=args.start_fen,
                c64_color=c64_color,
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
            for index, c64_color in enumerate(side_schedule(args.c64_side, args.games_per_side), start=1)
        ]
    finally:
        if sim6502_runner is not None:
            sim6502_runner.close()
        stockfish.close()

    print_summary(
        results,
        stockfish_depth=args.stockfish_depth,
        analysis_depth=args.analysis_depth,
        runner_target=args.runner_target,
        c64_backend=args.c64_backend,
    )

    if args.json:
        args.json.write_text(json.dumps([asdict(result) for result in results], indent=2), encoding="utf-8")
    if args.pgn:
        args.pgn.write_text("\n\n".join(result.pgn for result in results) + "\n", encoding="utf-8")
    if args.blunder_corpus:
        corpus = build_blunder_corpus(results, threshold=args.blunder_threshold)
        args.blunder_corpus.write_text(json.dumps(corpus, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(
            f"Wrote {len(corpus['positions'])} blunder position(s) "
            f">= {args.blunder_threshold}cp to {args.blunder_corpus}"
        )

    failed = any(
        "illegal" in result.termination
        or "no-move" in result.termination
        or "runner-error" in result.termination
        for result in results
    )
    if failed:
        return 1

    if args.max_average_loss is not None:
        losses = [result.c64_average_loss for result in results if result.c64_average_loss is not None]
        if losses and (sum(losses) / len(losses)) > args.max_average_loss:
            return 1

    if args.min_score is not None:
        scores = [result.c64_score for result in results if result.c64_score is not None]
        if sum(scores) < args.min_score:
            return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
