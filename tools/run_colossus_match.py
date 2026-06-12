#!/usr/bin/env python3
"""Run a VICE-hosted Colossus Chess 4 game against the local C64 AI."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

from probe_colossus_vice import (  # noqa: E402
    DEFAULT_D64,
    DEFAULT_PROGRAM_INDEX,
    DEFAULT_VICE_MCP_URL,
    ViceMCPClient,
    decode_screen,
    send_colossus_move,
)
from run_stockfish_strength import (  # noqa: E402
    C64_BACKENDS,
    DEFAULT_IMAGE,
    DEFAULT_PULL,
    DIFFICULTY,
    ProbePosition,
    RUNNER_TARGETS,
    RunnerError,
    c64_encoded_move_to_uci,
    chess,
    create_sim6502_runner,
    fen_to_c64,
    require_chess,
    repo_root_from_script,
    runner_required_files,
    run_c64_ai,
    square_to_0x88,
)
from run_colossus_raw import (  # noqa: E402
    DEFAULT_RUNNER_DLL as DEFAULT_RAW_RUNNER_DLL,
    DEFAULT_RUNTIME_DIR as DEFAULT_RAW_RUNTIME_DIR,
    PROFILE_PRESETS as COLOSSUS_RAW_PROFILES,
    best_line,
    move_for_screen,
    run_raw as run_raw_colossus_command,
    screen_search_stats,
)


MOVE_LINE_RE = re.compile(
    r"^\s*(\d+)\s+([a-h][1-8])\s*[-x]\s*([a-h][1-8])"
    r"[+#]?(?:\s+([a-h][1-8])\s*[-x]\s*([a-h][1-8])[+#]?)?",
    re.IGNORECASE,
)
ASSUMED_MOVE_RE = re.compile(r"\bAssumed:\s*([a-h][1-8])\s*[-x]\s*([a-h][1-8])", re.IGNORECASE)
COLOSSUS_BOARD_BASE = 0xA700
COLOSSUS_BOARD_ORIGIN = 13
COLOSSUS_BOARD_STRIDE = 10
COLOSSUS_PIECE_SYMBOLS = {
    0x00: None,
    0x02: "p",
    0x03: "n",
    0x04: "b",
    0x05: "r",
    0x06: "q",
    0x07: "k",
    0xFE: "P",
    0xFD: "N",
    0xFC: "B",
    0xFB: "R",
    0xFA: "Q",
    0xF9: "K",
}


@dataclass
class MatchMove:
    ply: int
    side: str
    actor: str
    fen: str
    move: str
    san: str
    c64_cycles: int | None = None
    colossus_cycles: int | None = None
    colossus_steps: int | None = None
    colossus_lookahead: int | None = None
    colossus_positions: int | None = None
    colossus_wall_ms: float | None = None
    colossus_cycles_per_second: float | None = None
    note: str = ""


@dataclass
class PonderStats:
    enabled: bool = False
    live_samples: int = 0
    candidates: int = 0
    searches: int = 0
    cached: int = 0
    replaced: int = 0
    search_no_reply: int = 0
    search_errors: int = 0
    repeat_skips: int = 0
    hits: int = 0
    misses: int = 0
    accept_failures: int = 0
    illegal_replies: int = 0
    use_errors: int = 0
    unused: int = 0
    cycles_invested: int = 0
    cycles_aborted: int = 0
    cycles_hit: int = 0


@dataclass
class MatchResult:
    result: str
    termination: str
    moves: list[MatchMove]
    pgn: str
    final_fen: str
    decoded_screen: str
    ponder: PonderStats | None = None


def read_screen(vice: ViceMCPClient) -> str:
    screen_ram = vice.call("vice.memory.read", {"address": "$0400", "size": 1000})
    return decode_screen(screen_ram.get("data", []))


def set_warp(vice: ViceMCPClient, speed: int) -> None:
    vice.call("vice.machine.config.set", {"resources": {"WarpMode": 1, "Speed": speed}})
    vice.call("vice.execution.run")


def disable_colossus_prediction(vice: ViceMCPClient) -> None:
    # Colossus prediction mode guesses the opponent's next move and can desync
    # automated engine-vs-engine input. $B49B=0 disables that feature.
    vice.call("vice.memory.write", {"address": "$b49b", "data": [0], "bank": "ram"})


def wait_for_boot(vice: ViceMCPClient, timeout_seconds: float, poll_seconds: float) -> str:
    deadline = time.monotonic() + timeout_seconds
    last_screen = ""
    while time.monotonic() < deadline:
        last_screen = read_screen(vice)
        if "COLOSSUS 4.0" in last_screen.upper() and "LOADING" not in last_screen.upper():
            return last_screen
        time.sleep(poll_seconds)
    raise TimeoutError(f"Colossus did not reach the board within {timeout_seconds:.1f}s\n{last_screen}")


def boot_colossus(args: argparse.Namespace, vice: ViceMCPClient) -> str:
    vice.call("vice.disk.attach", {"unit": 8, "path": str(args.d64)})
    vice.call("vice.machine.reset", {"mode": "hard", "run_after": True})
    vice.call("vice.autostart", {"path": str(args.d64), "index": args.program_index, "run": True})
    set_warp(vice, args.warp_speed)
    return wait_for_boot(vice, args.boot_timeout_seconds, args.poll_seconds)


def screen_move_pairs(screen: str) -> list[str]:
    return [move4 for _, move4 in screen_move_entries(screen)]


def screen_move_entries(screen: str) -> list[tuple[int, str]]:
    moves: list[str] = []
    entries: list[tuple[int, str]] = []
    for line in screen.splitlines():
        match = MOVE_LINE_RE.match(line)
        if not match:
            continue
        move_number_text, white_from, white_to, black_from, black_to = match.groups()
        white_ply = (int(move_number_text) * 2) - 1
        entries.append((white_ply, (white_from + white_to).lower()))
        if black_from and black_to:
            entries.append((white_ply + 1, (black_from + black_to).lower()))
    return entries


def screen_assumed_move(screen: str) -> str | None:
    match = ASSUMED_MOVE_RE.search(screen)
    if not match:
        return None
    return (match.group(1) + match.group(2)).lower()


def legalize_from_to(board: Any, move4: str) -> Any | None:
    from_square = chess.parse_square(move4[:2])
    to_square = chess.parse_square(move4[2:4])
    matches = [
        move
        for move in board.legal_moves
        if move.from_square == from_square and move.to_square == to_square
    ]
    if not matches:
        return None
    for move in matches:
        if move.promotion == chess.QUEEN:
            return move
    return matches[0]


def best_line_move_tokens(line: str) -> list[str]:
    return [
        token.lower()
        for token in re.findall(r"\b[a-h][1-8][a-h][1-8][qrbn]?\b", line, flags=re.IGNORECASE)
        if token.lower() != "null"
    ]


def predicted_colossus_reply_from_best_line(line: str, engine_move_uci: str) -> str | None:
    tokens = best_line_move_tokens(line)
    engine_move4 = engine_move_uci[:4].lower()
    for index, token in enumerate(tokens[:-1]):
        if token[:4] == engine_move4:
            return tokens[index + 1]
    return None


def predicted_colossus_reply_from_live_line(board: Any, line: str) -> Any | None:
    for token in best_line_move_tokens(line):
        move = legalize_from_to(board, token)
        if move is not None:
            return move
    return None


def move_from_ponder_response(board: Any, response: dict[str, Any]) -> Any | None:
    move_uci = c64_encoded_move_to_uci(board.fen(), int(response.get("encoded", 0xFFFF)))
    if not move_uci:
        return None
    move = chess.Move.from_uci(move_uci)
    return move if move in board.legal_moves else None


def try_start_ponder_for_move(
    args: argparse.Namespace,
    sim_runner: Any | None,
    board: Any,
    predicted_move: Any | None,
    stats: PonderStats | None = None,
    existing: dict[str, Any] | None = None,
    source: str = "best-line",
    timeout_cycles: int | None = None,
) -> dict[str, Any] | None:
    if not args.ponder or sim_runner is None:
        return existing
    if predicted_move is None:
        return existing
    if existing is not None:
        existing_move = existing.get("move")
        if (
            existing_move is not None
            and existing_move.from_square == predicted_move.from_square
            and existing_move.to_square == predicted_move.to_square
        ):
            return existing
    if stats is not None:
        stats.candidates += 1
        stats.searches += 1
    ponder_timeout = args.ponder_timeout_cycles if timeout_cycles is None else timeout_cycles
    try:
        ponder_response = sim_runner.ponder_search(
            fen_to_c64(board.fen()),
            DIFFICULTY[args.difficulty],
            ponder_timeout,
            square_to_0x88(predicted_move.from_square),
            square_to_0x88(predicted_move.to_square),
        )
    except Exception as exc:
        if stats is not None:
            stats.search_errors += 1
            if ponder_timeout > 0:
                stats.cycles_aborted += ponder_timeout
        message = str(exc)
        if "exceeded" in message:
            log_progress(
                args,
                f"ponder timeout {source} Colossus {predicted_move.uci()} after {ponder_timeout:,} cycles",
            )
        else:
            log_progress(args, f"ponder skipped after bridge error: {exc}")
        return existing
    if not ponder_response.get("valid"):
        if stats is not None:
            stats.search_no_reply += 1
        return existing
    cycles = int(ponder_response.get("cycles") or 0)
    if stats is not None:
        stats.cached += 1
        stats.cycles_invested += cycles
        if existing is not None:
            stats.replaced += 1
    log_progress(args, f"ponder cached {source} Colossus {predicted_move.uci()} cycles={cycles:,}")
    return {
        "move": predicted_move,
        "cycles": cycles,
        "response": ponder_response,
        "source": source,
    }


def try_start_ponder(
    args: argparse.Namespace,
    sim_runner: Any | None,
    board: Any,
    engine_move_uci: str,
    last_colossus_best_line: str,
    stats: PonderStats | None = None,
) -> dict[str, Any] | None:
    predicted_uci = predicted_colossus_reply_from_best_line(last_colossus_best_line, engine_move_uci)
    predicted_move = legalize_from_to(board, predicted_uci) if predicted_uci else None
    return try_start_ponder_for_move(
        args,
        sim_runner,
        board,
        predicted_move,
        stats,
        source="previous-line",
    )


def try_start_live_ponder(
    args: argparse.Namespace,
    sim_runner: Any | None,
    board: Any,
    sample: dict[str, Any],
    stats: PonderStats,
    existing: dict[str, Any] | None,
    attempted_moves: dict[str, int] | None = None,
) -> dict[str, Any] | None:
    stats.live_samples += 1
    line = str(sample.get("line") or "")
    predicted_move = predicted_colossus_reply_from_live_line(board, line)
    if predicted_move is None:
        return existing
    move_key = predicted_move.uci()[:4]
    lookahead = int(sample.get("lookahead") or 0)
    if attempted_moves is not None:
        previous_lookahead = attempted_moves.get(move_key)
        if previous_lookahead is not None and lookahead <= previous_lookahead:
            stats.repeat_skips += 1
            return existing
        attempted_moves[move_key] = lookahead
    source = "live-line"
    if lookahead:
        source += f"/d{lookahead}"
    timeout_cycles = args.ponder_timeout_cycles
    if lookahead >= args.ponder_deep_min_lookahead:
        timeout_cycles = args.ponder_deep_timeout_cycles
    return try_start_ponder_for_move(
        args,
        sim_runner,
        board,
        predicted_move,
        stats,
        existing=existing,
        source=source,
        timeout_cycles=timeout_cycles,
    )


def bytes_from_mcp_data(data: list[Any]) -> bytes:
    values: list[int] = []
    for value in data:
        if isinstance(value, str):
            values.append(int(value, 16) & 0xFF)
        else:
            values.append(int(value) & 0xFF)
    return bytes(values)


def read_colossus_piece_map(vice: ViceMCPClient) -> dict[int, Any]:
    result = vice.call(
        "vice.memory.read",
        {"address": f"${COLOSSUS_BOARD_BASE:04x}", "size": 100, "bank": "ram"},
    )
    data = bytes_from_mcp_data(result.get("data", []))
    if len(data) < COLOSSUS_BOARD_ORIGIN + (COLOSSUS_BOARD_STRIDE * 7) + 8:
        raise RuntimeError(f"Colossus board RAM read returned {len(data)} bytes")

    pieces: dict[int, Any] = {}
    for rank in range(1, 9):
        for file_index in range(8):
            offset = COLOSSUS_BOARD_ORIGIN + ((8 - rank) * COLOSSUS_BOARD_STRIDE) + file_index
            code = data[offset]
            if code not in COLOSSUS_PIECE_SYMBOLS:
                raise RuntimeError(
                    f"Unexpected Colossus piece byte ${code:02x} at "
                    f"{chess.square_name(chess.square(file_index, rank - 1))}"
                )
            symbol = COLOSSUS_PIECE_SYMBOLS[code]
            if symbol is not None:
                pieces[chess.square(file_index, rank - 1)] = chess.Piece.from_symbol(symbol)
    return pieces


def piece_map_matches_board(piece_map: dict[int, Any], board: Any) -> bool:
    return all(piece_map.get(square) == board.piece_at(square) for square in chess.SQUARES)


def piece_map_board_fen(piece_map: dict[int, Any]) -> str:
    board = chess.Board(None)
    for square, piece in piece_map.items():
        board.set_piece_at(square, piece)
    return board.board_fen()


def infer_move_from_colossus_memory(board: Any, piece_map: dict[int, Any]) -> Any | None:
    for move in board.legal_moves:
        candidate = board.copy(stack=False)
        candidate.push(move)
        if piece_map_matches_board(piece_map, candidate):
            return move
    return None


def parsed_screen_moves(start_fen: str, screen: str) -> list[Any]:
    board = chess.Board(start_fen)
    parsed = []
    for move4 in screen_move_pairs(screen):
        move = legalize_from_to(board, move4)
        if move is None:
            break
        parsed.append(move)
        board.push(move)
    return parsed


def wait_for_screen_plies(
    args: argparse.Namespace,
    vice: ViceMCPClient,
    start_fen: str,
    target_plies: int,
    timeout_seconds: float,
    require_prompt: bool = False,
) -> tuple[list[Any], str]:
    deadline = time.monotonic() + timeout_seconds
    last_screen = ""
    last_moves: list[Any] = []
    last_warp_refresh = 0.0
    while time.monotonic() < deadline:
        now = time.monotonic()
        if now - last_warp_refresh > 5.0:
            set_warp(vice, args.warp_speed)
            last_warp_refresh = now
        last_screen = read_screen(vice)
        last_moves = parsed_screen_moves(start_fen, last_screen)
        prompt_ready = (not require_prompt) or ("YOUR MOVE" in last_screen.upper())
        if len(last_moves) >= target_plies and prompt_ready:
            return last_moves, last_screen
        time.sleep(args.poll_seconds)
    raise TimeoutError(
        f"Colossus move log reached {len(last_moves)} plies, expected {target_plies}"
        f"{' plus prompt' if require_prompt else ''} within {timeout_seconds:.1f}s\n{last_screen}"
    )


def wait_for_colossus_memory_position(
    args: argparse.Namespace,
    vice: ViceMCPClient,
    expected_board: Any,
    timeout_seconds: float,
) -> str:
    deadline = time.monotonic() + timeout_seconds
    last_board_fen = ""
    last_warp_refresh = 0.0
    while time.monotonic() < deadline:
        now = time.monotonic()
        if now - last_warp_refresh > 5.0:
            set_warp(vice, args.warp_speed)
            last_warp_refresh = now
        piece_map = read_colossus_piece_map(vice)
        last_board_fen = piece_map_board_fen(piece_map)
        if piece_map_matches_board(piece_map, expected_board):
            return read_screen(vice)
        time.sleep(args.poll_seconds)
    raise TimeoutError(
        f"Colossus RAM did not reach expected position within {timeout_seconds:.1f}s; "
        f"expected={expected_board.board_fen()} actual={last_board_fen}\n{read_screen(vice)}"
    )


def wait_for_colossus_memory_after_engine_move(
    args: argparse.Namespace,
    vice: ViceMCPClient,
    expected_board: Any,
    timeout_seconds: float,
) -> tuple[str, Any | None]:
    deadline = time.monotonic() + timeout_seconds
    last_board_fen = ""
    last_warp_refresh = 0.0
    while time.monotonic() < deadline:
        now = time.monotonic()
        if now - last_warp_refresh > 5.0:
            set_warp(vice, args.warp_speed)
            last_warp_refresh = now
        piece_map = read_colossus_piece_map(vice)
        last_board_fen = piece_map_board_fen(piece_map)
        if piece_map_matches_board(piece_map, expected_board):
            return read_screen(vice), None
        reply = infer_move_from_colossus_memory(expected_board, piece_map)
        if reply is not None:
            return read_screen(vice), reply
        time.sleep(args.poll_seconds)
    raise TimeoutError(
        f"Colossus RAM did not acknowledge expected position within {timeout_seconds:.1f}s; "
        f"expected={expected_board.board_fen()} actual={last_board_fen}\n{read_screen(vice)}"
    )


def wait_for_colossus_memory_move(
    args: argparse.Namespace,
    vice: ViceMCPClient,
    board: Any,
    timeout_seconds: float,
) -> tuple[Any, str]:
    deadline = time.monotonic() + timeout_seconds
    last_board_fen = ""
    last_warp_refresh = 0.0
    while time.monotonic() < deadline:
        now = time.monotonic()
        if now - last_warp_refresh > 5.0:
            set_warp(vice, args.warp_speed)
            last_warp_refresh = now
        piece_map = read_colossus_piece_map(vice)
        last_board_fen = piece_map_board_fen(piece_map)
        move = infer_move_from_colossus_memory(board, piece_map)
        if move is not None:
            return move, read_screen(vice)
        time.sleep(args.poll_seconds)
    raise TimeoutError(
        f"Colossus RAM did not produce a legal move for {board.fen()} within {timeout_seconds:.1f}s; "
        f"actual={last_board_fen}\n{read_screen(vice)}"
    )


def pgn_for_match(start_fen: str, moves: list[MatchMove], result: str, engine_color: str) -> str:
    import chess.pgn

    game = chess.pgn.Game()
    game.headers["Event"] = "C64 AI vs Colossus Chess 4"
    game.headers["White"] = "C64 AI" if engine_color == "white" else "Colossus 4.0"
    game.headers["Black"] = "C64 AI" if engine_color == "black" else "Colossus 4.0"
    game.headers["Result"] = result
    if start_fen != chess.STARTING_FEN:
        game.headers["SetUp"] = "1"
        game.headers["FEN"] = start_fen

    node = game
    for record in moves:
        node = node.add_variation(chess.Move.from_uci(record.move))
    return str(game)


def sync_screen_moves(
    board: Any,
    records: list[MatchMove],
    screen_moves: list[Any],
    engine_side: bool,
    pending_cycles: dict[int, int],
) -> None:
    while len(records) < len(screen_moves):
        move = screen_moves[len(records)]
        if move not in board.legal_moves:
            raise RuntimeError(f"Colossus log produced illegal move {move.uci()} for {board.fen()}")
        append_move_record(board, records, move, engine_side, pending_cycles)


def sync_visible_screen_moves(
    board: Any,
    records: list[MatchMove],
    screen: str,
    engine_side: bool,
    pending_cycles: dict[int, int],
) -> None:
    entries = dict(screen_move_entries(screen))
    while True:
        move4 = entries.get(len(records) + 1)
        if move4 is None:
            return
        move = legalize_from_to(board, move4)
        if move is None:
            raise RuntimeError(f"Colossus visible log produced illegal move {move4} for {board.fen()}")
        append_move_record(board, records, move, engine_side, pending_cycles)


def wait_for_visible_screen_ply(
    args: argparse.Namespace,
    vice: ViceMCPClient,
    target_ply: int,
    timeout_seconds: float,
) -> str:
    deadline = time.monotonic() + timeout_seconds
    last_screen = ""
    last_visible: list[int] = []
    last_warp_refresh = 0.0
    while time.monotonic() < deadline:
        now = time.monotonic()
        if now - last_warp_refresh > 5.0:
            set_warp(vice, args.warp_speed)
            last_warp_refresh = now
        last_screen = read_screen(vice)
        last_visible = [ply for ply, _ in screen_move_entries(last_screen)]
        if target_ply in last_visible:
            return last_screen
        time.sleep(args.poll_seconds)
    raise TimeoutError(
        f"Colossus visible log did not show ply {target_ply} within {timeout_seconds:.1f}s; "
        f"visible={last_visible}\n{last_screen}"
    )


def send_engine_move_with_ack(
    args: argparse.Namespace,
    vice: ViceMCPClient,
    move_uci: str,
    target_ply: int,
) -> str:
    last_error: TimeoutError | None = None
    for _ in range(args.move_attempts):
        send_colossus_move(
            vice,
            move_uci,
            input_mode=args.move_input,
            hold_frames=args.move_hold_frames,
            key_gap=args.move_key_gap,
        )
        try:
            return wait_for_visible_screen_ply(
                args,
                vice,
                target_ply,
                args.input_timeout_seconds,
            )
        except TimeoutError as exc:
            last_error = exc
            set_warp(vice, args.warp_speed)
    if last_error is not None:
        raise last_error
    raise RuntimeError("move send was not attempted")


def append_move_record(
    board: Any,
    records: list[MatchMove],
    move: Any,
    engine_side: bool,
    pending_cycles: dict[int, int],
    note: str = "",
    colossus_stats: dict[str, Any] | None = None,
) -> None:
    ply = len(records) + 1
    fen = board.fen()
    san = board.san(move)
    actor = "c64" if board.turn == engine_side else "colossus"
    records.append(
        MatchMove(
            ply=ply,
            side="white" if board.turn == chess.WHITE else "black",
            actor=actor,
            fen=fen,
            move=move.uci(),
            san=san,
            c64_cycles=pending_cycles.pop(ply, None),
            colossus_cycles=(colossus_stats or {}).get("cycles"),
            colossus_steps=(colossus_stats or {}).get("steps"),
            colossus_lookahead=(colossus_stats or {}).get("lookahead"),
            colossus_positions=(colossus_stats or {}).get("positions"),
            colossus_wall_ms=(colossus_stats or {}).get("wall_ms"),
            colossus_cycles_per_second=(colossus_stats or {}).get("cycles_per_second"),
            note=note,
        )
    )
    board.push(move)


def log_progress(args: argparse.Namespace, message: str) -> None:
    if args.progress:
        print(message, file=sys.stderr, flush=True)


def log_last_record(args: argparse.Namespace, records: list[MatchMove]) -> None:
    if not records:
        return
    record = records[-1]
    suffix = ""
    if record.c64_cycles is not None:
        suffix = f" c64_cycles={record.c64_cycles:,}"
    elif record.colossus_cycles is not None:
        suffix = f" colossus_cycles={record.colossus_cycles:,}"
        if record.colossus_wall_ms is not None:
            suffix += f" wall={record.colossus_wall_ms / 1000.0:.2f}s"
    log_progress(args, f"ply {record.ply:02d} {record.actor:8s} {record.move:5s} {record.san}{suffix}")


def log_new_records(args: argparse.Namespace, records: list[MatchMove], start_index: int) -> None:
    for index in range(start_index, len(records)):
        log_last_record(args, records[: index + 1])


# Cycle budget for committing an already-found best line after the move-now
# keypress. Probes resumed from a result-json meta commit within ~260M cycles
# (keyboard poll alignment); this leaves wide margin.
MOVE_NOW_COMMIT_CYCLES = 1_000_000_000

# Whether the move-now press lands depends on the PC the think phase stopped
# at; some stop points BRK immediately on pc-style resume. Between attempts,
# continue the search briefly (a result-json resume, which always works) so
# the next attempt starts from a fresh PC.
MOVE_NOW_MAX_ATTEMPTS = 4
MOVE_NOW_NUDGE_CYCLES = 50_000_000


class RawColossusSession:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.runtime_dir = self._repo_relative(args.colossus_raw_runtime_dir)
        self.output_dir = self._repo_relative(args.colossus_raw_output_dir)
        self.runner = self._repo_relative(args.colossus_raw_runner)
        self.ram = self.runtime_dir / "ready.ram.bin"
        self.cpu_view = self.runtime_dir / "ready_cpu.ram.bin"
        self.meta = self.runtime_dir / "ready.json"
        self.last_screen = ""
        self.profile = COLOSSUS_RAW_PROFILES[args.colossus_profile]
        self.cycles = args.colossus_raw_cycles if args.colossus_raw_cycles is not None else self.profile["cycles"]
        self.tod_cycles_per_tick = (
            args.colossus_raw_tod_cycles_per_tick
            if args.colossus_raw_tod_cycles_per_tick is not None
            else self.profile["tod_cycles_per_tick"]
        )
        self.force_move_after_seconds = max(0.0, args.colossus_raw_force_move_after_seconds)
        self.move_now_after_cycles = max(0, args.colossus_move_now_after_cycles)
        self.pokes = [*self.profile["pokes"], *args.colossus_raw_poke]

    def _repo_relative(self, path: Path) -> Path:
        return path if path.is_absolute() else self.args.repo_root / path

    def ensure_ready(self) -> None:
        missing = [path for path in (self.ram, self.cpu_view, self.meta) if not path.exists()]
        if missing:
            raise RuntimeError(
                "Missing Colossus raw runtime artifacts: "
                + ", ".join(str(path) for path in missing)
                + ". Run tools/dump_colossus_runtime.py first."
            )
        if not self.runner.exists():
            subprocess.run(
                ["dotnet", "build", "tools/ColossusRawRunner/ColossusRawRunner.csproj", "-c", "Release"],
                cwd=self.args.repo_root,
                check=True,
            )
        self.output_dir.mkdir(parents=True, exist_ok=True)
        if (self.runtime_dir / "ready.screen.txt").exists():
            self.last_screen = (self.runtime_dir / "ready.screen.txt").read_text(encoding="utf-8", errors="replace")

    def raw_move_input_args(self, move_uci: str) -> list[str]:
        if self.args.colossus_raw_input == "bulk":
            return ["--move", move_uci]
        return [
            "--queued-move",
            move_uci,
            "--queued-gap-cycles",
            str(self.args.colossus_raw_input_gap_cycles),
        ]

    def raw_input_bytes_args(self, bytes_text: str) -> list[str]:
        if self.args.colossus_raw_input == "bulk":
            return ["--input-bytes", bytes_text]
        return [
            "--queued-input-bytes",
            bytes_text,
            "--queued-gap-cycles",
            str(self.args.colossus_raw_input_gap_cycles),
        ]

    def raw_time_limit_args(self) -> list[str]:
        if self.force_move_after_seconds <= 0:
            return []
        return ["--wall-time-limit-seconds", f"{self.force_move_after_seconds:g}"]

    def think_cycles(self) -> int:
        if self.move_now_after_cycles > 0:
            return self.move_now_after_cycles
        return self.cycles

    def force_move_now(self, out_prefix: Path, stop_regex: str, target_ply: int) -> dict[str, Any]:
        """Inject Colossus's own move-now command into a still-thinking state.

        Colossus 4 commits its currently displayed best line when 'M' is
        pressed mid-search. This bounds per-move think time externally while
        the committed move is still entirely Colossus's choice.

        The matrix keypress is only scanned when the machine resumes with the
        boot dump's interrupt state: result-json metas restore a context whose
        keyboard IRQ never fires, so the press would be ignored forever.
        Resume from the think RAM at its exact PC with the boot meta instead.
        Whether the press lands is still PC-dependent (some stop points sit in
        interrupt-masked code), so retry from each attempt's advanced state.
        """
        source_prefix = out_prefix
        result: dict[str, Any] = {}
        total_cycles = 0
        for attempt in range(1, MOVE_NOW_MAX_ATTEMPTS + 1):
            if attempt > 1:
                nudge_prefix = out_prefix.parent / f"{out_prefix.name}_nudge{attempt}"
                nudge_command = [
                    "dotnet",
                    str(self.runner),
                    "--ram",
                    str(source_prefix.with_suffix(".ram.bin")),
                    "--cpu-view",
                    str(self.cpu_view),
                    "--meta",
                    str(source_prefix.with_suffix(".json")),
                    "--cycles",
                    str(MOVE_NOW_NUDGE_CYCLES),
                    "--tod-cycles-per-tick",
                    str(self.tod_cycles_per_tick),
                    "--poll-steps",
                    str(self.args.colossus_raw_poll_steps),
                    "--ram-out",
                    str(nudge_prefix.with_suffix(".ram.bin")),
                    "--json",
                    str(nudge_prefix.with_suffix(".json")),
                    "--screen",
                    str(nudge_prefix.with_suffix(".screen.txt")),
                ]
                nudge_result = self.run_raw_command(nudge_command)
                total_cycles += int(nudge_result.get("cycles") or 0)
                source_prefix = nudge_prefix
            forced_prefix = out_prefix.parent / f"{out_prefix.name}_forced{attempt}"
            think_json = json.loads(source_prefix.with_suffix(".json").read_text(encoding="utf-8"))
            end_pc = int(think_json["end"]["PC"])
            command = [
                "dotnet",
                str(self.runner),
                "--ram",
                str(source_prefix.with_suffix(".ram.bin")),
                "--cpu-view",
                str(self.cpu_view),
                "--meta",
                str(self.runtime_dir / "ready.json"),
                "--pc",
                str(end_pc),
                "--matrix-text",
                "m",
                "--cycles",
                str(MOVE_NOW_COMMIT_CYCLES),
                # Commit at the normal clock; the move was already chosen
                # during the think phase, so only a few extra TOD seconds
                # elapse.
                "--tod-cycles-per-tick",
                "100000",
                "--stop-when-screen-regex",
                stop_regex,
                "--poll-steps",
                str(self.args.colossus_raw_poll_steps),
                "--ram-out",
                str(forced_prefix.with_suffix(".ram.bin")),
                "--json",
                str(forced_prefix.with_suffix(".json")),
                "--screen",
                str(forced_prefix.with_suffix(".screen.txt")),
            ]
            command.extend(self.raw_time_limit_args())
            result = self.run_raw_command(command)
            total_cycles += int(result.get("cycles") or 0)
            result["forcedPrefix"] = str(forced_prefix)
            result["forcedAttempts"] = attempt
            # Success check must agree with the caller's parser: the committed
            # move shows up as screen move list entry target_ply. A redundant
            # M press after a commit lands in Colossus's input phase and
            # silently desyncs the rest of the game, so never retry past
            # success.
            screen = str(result.get("screen", ""))
            if dict(screen_move_entries(screen)).get(target_ply) is not None:
                break
            # Only chain from the forced state when it actually executed;
            # instant-BRK attempts leave the prior searching state authoritative.
            if int(result.get("steps") or 0) > 1000:
                source_prefix = forced_prefix
        result["cycles"] = total_cycles
        return result

    def legal_reply_screen_pattern(self, board: Any | None) -> str:
        if board is None:
            return r"[a-h][1-8][-x][a-h][1-8][+#]?"
        moves = sorted({move_for_screen(move.uci()) for move in board.legal_moves})
        if not moves:
            return r"(?!)"
        return "(?:" + "|".join(moves) + ")"

    def run_raw_command(
        self,
        command: list[str],
        live_sample_handler: Any | None = None,
    ) -> dict[str, Any]:
        if live_sample_handler is None:
            return run_raw_colossus_command(self.args, command)

        process = subprocess.Popen(
            command,
            cwd=self.args.repo_root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        assert process.stdout is not None
        stdout_lines: list[str] = []
        final_response: dict[str, Any] | None = None
        for line in process.stdout:
            text = line.strip()
            if not text:
                continue
            stdout_lines.append(text)
            try:
                payload = json.loads(text)
            except json.JSONDecodeError:
                continue
            if payload.get("type") == "best-line-sample":
                live_sample_handler(payload)
            else:
                final_response = payload

        stderr = process.stderr.read() if process.stderr is not None else ""
        return_code = process.wait()
        if return_code != 0:
            raise RuntimeError(
                f"raw runner failed with {return_code}\n"
                f"stdout:\n{os.linesep.join(stdout_lines)}\n"
                f"stderr:\n{stderr}"
            )
        if final_response is None:
            for text in reversed(stdout_lines):
                try:
                    payload = json.loads(text)
                except json.JSONDecodeError:
                    continue
                if payload.get("type") != "best-line-sample":
                    final_response = payload
                    break
        if final_response is None:
            raise RuntimeError(f"raw runner produced no final JSON\nstderr:\n{stderr}")
        return final_response

    def go_first(self) -> tuple[str, dict[str, Any], str]:
        out_prefix = self.output_dir / "ply01"
        command = [
            "dotnet",
            str(self.runner),
            "--ram",
            str(self.ram),
            "--cpu-view",
            str(self.cpu_view),
            "--meta",
            str(self.meta),
            "--cycles",
            str(self.think_cycles()),
            "--tod-cycles-per-tick",
            str(self.tod_cycles_per_tick),
            "--stop-when-screen-regex",
            r"^\s*1\s+[a-h][1-8][-x][a-h][1-8]",
            "--poll-steps",
            str(self.args.colossus_raw_poll_steps),
            "--ram-out",
            str(out_prefix.with_suffix(".ram.bin")),
            "--json",
            str(out_prefix.with_suffix(".json")),
            "--screen",
            str(out_prefix.with_suffix(".screen.txt")),
        ]
        command.extend(self.raw_input_bytes_args("c7"))
        command.extend(self.raw_time_limit_args())
        for poke in self.pokes:
            command.extend(["--poke", poke])
        result = self.run_raw_command(command)
        self.last_screen = str(result.get("screen", ""))
        visible_entries = dict(screen_move_entries(self.last_screen))
        reply_uci = visible_entries.get(1)
        forced = False
        if reply_uci is None and self.move_now_after_cycles > 0:
            think_cycles = int(result.get("cycles") or 0)
            result = self.force_move_now(out_prefix, r"^\s*1\s+[a-h][1-8][-x][a-h][1-8]", 1)
            result["cycles"] = int(result.get("cycles") or 0) + think_cycles
            self.last_screen = str(result.get("screen", ""))
            visible_entries = dict(screen_move_entries(self.last_screen))
            reply_uci = visible_entries.get(1)
            forced = reply_uci is not None
        if reply_uci is None:
            limit_text = "uncapped" if self.think_cycles() <= 0 else f"{self.think_cycles()} cycles"
            if self.force_move_after_seconds > 0:
                limit_text += f" or {self.force_move_after_seconds:g}s wall"
            raise TimeoutError(
                f"Raw Colossus profile {self.args.colossus_profile!r} did not produce first move within "
                f"{limit_text}; visible={sorted(visible_entries)}, stop={result.get('stopReason')}.\n"
                f"{self.last_screen}"
            )

        if forced:
            forced_prefix = Path(result["forcedPrefix"])
            self.ram = forced_prefix.with_suffix(".ram.bin")
            self.meta = forced_prefix.with_suffix(".json")
        else:
            self.ram = out_prefix.with_suffix(".ram.bin")
            self.meta = out_prefix.with_suffix(".json")
        stats = self.stats_for_result(result)
        if forced:
            stats["forced_move_now"] = True
        return reply_uci, stats, best_line(self.last_screen)

    def stats_for_result(self, result: dict[str, Any]) -> dict[str, Any]:
        lookahead_text, positions_text = screen_search_stats(self.last_screen)
        stats = {
            "cycles": int(result.get("cycles") or 0),
            "steps": int(result.get("steps") or 0),
            "wall_ms": float(result.get("wallMilliseconds") or 0.0),
            "cycles_per_second": float(result.get("cyclesPerSecond") or 0.0),
            "best_line_samples": len(result.get("bestLineSamples") or []),
            "stop_reason": str(result.get("stopReason") or ""),
        }
        if lookahead_text != "?":
            stats["lookahead"] = int(lookahead_text)
        if positions_text != "?":
            stats["positions"] = int(positions_text)
        return stats

    def reply(
        self,
        move_uci: str,
        move_number: int,
        target_ply: int,
        board: Any | None = None,
        sim_runner: Any | None = None,
        ponder_stats: PonderStats | None = None,
        pending_ponder: dict[str, Any] | None = None,
    ) -> tuple[str, dict[str, Any], str, dict[str, Any] | None]:
        out_prefix = self.output_dir / f"ply{target_ply:02d}"
        reply_pattern = self.legal_reply_screen_pattern(board)
        if self.args.engine_color == "white":
            stop_regex = rf"^\s*{move_number}\s+{move_for_screen(move_uci)}\s+{reply_pattern}"
        else:
            stop_regex = rf"^\s*{move_number + 1}\s+{reply_pattern}"
        command = [
            "dotnet",
            str(self.runner),
            "--ram",
            str(self.ram),
            "--cpu-view",
            str(self.cpu_view),
            "--meta",
            str(self.meta),
            "--cycles",
            str(self.think_cycles()),
            "--tod-cycles-per-tick",
            str(self.tod_cycles_per_tick),
            "--stop-when-screen-regex",
            stop_regex,
            "--poll-steps",
            str(self.args.colossus_raw_poll_steps),
            "--ram-out",
            str(out_prefix.with_suffix(".ram.bin")),
            "--json",
            str(out_prefix.with_suffix(".json")),
            "--screen",
            str(out_prefix.with_suffix(".screen.txt")),
        ]
        command.extend(self.raw_move_input_args(move_uci))
        command.extend(self.raw_time_limit_args())
        if board is not None and sim_runner is not None and ponder_stats is not None and self.args.ponder:
            command.append("--emit-best-line-samples")
        for poke in self.pokes:
            command.extend(["--poke", poke])

        attempted_live_moves: dict[str, int] = {}

        def handle_live_sample(sample: dict[str, Any]) -> None:
            nonlocal pending_ponder
            if board is None or sim_runner is None or ponder_stats is None:
                return
            pending_ponder = try_start_live_ponder(
                self.args,
                sim_runner,
                board,
                sample,
                ponder_stats,
                pending_ponder,
                attempted_live_moves,
            )

        result = self.run_raw_command(
            command,
            handle_live_sample if board is not None and sim_runner is not None and ponder_stats is not None else None,
        )
        self.last_screen = str(result.get("screen", ""))
        visible_entries = dict(screen_move_entries(self.last_screen))
        reply_uci = visible_entries.get(target_ply)
        forced = False
        if reply_uci is None and self.move_now_after_cycles > 0:
            think_cycles = int(result.get("cycles") or 0)
            result = self.force_move_now(out_prefix, stop_regex, target_ply)
            result["cycles"] = int(result.get("cycles") or 0) + think_cycles
            self.last_screen = str(result.get("screen", ""))
            visible_entries = dict(screen_move_entries(self.last_screen))
            reply_uci = visible_entries.get(target_ply)
            forced = reply_uci is not None
        if reply_uci is None:
            limit_text = "uncapped" if self.think_cycles() <= 0 else f"{self.think_cycles()} cycles"
            if self.force_move_after_seconds > 0:
                limit_text += f" or {self.force_move_after_seconds:g}s wall"
            raise TimeoutError(
                f"Raw Colossus profile {self.args.colossus_profile!r} did not reply within "
                f"{limit_text}; visible={sorted(visible_entries)}, stop={result.get('stopReason')}.\n"
                f"{self.last_screen}"
            )

        if forced:
            forced_prefix = Path(result["forcedPrefix"])
            self.ram = forced_prefix.with_suffix(".ram.bin")
            self.meta = forced_prefix.with_suffix(".json")
        else:
            self.ram = out_prefix.with_suffix(".ram.bin")
            self.meta = out_prefix.with_suffix(".json")
        stats = self.stats_for_result(result)
        if forced:
            stats["forced_move_now"] = True
        best = best_line(self.last_screen)
        return reply_uci, stats, best, pending_ponder


def write_progress_outputs(
    args: argparse.Namespace,
    records: list[MatchMove],
    board: Any,
    decoded_screen: str,
    ponder: PonderStats | None = None,
) -> None:
    if not args.json and not args.pgn:
        return
    pgn = pgn_for_match(args.start_fen, records, "*", args.engine_color)
    partial = MatchResult(
        result="*",
        termination="in-progress",
        moves=records,
        pgn=pgn,
        final_fen=board.fen(),
        decoded_screen=decoded_screen,
        ponder=ponder,
    )
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(asdict(partial), indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if args.pgn:
        args.pgn.parent.mkdir(parents=True, exist_ok=True)
        args.pgn.write_text(partial.pgn + "\n", encoding="utf-8")


def run_match_raw(args: argparse.Namespace) -> MatchResult:
    require_chess()
    if args.start_fen != chess.STARTING_FEN:
        raise SystemExit("Colossus raw runtime starts from the normal starting FEN.")
    missing = [path for path in runner_required_files(args.runner_target) if not (args.repo_root / path).exists()]
    if missing:
        raise SystemExit(f"Missing C64 runner files: {', '.join(missing)}. Run `make build` first.")

    board = chess.Board(args.start_fen)
    engine_side = chess.WHITE if args.engine_color == "white" else chess.BLACK
    records: list[MatchMove] = []
    pending_cycles: dict[int, int] = {}
    forced_white_moves = [move.strip().lower() for move in args.force_white_moves if move.strip()]
    if forced_white_moves and engine_side == chess.BLACK:
        raise SystemExit("--force-white-moves is only supported when --engine-color white.")
    forced_white_index = 0
    colossus = RawColossusSession(args)
    colossus.ensure_ready()
    log_progress(
        args,
        f"raw Colossus profile={args.colossus_profile} engine_color={args.engine_color} max_plies={args.max_plies}",
    )
    termination = "max-plies"
    adjudicated_result: str | None = None
    last_colossus_best_line = ""
    pending_ponder: dict[str, Any] | None = None
    cached_engine_move: Any | None = None
    cached_engine_cycles: int | None = None
    cached_engine_note = ""
    ponder_stats = PonderStats(enabled=bool(args.ponder and args.c64_backend == "sim6502"))

    sim_runner_context = (
        create_sim6502_runner(args.repo_root, args.runner_target)
        if args.c64_backend == "sim6502"
        else None
    )
    try:
        if sim_runner_context is None:
            sim_runner = None
            context = None
        else:
            context = sim_runner_context
            sim_runner = context.__enter__()

        if engine_side == chess.BLACK:
            try:
                reply_uci, stats, best = colossus.go_first()
            except TimeoutError:
                termination = (
                    "colossus-forfeit-time"
                    if args.colossus_raw_force_move_after_seconds > 0
                    else "colossus-timeout"
                )
                adjudicated_result = "*"
                reply_uci = ""
            if reply_uci:
                move = legalize_from_to(board, reply_uci)
                if move is None:
                    termination = f"colossus-illegal-move:{reply_uci}"
                    adjudicated_result = "*"
                else:
                    note = f"raw-{args.colossus_profile}; go"
                    if best:
                        note += f"; best-line={best}"
                    last_colossus_best_line = best
                    append_move_record(board, records, move, engine_side, pending_cycles, note=note, colossus_stats=stats)
                    log_last_record(args, records)
                    write_progress_outputs(args, records, board, colossus.last_screen, ponder_stats)

        while len(records) < args.max_plies and not board.is_game_over(claim_draw=True):
            if adjudicated_result is not None:
                break
            if board.turn == engine_side:
                if forced_white_index < len(forced_white_moves):
                    if cached_engine_move is not None:
                        ponder_stats.unused += 1
                        cached_engine_move = None
                        cached_engine_cycles = None
                        cached_engine_note = ""
                    move_uci = forced_white_moves[forced_white_index]
                    forced_white_index += 1
                    move = chess.Move.from_uci(move_uci)
                    if move not in board.legal_moves:
                        raise RuntimeError(f"Forced white move {move_uci} is illegal for {board.fen()}")
                    append_move_record(
                        board,
                        records,
                        move,
                        engine_side,
                        pending_cycles,
                        note="forced-opening",
                    )
                    log_last_record(args, records)
                    write_progress_outputs(args, records, board, colossus.last_screen, ponder_stats)
                    continue

                if cached_engine_move is not None:
                    move = cached_engine_move
                    if move not in board.legal_moves:
                        raise RuntimeError(f"Cached ponder move {move.uci()} is illegal for {board.fen()}")
                    expected_ply = len(records) + 1
                    if cached_engine_cycles is not None:
                        pending_cycles[expected_ply] = cached_engine_cycles
                    append_move_record(
                        board,
                        records,
                        move,
                        engine_side,
                        pending_cycles,
                        note=cached_engine_note,
                    )
                    log_last_record(args, records)
                    write_progress_outputs(args, records, board, colossus.last_screen, ponder_stats)
                    pending_ponder = try_start_ponder(
                        args,
                        sim_runner,
                        board,
                        move.uci(),
                        last_colossus_best_line,
                        ponder_stats,
                    )
                    cached_engine_move = None
                    cached_engine_cycles = None
                    cached_engine_note = ""
                    continue

                position = ProbePosition(
                    name=f"colossus-raw-ply-{len(records) + 1}",
                    fen=board.fen(),
                    description="C64 AI move against raw Colossus",
                    category="colossus",
                    tags=["colossus", "raw"],
                )
                move_uci, cycles, _raw = run_c64_ai(
                    repo_root=args.repo_root,
                    image=args.sim6502_image,
                    pull=args.sim6502_pull,
                    position=position,
                    difficulty=args.difficulty,
                    timeout=args.c64_timeout,
                    book_enabled=False,
                    runner_target=args.runner_target,
                    c64_backend=args.c64_backend,
                    sim6502_runner=sim_runner,
                )
                if not move_uci:
                    raise RuntimeError(f"C64 AI returned no move for {board.fen()}")
                move = chess.Move.from_uci(move_uci)
                if move not in board.legal_moves:
                    raise RuntimeError(f"C64 AI returned illegal move {move_uci} for {board.fen()}")
                pending_cycles[len(records) + 1] = cycles
                append_move_record(board, records, move, engine_side, pending_cycles)
                log_last_record(args, records)
                write_progress_outputs(args, records, board, colossus.last_screen, ponder_stats)
                pending_ponder = try_start_ponder(
                    args,
                    sim_runner,
                    board,
                    move_uci,
                    last_colossus_best_line,
                    ponder_stats,
                )
                continue

            last_engine_move = records[-1].move
            target_ply = len(records) + 1
            move_number = board.fullmove_number
            try:
                reply_uci, stats, best, pending_ponder = colossus.reply(
                    last_engine_move,
                    move_number,
                    target_ply,
                    board=board,
                    sim_runner=sim_runner,
                    ponder_stats=ponder_stats,
                    pending_ponder=pending_ponder,
                )
            except TimeoutError:
                termination = (
                    "colossus-forfeit-time"
                    if args.colossus_raw_force_move_after_seconds > 0
                    else "colossus-timeout"
                )
                adjudicated_result = "*"
                break
            move = legalize_from_to(board, reply_uci)
            if move is None:
                termination = f"colossus-illegal-move:{reply_uci}"
                adjudicated_result = "*"
                break
            if pending_ponder is not None and sim_runner is not None:
                predicted_move = pending_ponder["move"]
                try:
                    use_response = sim_runner.ponder_use(
                        square_to_0x88(move.from_square),
                        square_to_0x88(move.to_square),
                    )
                    if (
                        use_response.get("accepted")
                        and move.from_square == predicted_move.from_square
                        and move.to_square == predicted_move.to_square
                    ):
                        board_after_colossus = board.copy(stack=False)
                        board_after_colossus.push(move)
                        cached_move = move_from_ponder_response(board_after_colossus, use_response)
                        if cached_move is not None:
                            cached_engine_move = cached_move
                            cached_engine_cycles = int(pending_ponder.get("cycles") or 0)
                            cached_engine_note = f"ponder-hit predicted={move.uci()}"
                            ponder_stats.hits += 1
                            ponder_stats.cycles_hit += cached_engine_cycles
                            log_progress(
                                args,
                                f"ponder hit on {move.uci()}, cached engine reply {cached_move.uci()}",
                            )
                        else:
                            ponder_stats.illegal_replies += 1
                            log_progress(args, f"ponder matched {move.uci()} but cached reply was illegal")
                    elif move.from_square == predicted_move.from_square and move.to_square == predicted_move.to_square:
                        ponder_stats.accept_failures += 1
                        log_progress(args, f"ponder matched {move.uci()} but produced no accepted reply")
                    else:
                        ponder_stats.misses += 1
                        log_progress(args, f"ponder miss predicted={predicted_move.uci()} actual={move.uci()}")
                except Exception as exc:
                    ponder_stats.use_errors += 1
                    log_progress(args, f"ponder use skipped after bridge error: {exc}")
                finally:
                    pending_ponder = None
            note = f"raw-{args.colossus_profile}"
            if best:
                note += f"; best-line={best}"
            last_colossus_best_line = best
            append_move_record(board, records, move, engine_side, pending_cycles, note=note, colossus_stats=stats)
            log_last_record(args, records)
            write_progress_outputs(args, records, board, colossus.last_screen, ponder_stats)
    finally:
        if sim_runner_context is not None:
            sim_runner_context.__exit__(None, None, None)

    result = adjudicated_result or board.result(claim_draw=True)
    if board.is_game_over(claim_draw=True):
        termination = "game-over"
    if pending_ponder is not None:
        ponder_stats.unused += 1
    pgn = pgn_for_match(args.start_fen, records, result, args.engine_color)
    return MatchResult(
        result=result,
        termination=termination,
        moves=records,
        pgn=pgn,
        final_fen=board.fen(),
        decoded_screen=colossus.last_screen,
        ponder=ponder_stats,
    )


def wait_for_engine_move_ack(
    args: argparse.Namespace,
    vice: ViceMCPClient,
    start_fen: str,
    target_plies: int,
    expected_move: Any,
) -> tuple[list[Any], str, bool]:
    deadline = time.monotonic() + args.input_timeout_seconds
    last_screen = ""
    last_moves: list[Any] = []
    last_warp_refresh = 0.0
    expected_uci = expected_move.uci()[:4]
    while time.monotonic() < deadline:
        now = time.monotonic()
        if now - last_warp_refresh > 5.0:
            set_warp(vice, args.warp_speed)
            last_warp_refresh = now
        last_screen = read_screen(vice)
        last_moves = parsed_screen_moves(start_fen, last_screen)
        if len(last_moves) >= target_plies:
            return last_moves, last_screen, False
        if screen_assumed_move(last_screen) == expected_uci:
            return last_moves, last_screen, True
        time.sleep(args.poll_seconds)
    raise TimeoutError(
        f"Colossus did not acknowledge engine move {expected_uci} within "
        f"{args.input_timeout_seconds:.1f}s; log plies={len(last_moves)}\n{last_screen}"
    )


def write_outputs(args: argparse.Namespace, result: MatchResult) -> None:
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(asdict(result), indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if args.pgn:
        args.pgn.parent.mkdir(parents=True, exist_ok=True)
        args.pgn.write_text(result.pgn + "\n", encoding="utf-8")


def run_match(args: argparse.Namespace) -> MatchResult:
    require_chess()
    if args.colossus_backend == "raw":
        return run_match_raw(args)

    if args.start_fen != chess.STARTING_FEN:
        raise SystemExit("Colossus board setup is not automated yet; use the normal starting FEN.")
    if args.engine_color != "white":
        raise SystemExit("Colossus side-switch automation is not wired yet; use --engine-color white.")
    missing = [path for path in runner_required_files(args.runner_target) if not (args.repo_root / path).exists()]
    if missing:
        raise SystemExit(f"Missing C64 runner files: {', '.join(missing)}. Run `make build` first.")

    vice = ViceMCPClient(args.vice_url)
    if args.boot:
        log_progress(args, "booting Colossus in VICE")
        decoded_screen = boot_colossus(args, vice)
        log_progress(args, "VICE Colossus board ready")
    else:
        set_warp(vice, args.warp_speed)
        decoded_screen = read_screen(vice)
    disable_colossus_prediction(vice)

    board = chess.Board(args.start_fen)
    engine_side = chess.WHITE if args.engine_color == "white" else chess.BLACK
    records: list[MatchMove] = []
    pending_cycles: dict[int, int] = {}

    sim_runner_context = (
        create_sim6502_runner(args.repo_root, args.runner_target)
        if args.c64_backend == "sim6502"
        else None
    )
    try:
        if sim_runner_context is None:
            sim_runner = None
            context = None
        else:
            context = sim_runner_context
            sim_runner = context.__enter__()

        while len(records) < args.max_plies and not board.is_game_over(claim_draw=True):
            previous_count = len(records)
            sync_visible_screen_moves(board, records, decoded_screen, engine_side, pending_cycles)
            log_new_records(args, records, previous_count)
            if board.is_game_over(claim_draw=True) or len(records) >= args.max_plies:
                break

            if board.turn == engine_side:
                position = ProbePosition(
                    name=f"colossus-ply-{len(records) + 1}",
                    fen=board.fen(),
                    description="C64 AI move against Colossus",
                    category="colossus",
                    tags=["colossus"],
                )
                try:
                    move_uci, cycles, _raw = run_c64_ai(
                        repo_root=args.repo_root,
                        image=args.sim6502_image,
                        pull=args.sim6502_pull,
                        position=position,
                        difficulty=args.difficulty,
                        timeout=args.c64_timeout,
                        book_enabled=False,
                        runner_target=args.runner_target,
                        c64_backend=args.c64_backend,
                        sim6502_runner=sim_runner,
                    )
                except RunnerError:
                    raise

                if not move_uci:
                    raise RuntimeError(f"C64 AI returned no move for {board.fen()}")
                move = chess.Move.from_uci(move_uci)
                if move not in board.legal_moves:
                    raise RuntimeError(f"C64 AI returned illegal move {move_uci} for {board.fen()}")

                expected_ply = len(records) + 1
                pending_cycles[expected_ply] = cycles
                disable_colossus_prediction(vice)
                log_progress(args, f"sending engine move {move_uci} for ply {expected_ply:02d}")
                decoded_screen = send_engine_move_with_ack(args, vice, move_uci, expected_ply)
                previous_count = len(records)
                sync_visible_screen_moves(board, records, decoded_screen, engine_side, pending_cycles)
                log_new_records(args, records, previous_count)
            else:
                log_progress(args, f"waiting for Colossus ply {len(records) + 1:02d}")
                decoded_screen = wait_for_visible_screen_ply(
                    args,
                    vice,
                    len(records) + 1,
                    args.colossus_timeout_seconds,
                )
                previous_count = len(records)
                sync_visible_screen_moves(board, records, decoded_screen, engine_side, pending_cycles)
                log_new_records(args, records, previous_count)
                if not board.is_game_over(claim_draw=True):
                    time.sleep(args.post_colossus_delay_seconds)
    finally:
        if sim_runner_context is not None:
            sim_runner_context.__exit__(None, None, None)

    result = board.result(claim_draw=True)
    termination = "game-over" if board.is_game_over(claim_draw=True) else "max-plies"
    pgn = pgn_for_match(args.start_fen, records, result, args.engine_color)
    return MatchResult(
        result=result,
        termination=termination,
        moves=records,
        pgn=pgn,
        final_fen=board.fen(),
        decoded_screen=decoded_screen,
    )


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vice-url", default=os.environ.get("VICE_MCP_URL", DEFAULT_VICE_MCP_URL))
    parser.add_argument("--d64", type=Path, default=Path(os.environ.get("COLOSSUS_D64", DEFAULT_D64)))
    parser.add_argument("--program-index", type=int, default=DEFAULT_PROGRAM_INDEX)
    parser.add_argument("--repo-root", type=Path, default=repo_root_from_script())
    parser.add_argument("--engine-color", choices=("white", "black"), default="white")
    parser.add_argument("--difficulty", choices=sorted(DIFFICULTY), default="hard")
    parser.add_argument("--runner-target", choices=sorted(RUNNER_TARGETS), default="headless")
    parser.add_argument("--c64-backend", choices=C64_BACKENDS, default="sim6502")
    parser.add_argument("--colossus-backend", choices=("vice", "raw"), default="vice")
    parser.add_argument("--colossus-profile", choices=sorted(COLOSSUS_RAW_PROFILES), default="match")
    parser.add_argument("--colossus-raw-runtime-dir", type=Path, default=DEFAULT_RAW_RUNTIME_DIR)
    parser.add_argument("--colossus-raw-output-dir", type=Path, default=Path("build") / "colossus_raw_match")
    parser.add_argument("--colossus-raw-runner", type=Path, default=DEFAULT_RAW_RUNNER_DLL)
    parser.add_argument("--colossus-raw-cycles", type=int, help="Raw Colossus cycle cap; 0 means run until reply.")
    parser.add_argument("--colossus-raw-tod-cycles-per-tick", type=int)
    parser.add_argument(
        "--colossus-raw-force-move-after-seconds",
        type=float,
        default=0.0,
        help="Raw backend safety stop: give Colossus this much host wall time to commit a move; no/illegal move is non-clean data.",
    )
    parser.add_argument(
        "--colossus-move-now-after-cycles",
        type=int,
        default=0,
        help="Raw backend per-move think budget in cycles; when exceeded, inject Colossus's own "
        "move-now command (M) so it commits its displayed best line. 0 disables.",
    )
    parser.add_argument("--colossus-raw-poll-steps", type=int, default=8192)
    parser.add_argument(
        "--colossus-raw-input",
        choices=("queued", "bulk"),
        default="queued",
        help="How raw Colossus receives moves: queued feeds the KERNAL buffer over time; bulk preloads it.",
    )
    parser.add_argument(
        "--colossus-raw-input-gap-cycles",
        type=int,
        default=250_000,
        help="Cycle spacing between queued raw keyboard-buffer bytes.",
    )
    parser.add_argument(
        "--colossus-raw-poke",
        action="append",
        default=[],
        help="Extra raw Colossus RAM patch, e.g. 0xb407=0x00. Profile pokes still apply.",
    )
    parser.add_argument(
        "--force-white-moves",
        nargs="*",
        default=[],
        help="Raw backend only: force these initial white UCI moves before handing white back to the engine.",
    )
    parser.add_argument("--sim6502-image", default=DEFAULT_IMAGE)
    parser.add_argument("--sim6502-pull", choices=("always", "missing", "never"), default=DEFAULT_PULL)
    parser.add_argument("--c64-timeout", type=int, default=750_000_000)
    parser.add_argument(
        "--ponder",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Use the headless ponder cache when Colossus best-line prediction provides a legal reply.",
    )
    parser.add_argument(
        "--ponder-timeout-cycles",
        type=int,
        default=5_000_000,
        help="Cycle cap for each speculative ponder search; use 0 for the normal C64 timeout.",
    )
    parser.add_argument(
        "--ponder-deep-min-lookahead",
        type=int,
        default=2,
        help="Live Colossus lookahead required before using the larger deep ponder timeout.",
    )
    parser.add_argument(
        "--ponder-deep-timeout-cycles",
        type=int,
        default=100_000_000,
        help="Cycle cap for live ponder candidates that survive to the deep lookahead tier.",
    )
    parser.add_argument("--start-fen", default=chess.STARTING_FEN if chess else None)
    parser.add_argument("--max-plies", type=int, default=20)
    parser.add_argument("--boot", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--warp-speed", type=int, default=10000)
    parser.add_argument("--boot-timeout-seconds", type=float, default=45.0)
    parser.add_argument("--input-timeout-seconds", type=float, default=20.0)
    parser.add_argument("--colossus-timeout-seconds", type=float, default=1800.0)
    parser.add_argument("--post-colossus-delay-seconds", type=float, default=2.5)
    parser.add_argument("--poll-seconds", type=float, default=1.0)
    parser.add_argument(
        "--move-input",
        choices=(
            "safe-petscii",
            "petscii",
            "safe-type",
            "type",
            "keypress",
            "keypress-shift",
            "matrix",
            "matrix-shift",
            "matrix-chord",
        ),
        default="type",
    )
    parser.add_argument("--move-hold-frames", type=int, default=5)
    parser.add_argument("--move-key-gap", type=float, default=0.08)
    parser.add_argument("--move-attempts", type=int, default=3)
    parser.add_argument("--progress", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--json", type=Path)
    parser.add_argument("--pgn", type=Path)
    args = parser.parse_args(argv)
    if args.ponder_timeout_cycles <= 0:
        args.ponder_timeout_cycles = args.c64_timeout
    if args.ponder_deep_timeout_cycles <= 0:
        args.ponder_deep_timeout_cycles = args.ponder_timeout_cycles
    args.ponder_deep_min_lookahead = max(1, args.ponder_deep_min_lookahead)
    return args


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    result = run_match(args)
    write_outputs(args, result)
    print(result.pgn)
    print(f"\nResult: {result.result} ({result.termination}), plies: {len(result.moves)}")
    for record in result.moves:
        details = []
        if record.c64_cycles is not None:
            details.append(f"c64_cycles={record.c64_cycles}")
        if record.colossus_positions is not None:
            details.append(f"colossus_positions={record.colossus_positions}")
        if record.colossus_lookahead is not None:
            details.append(f"lookahead={record.colossus_lookahead}")
        if record.colossus_wall_ms is not None:
            details.append(f"colossus_wall={record.colossus_wall_ms / 1000.0:.2f}s")
        if record.colossus_cycles_per_second is not None:
            details.append(f"colossus_sim={record.colossus_cycles_per_second:.0f} cyc/s")
        suffix = f" ({', '.join(details)})" if details else ""
        print(f"{record.ply:02d}. {record.actor:8s} {record.move:5s} {record.san}{suffix}")
    if args.json:
        print(f"JSON: {args.json}")
    if args.pgn:
        print(f"PGN: {args.pgn}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
