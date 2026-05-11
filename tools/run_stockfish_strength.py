#!/usr/bin/env python3
"""Compare the C64 AI's selected moves with a local Stockfish oracle.

This is an optional strength probe, not a replacement for the deterministic
sim6502 regression suite. It runs curated FEN positions through the C64 AI by
generating a temporary sim6502 suite, asks Stockfish for its preferred move and
evaluation, then reports move rank and approximate centipawn loss.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import asdict, dataclass, field
from pathlib import Path

try:
    import chess
except ImportError:  # pragma: no cover - exercised by environments without python-chess
    chess = None


DEFAULT_IMAGE = os.environ.get("SIM6502_IMAGE", "ghcr.io/barryw/sim6502:latest")
DEFAULT_PULL = os.environ.get("SIM6502_PULL", "always")
EMPTY_PIECE = 0x30
WHITE_COLOR = 0x80
WHITES_TURN = 0x01
BLACKS_TURN = 0x00
NO_EN_PASSANT = 0xFF

DIFFICULTY = {
    "easy": 0,
    "medium": 1,
    "hard": 2,
}

RUNNER_TARGETS = {
    "app": {
        "symbols": "/code/main.sym",
        "program": "/code/main.prg",
        "find_best_move": "FindBestMove",
        "required": ("main.sym", "main.prg"),
        "supports_book": True,
    },
    "headless": {
        "symbols": "/code/build/engine_harness.sym",
        "program": "/code/build/engine_harness.prg",
        "find_best_move": "ChessFindBestMove",
        "required": ("build/engine_harness.sym", "build/engine_harness.prg"),
        "supports_book": False,
    },
}

C64_BACKENDS = ("docker", "sim6502")

PIECE_TO_C64 = {
    "p": 0x31,
    "n": 0x32,
    "b": 0x33,
    "r": 0x34,
    "q": 0x35,
    "k": 0x36,
}

AI_RESULT_RE = re.compile(
    r"'(?P<name>[^']+)'\s+-\s+Expected\s+(?P<cycles>-?\d+)\s+==\s+(?P<encoded>\d+)\s+in assertion\s+'ai-result'"
)


@dataclass(frozen=True)
class ProbePosition:
    name: str
    fen: str
    description: str
    category: str = "general"
    tags: list[str] = field(default_factory=list)


@dataclass
class C64Position:
    board88: list[int]
    currentplayer: int
    whitekingsq: int
    blackkingsq: int
    castlerights: int
    enpassantsq: int
    halfmove_clock: int
    fullmove_number: int


@dataclass
class StockfishLine:
    move: str
    score: str
    score_cp: int
    depth: int
    pv: list[str]


@dataclass
class ProbeResult:
    name: str
    fen: str
    category: str
    tags: list[str]
    c64_move: str | None
    stockfish_best: str | None
    stockfish_best_score: int | None
    c64_score: int | None
    stockfish_rank: int | None
    centipawn_loss: int | None
    c64_cycles: int | None
    legal: bool
    passed: bool
    note: str


DEFAULT_POSITIONS = [
    ProbePosition(
        "mate-in-one-rh8",
        "k7/8/1K6/8/8/8/7R/8 w - - 0 1",
        "White should find Rh8#",
        "mate",
        ["mate", "rook", "endgame"],
    ),
    ProbePosition(
        "hanging-queen",
        "4k3/8/3q4/8/4N3/8/8/4K3 w - - 0 1",
        "White knight can take a loose black queen",
        "tactic",
        ["capture", "knight", "material"],
    ),
    ProbePosition(
        "promotion-queen",
        "k7/4P3/8/8/8/8/8/7K w - - 0 1",
        "White should promote the e-pawn",
        "promotion",
        ["promotion", "queen"],
    ),
]


class RunnerError(RuntimeError):
    pass


def require_chess() -> None:
    if chess is None:
        raise SystemExit("Missing dependency: python-chess. Install it with `python3 -m pip install chess`.")


def repo_root_from_script() -> Path:
    return Path(__file__).resolve().parents[1]


def hex_byte(value: int) -> str:
    return f"${value & 0xFF:02x}"


def safe_test_name(name: str) -> str:
    return re.sub(r"[^a-zA-Z0-9_-]+", "-", name).strip("-") or "position"


def normalize_sim_cycles(cycles: int) -> int:
    return cycles + (1 << 32) if cycles < 0 else cycles


def runner_required_files(runner_target: str) -> tuple[str, ...]:
    if runner_target not in RUNNER_TARGETS:
        raise ValueError(f"Unknown C64 runner target: {runner_target}")
    return tuple(RUNNER_TARGETS[runner_target]["required"])


def runner_local_path(repo_root: Path, runner_target: str, key: str) -> Path:
    target = RUNNER_TARGETS[runner_target]
    path = str(target[key])
    if path.startswith("/code/"):
        path = path[len("/code/") :]
    return repo_root / path


def create_sim6502_runner(repo_root: Path, runner_target: str):
    if runner_target != "headless":
        raise RunnerError("Persistent sim6502 backend currently supports --runner-target headless only.")
    from sim6502_headless_runner import Sim6502HeadlessRunner

    target = RUNNER_TARGETS[runner_target]
    return Sim6502HeadlessRunner(
        repo_root=repo_root,
        program_path=runner_local_path(repo_root, runner_target, "program"),
        symbols_path=runner_local_path(repo_root, runner_target, "symbols"),
        find_best_move=str(target["find_best_move"]),
    )


def square_to_0x88(square: int) -> int:
    return (7 - chess.square_rank(square)) * 16 + chess.square_file(square)


def square_from_0x88(index: int) -> int:
    return chess.square(index & 0x07, 7 - (index >> 4))


def fen_to_c64(fen: str) -> C64Position:
    require_chess()
    board = chess.Board(fen)
    board88 = [EMPTY_PIECE] * 128
    white_king = None
    black_king = None

    for square, piece in board.piece_map().items():
        base = PIECE_TO_C64[piece.symbol().lower()]
        value = base | (WHITE_COLOR if piece.color == chess.WHITE else 0)
        index = square_to_0x88(square)
        board88[index] = value
        if piece.piece_type == chess.KING:
            if piece.color == chess.WHITE:
                white_king = index
            else:
                black_king = index

    if white_king is None or black_king is None:
        raise ValueError(f"FEN must include both kings: {fen}")

    castling = 0
    if board.has_kingside_castling_rights(chess.WHITE):
        castling |= 0x01
    if board.has_queenside_castling_rights(chess.WHITE):
        castling |= 0x02
    if board.has_kingside_castling_rights(chess.BLACK):
        castling |= 0x04
    if board.has_queenside_castling_rights(chess.BLACK):
        castling |= 0x08

    ep_square = square_to_0x88(board.ep_square) if board.ep_square is not None else NO_EN_PASSANT
    return C64Position(
        board88=board88,
        currentplayer=WHITES_TURN if board.turn == chess.WHITE else BLACKS_TURN,
        whitekingsq=white_king,
        blackkingsq=black_king,
        castlerights=castling,
        enpassantsq=ep_square,
        halfmove_clock=min(board.halfmove_clock, 255),
        fullmove_number=min(board.fullmove_number, 65535),
    )


def c64_encoded_move_to_uci(fen: str, encoded: int) -> str | None:
    require_chess()
    board = chess.Board(fen)
    from_index = (encoded >> 8) & 0xFF
    to_raw = encoded & 0xFF
    if from_index == 0xFF or to_raw == 0xFF:
        return None
    if from_index & 0x88 or (to_raw & 0x7F) & 0x88:
        return None

    to_index = to_raw & 0x7F
    from_square = square_from_0x88(from_index)
    to_square = square_from_0x88(to_index)
    move = chess.square_name(from_square) + chess.square_name(to_square)

    piece = board.piece_at(from_square)
    if piece and piece.piece_type == chess.PAWN and chess.square_rank(to_square) in (0, 7):
        move += "n" if (to_raw & 0x80) else "q"
    return move


def build_sim6502_suite(
    position: ProbePosition,
    c64: C64Position,
    difficulty: str,
    timeout: int,
    book_enabled: bool = False,
    runner_target: str = "app",
) -> str:
    target = RUNNER_TARGETS[runner_target]
    white_pieces = [c64.whitekingsq] + [
        index
        for index, value in enumerate(c64.board88)
        if value != EMPTY_PIECE and (value & WHITE_COLOR) and index != c64.whitekingsq
    ]
    black_pieces = [c64.blackkingsq] + [
        index
        for index, value in enumerate(c64.board88)
        if value != EMPTY_PIECE and not (value & WHITE_COLOR) and index != c64.blackkingsq
    ]

    lines = [
        "suites {",
        '  suite("Stockfish Strength Probe") {',
        f'    symbols("{target["symbols"]}")',
        f'    load("{target["program"]}", strip_header = true)',
        "",
        f'    test("{safe_test_name(position.name)}", "{position.description}", timeout = {timeout}) {{',
        "      jsr([InitZobristTables], stop_on_rts = true, fail_on_brk = true)",
        "      jsr([TTClear], stop_on_rts = true, fail_on_brk = true)",
    ]
    if target["supports_book"]:
        lines.extend(
            [
                "      jsr([ResetBookState], stop_on_rts = true, fail_on_brk = true)",
                f"      jsr([{'EnableBook' if book_enabled else 'DisableBook'}], stop_on_rts = true, fail_on_brk = true)",
            ]
        )
    lines.extend(
        [
            "",
            "      memfill([Board88], 128, $30)",
        ]
    )

    for index, value in enumerate(c64.board88):
        if value != EMPTY_PIECE:
            lines.append(f"      [Board88] + {hex_byte(index)} = {hex_byte(value)}")

    lines.extend(
        [
            "",
            "      memfill([WhitePieceList], 16, $ff)",
            "      memfill([BlackPieceList], 16, $ff)",
        ]
    )
    for index, square in enumerate(white_pieces):
        lines.append(f"      [WhitePieceList] + {hex_byte(index)} = {hex_byte(square)}")
    for index, square in enumerate(black_pieces):
        lines.append(f"      [BlackPieceList] + {hex_byte(index)} = {hex_byte(square)}")

    fullmove_lo = c64.fullmove_number & 0xFF
    fullmove_hi = (c64.fullmove_number >> 8) & 0xFF
    lines.extend(
        [
            "",
            f"      [currentplayer] = {hex_byte(c64.currentplayer)}",
            f"      [difficulty] = {hex_byte(DIFFICULTY[difficulty])}",
            f"      [whitekingsq] = {hex_byte(c64.whitekingsq)}",
            f"      [blackkingsq] = {hex_byte(c64.blackkingsq)}",
            f"      [castlerights] = {hex_byte(c64.castlerights)}",
            f"      [enpassantsq] = {hex_byte(c64.enpassantsq)}",
            f"      [HalfmoveClock] = {hex_byte(c64.halfmove_clock)}",
            f"      [FullmoveNumber] = {hex_byte(fullmove_lo)}",
            f"      [FullmoveNumber] + 1 = {hex_byte(fullmove_hi)}",
            "      [HistoryCount] = $00",
            f"      [WhitePieceCount] = {hex_byte(len(white_pieces))}",
            f"      [BlackPieceCount] = {hex_byte(len(black_pieces))}",
            "      [promotionsq] = $ff",
            "      [BestMoveFrom] = $ff",
            "      [BestMoveTo] = $ff",
            "",
            f"      jsr([{target['find_best_move']}], stop_on_rts = true, fail_on_brk = true)",
            "",
            '      assert(peekbyte([SearchDepth]) == $00, "SearchDepth should return to zero")',
            '      assert(cycles == ((peekbyte([BestMoveFrom]) * 256) + peekbyte([BestMoveTo])), "ai-result")',
            "    }",
            "  }",
            "}",
        ]
    )
    return "\n".join(lines) + "\n"


def run_c64_ai(
    repo_root: Path,
    image: str,
    pull: str,
    position: ProbePosition,
    difficulty: str,
    timeout: int,
    book_enabled: bool = False,
    runner_target: str = "app",
    c64_backend: str = "docker",
    sim6502_runner: object | None = None,
) -> tuple[str | None, int, str]:
    if c64_backend == "sim6502":
        if book_enabled:
            raise RunnerError("Persistent sim6502 backend does not support the C64 app opening book toggle.")
        c64 = fen_to_c64(position.fen)
        try:
            if sim6502_runner is None:
                with create_sim6502_runner(repo_root, runner_target) as runner:
                    response = runner.best_move(c64, DIFFICULTY[difficulty], timeout)
            else:
                response = sim6502_runner.best_move(c64, DIFFICULTY[difficulty], timeout)
        except Exception as exc:
            raise RunnerError(f"Persistent sim6502 failed for {position.name}: {exc}") from exc

        encoded = int(response["encoded"])
        cycles = int(response["cycles"])
        return c64_encoded_move_to_uci(position.fen, encoded), cycles, json.dumps(response, sort_keys=True)

    if c64_backend != "docker":
        raise RunnerError(f"Unknown C64 backend: {c64_backend}")

    c64 = fen_to_c64(position.fen)
    suite = build_sim6502_suite(
        position,
        c64,
        difficulty,
        timeout,
        book_enabled=book_enabled,
        runner_target=runner_target,
    )
    with tempfile.TemporaryDirectory(prefix="chess-stockfish-probe-") as temp:
        suite_path = Path(temp) / "stockfish_strength.6502"
        suite_path.write_text(suite, encoding="utf-8")
        cmd = [
            "docker",
            "run",
            f"--pull={pull}",
            "--rm",
            "-v",
            f"{repo_root}:/code",
            "-v",
            f"{temp}:/bench",
            image,
            "-s",
            "/bench/stockfish_strength.6502",
        ]
        result = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    match = AI_RESULT_RE.search(result.stdout)
    if not match:
        raise RunnerError(f"Could not extract C64 AI move for {position.name}.\n\n{result.stdout}")

    encoded = int(match.group("encoded"))
    cycles = normalize_sim_cycles(int(match.group("cycles")))
    return c64_encoded_move_to_uci(position.fen, encoded), cycles, result.stdout


def score_to_cp(score_kind: str, value: int) -> int:
    if score_kind == "cp":
        return value
    if value > 0:
        return 100000 - abs(value)
    return -100000 + abs(value)


class Stockfish:
    def __init__(self, path: str, hash_mb: int = 16) -> None:
        self.proc = subprocess.Popen(
            [path],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        self._send("uci")
        self.identity = stockfish_identity_from_uci(self._read_until("uciok"))
        self.set_option("Threads", "1")
        self.set_option("Hash", str(hash_mb))
        self.is_ready()

    def close(self) -> None:
        if self.proc.poll() is None:
            self._send("quit")
            try:
                self.proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.proc.kill()

    def new_game(self) -> None:
        self._send("ucinewgame")
        self.is_ready()

    def _send(self, command: str) -> None:
        assert self.proc.stdin is not None
        self.proc.stdin.write(command + "\n")
        self.proc.stdin.flush()

    def _readline(self) -> str:
        assert self.proc.stdout is not None
        line = self.proc.stdout.readline()
        if line == "":
            raise RunnerError("Stockfish exited unexpectedly")
        return line.strip()

    def _read_until(self, token: str) -> list[str]:
        lines = []
        while True:
            line = self._readline()
            lines.append(line)
            if line == token or line.startswith(token + " "):
                return lines

    def set_option(self, name: str, value: str) -> None:
        self._send(f"setoption name {name} value {value}")

    def is_ready(self) -> None:
        self._send("isready")
        self._read_until("readyok")

    def analyze(
        self,
        fen: str,
        depth: int | None = None,
        multipv: int = 1,
        moves: list[str] | None = None,
        movetime_ms: int | None = None,
    ) -> list[StockfishLine]:
        if depth is None and movetime_ms is None:
            raise ValueError("Stockfish analyze requires depth or movetime_ms")
        self.set_option("MultiPV", str(max(1, multipv)))
        self.is_ready()
        move_suffix = ""
        if moves:
            move_suffix = " moves " + " ".join(moves)
        self._send(f"position fen {fen}{move_suffix}")
        if movetime_ms is not None:
            self._send(f"go movetime {movetime_ms}")
        else:
            self._send(f"go depth {depth}")

        latest: dict[int, StockfishLine] = {}
        while True:
            line = self._readline()
            if line.startswith("bestmove"):
                break
            parsed = parse_stockfish_info(line)
            if parsed:
                latest[parsed[0]] = parsed[1]

        return [latest[key] for key in sorted(latest)]


def stockfish_identity_from_uci(lines: list[str]) -> str:
    for line in lines:
        if line.startswith("id name "):
            return line[len("id name ") :]
    for line in lines:
        if line.startswith("Stockfish "):
            return line
    return "unknown"


def stockfish_identity_for_path(path: str) -> str:
    try:
        proc = subprocess.Popen(
            [path],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        stdout, _ = proc.communicate("uci\nquit\n", timeout=5)
    except Exception:
        return "unknown"
    lines = [line.strip() for line in stdout.splitlines() if line.strip()]
    return stockfish_identity_from_uci(lines)


def parse_stockfish_info(line: str) -> tuple[int, StockfishLine] | None:
    if not line.startswith("info "):
        return None
    tokens = line.split()
    if "score" not in tokens or "pv" not in tokens:
        return None

    depth = int(tokens[tokens.index("depth") + 1]) if "depth" in tokens else 0
    multipv = int(tokens[tokens.index("multipv") + 1]) if "multipv" in tokens else 1
    score_index = tokens.index("score")
    score_kind = tokens[score_index + 1]
    score_value = int(tokens[score_index + 2])
    pv = tokens[tokens.index("pv") + 1 :]
    if not pv:
        return None

    score_text = f"mate {score_value}" if score_kind == "mate" else f"cp {score_value}"
    return multipv, StockfishLine(
        move=pv[0],
        score=score_text,
        score_cp=score_to_cp(score_kind, score_value),
        depth=depth,
        pv=pv,
    )


@dataclass
class StrengthWorkerResources:
    stockfish: Stockfish
    sim6502_runner: object | None

    def close(self) -> None:
        if self.sim6502_runner is not None:
            self.sim6502_runner.close()
        self.stockfish.close()


class StrengthWorkerPool:
    """Thread-local Stockfish and sim6502 processes for corpus probes."""

    def __init__(self, args: argparse.Namespace, repo_root: Path) -> None:
        self.args = args
        self.repo_root = repo_root
        self._local = threading.local()
        self._lock = threading.Lock()
        self._workers: list[StrengthWorkerResources] = []

    def get(self) -> StrengthWorkerResources:
        worker = getattr(self._local, "worker", None)
        if worker is not None:
            return worker

        stockfish = Stockfish(self.args.stockfish_path)
        sim6502_runner = None
        if self.args.c64_backend == "sim6502":
            sim6502_runner = create_sim6502_runner(self.repo_root, self.args.runner_target)
            sim6502_runner.start()

        worker = StrengthWorkerResources(stockfish=stockfish, sim6502_runner=sim6502_runner)
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


def result_metrics(results: list[ProbeResult]) -> dict[str, object]:
    total = len(results)
    legal = sum(1 for result in results if result.legal)
    passed = sum(1 for result in results if result.passed)
    top1 = sum(1 for result in results if result.stockfish_rank == 1)
    top3 = sum(1 for result in results if result.stockfish_rank is not None and result.stockfish_rank <= 3)
    losses = [result.centipawn_loss for result in results if result.centipawn_loss is not None]
    cycles = [result.c64_cycles for result in results if result.c64_cycles is not None]
    return {
        "positions": total,
        "passed": passed,
        "legal": legal,
        "top1": top1,
        "top3": top3,
        "top1_rate": top1 / total if total else 0.0,
        "top3_rate": top3 / total if total else 0.0,
        "legal_rate": legal / total if total else 0.0,
        "total_centipawn_loss": sum(losses),
        "average_centipawn_loss": (sum(losses) / len(losses)) if losses else None,
        "max_centipawn_loss": max(losses) if losses else None,
        "average_cycles": (sum(cycles) / len(cycles)) if cycles else None,
        "max_cycles": max(cycles) if cycles else None,
    }


def category_metrics(results: list[ProbeResult]) -> dict[str, dict[str, object]]:
    categories = sorted({result.category for result in results})
    return {
        category: result_metrics([result for result in results if result.category == category])
        for category in categories
    }


def format_rate(metrics: dict[str, object], key: str) -> str:
    return f"{float(metrics[key]) * 100:.0f}%"


def format_optional_number(value: object) -> str:
    if value is None:
        return "-"
    if isinstance(value, float):
        return f"{value:,.1f}"
    if isinstance(value, int):
        return f"{value:,}"
    return str(value)


def evaluate_position(
    stockfish: Stockfish,
    position: ProbePosition,
    c64_move: str | None,
    depth: int,
    multipv: int,
    difficulty: str,
    repo_root: Path,
    image: str,
    pull: str,
    runner_target: str,
    c64_backend: str,
    sim6502_runner: object | None,
    timeout: int,
    require_top_n: int,
    max_centipawn_loss: int | None,
) -> ProbeResult:
    lines = stockfish.analyze(position.fen, depth=depth, multipv=multipv)
    best = lines[0] if lines else None
    stockfish_best = best.move if best else None
    best_score = best.score_cp if best else None

    legal = False
    rank = None
    loss = None
    c64_score = None
    note = ""
    cycles = None

    try:
        c64_move, cycles, _ = run_c64_ai(
            repo_root,
            image,
            pull,
            position,
            difficulty,
            timeout,
            runner_target=runner_target,
            c64_backend=c64_backend,
            sim6502_runner=sim6502_runner,
        )
    except RunnerError as exc:
        return ProbeResult(
            name=position.name,
            fen=position.fen,
            category=position.category,
            tags=position.tags,
            c64_move=None,
            stockfish_best=stockfish_best,
            stockfish_best_score=best_score,
            c64_score=None,
            stockfish_rank=None,
            centipawn_loss=None,
            c64_cycles=None,
            legal=False,
            passed=False,
            note=str(exc).splitlines()[0],
        )

    board = chess.Board(position.fen)
    if c64_move is None:
        note = "C64 AI did not return a move"
    else:
        try:
            move = chess.Move.from_uci(c64_move)
            legal = move in board.legal_moves
        except ValueError:
            legal = False
        if not legal:
            note = "C64 AI returned an illegal move"

    if legal and c64_move:
        for index, line in enumerate(lines, start=1):
            if line.move == c64_move:
                rank = index
                c64_score = line.score_cp
                loss = max(0, (best_score or 0) - line.score_cp)
                break

        if loss is None and best_score is not None:
            reply_lines = stockfish.analyze(position.fen, depth=depth, multipv=1, moves=[c64_move])
            if reply_lines:
                c64_score = -reply_lines[0].score_cp
                loss = max(0, best_score - c64_score)

    passed = legal
    if passed and require_top_n > 0:
        passed = rank is not None and rank <= require_top_n
        if not passed and not note:
            note = f"outside Stockfish top {require_top_n}"
    if passed and max_centipawn_loss is not None:
        passed = loss is not None and loss <= max_centipawn_loss
        if not passed and not note:
            note = f"centipawn loss exceeds {max_centipawn_loss}"
    if passed and not note:
        note = "ok"

    return ProbeResult(
        name=position.name,
        fen=position.fen,
        category=position.category,
        tags=position.tags,
        c64_move=c64_move,
        stockfish_best=stockfish_best,
        stockfish_best_score=best_score,
        c64_score=c64_score,
        stockfish_rank=rank,
        centipawn_loss=loss,
        c64_cycles=cycles,
        legal=legal,
        passed=passed,
        note=note,
    )


def evaluate_position_with_worker(
    args: argparse.Namespace,
    repo_root: Path,
    pool: StrengthWorkerPool,
    position: ProbePosition,
) -> tuple[ProbeResult, float]:
    worker = pool.get()
    started = time.monotonic()
    worker.stockfish.new_game()
    result = evaluate_position(
        stockfish=worker.stockfish,
        position=position,
        c64_move=None,
        depth=args.stockfish_depth,
        multipv=args.multipv,
        difficulty=args.difficulty,
        repo_root=repo_root,
        image=args.sim_image,
        pull=args.sim_pull,
        runner_target=args.runner_target,
        c64_backend=args.c64_backend,
        sim6502_runner=worker.sim6502_runner,
        timeout=args.timeout_cycles,
        require_top_n=args.require_top_n,
        max_centipawn_loss=args.max_centipawn_loss,
    )
    return result, time.monotonic() - started


def print_summary(results: list[ProbeResult], difficulty: str, depth: int, multipv: int) -> None:
    passed = sum(1 for result in results if result.passed)
    print(f"Stockfish strength probe: {passed}/{len(results)} passed")
    print(f"  difficulty={difficulty} stockfish_depth={depth} multipv={multipv}")
    overall = result_metrics(results)
    print(
        "  "
        f"legal={overall['legal']}/{overall['positions']} "
        f"top1={overall['top1']}/{overall['positions']} ({format_rate(overall, 'top1_rate')}) "
        f"top3={overall['top3']}/{overall['positions']} ({format_rate(overall, 'top3_rate')}) "
        f"avg_loss={format_optional_number(overall['average_centipawn_loss'])} "
        f"max_loss={format_optional_number(overall['max_centipawn_loss'])} "
        f"avg_cycles={format_optional_number(overall['average_cycles'])}"
    )

    for result in results:
        rank = "-" if result.stockfish_rank is None else str(result.stockfish_rank)
        loss = "-" if result.centipawn_loss is None else str(result.centipawn_loss)
        cycles = "-" if result.c64_cycles is None else f"{result.c64_cycles:,}"
        status = "PASSED" if result.passed else "FAILED"
        print(
            f"  {status:6} {result.name:22} "
            f"c64={result.c64_move or '-':7} sf={result.stockfish_best or '-':7} "
            f"rank={rank:>2} loss={loss:>6} cycles={cycles:>10} "
            f"cat={result.category:10} {result.note}"
        )

    by_category = category_metrics(results)
    if len(by_category) > 1:
        print("  Category metrics:")
        for category, metrics in by_category.items():
            print(
                f"    {category:10} "
                f"n={metrics['positions']:>2} "
                f"top1={metrics['top1']:>2} "
                f"top3={metrics['top3']:>2} "
                f"avg_loss={format_optional_number(metrics['average_centipawn_loss']):>6} "
                f"max_loss={format_optional_number(metrics['max_centipawn_loss']):>6}"
            )


def load_positions(args: argparse.Namespace) -> list[ProbePosition]:
    positions = []
    if args.include_defaults or not args.corpus:
        positions.extend(DEFAULT_POSITIONS)
    for corpus in args.corpus or []:
        positions.extend(load_corpus(corpus))
    for index, fen in enumerate(args.fen or [], start=1):
        positions.append(ProbePosition(f"custom-{index}", fen, "custom FEN"))
    if args.only:
        wanted = set(args.only)
        positions = [position for position in positions if position.name in wanted]
    if args.category:
        wanted_categories = set(args.category)
        positions = [position for position in positions if position.category in wanted_categories]
    if args.tag:
        wanted_tags = set(args.tag)
        positions = [position for position in positions if wanted_tags.intersection(position.tags)]
    return positions


def load_corpus(path: Path) -> list[ProbePosition]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    items = raw.get("positions", raw) if isinstance(raw, dict) else raw
    if not isinstance(items, list):
        raise ValueError(f"Corpus must be a list or object with a positions list: {path}")

    positions = []
    for index, item in enumerate(items, start=1):
        if not isinstance(item, dict):
            raise ValueError(f"Corpus entry {index} must be an object")
        name = str(item.get("name") or f"{path.stem}-{index}")
        fen = item.get("fen")
        if not fen:
            raise ValueError(f"Corpus entry {name} is missing fen")
        board = chess.Board(str(fen))
        if not board.is_valid():
            raise ValueError(f"Corpus entry {name} is not a valid chess position: {fen}")
        tags = item.get("tags") or []
        if isinstance(tags, str):
            tags = [tags]
        positions.append(
            ProbePosition(
                name=name,
                fen=str(fen),
                description=str(item.get("description") or name),
                category=str(item.get("category") or "general"),
                tags=[str(tag) for tag in tags],
            )
        )
    return positions


def run_self_test() -> int:
    require_chess()
    start = fen_to_c64(chess.STARTING_FEN)
    assert start.board88[0x00] == 0x34, "a8 should hold a black rook"
    assert start.board88[0x04] == 0x36, "e8 should hold a black king"
    assert start.board88[0x74] == 0xB6, "e1 should hold a white king"
    assert start.castlerights == 0x0F, "starting FEN should preserve all castling rights"
    assert start.enpassantsq == 0xFF, "starting FEN has no en passant square"
    assert start.currentplayer == WHITES_TURN, "white to move in starting FEN"
    promotion_fen = "k7/4P3/8/8/8/8/8/7K w - - 0 1"
    assert c64_encoded_move_to_uci(promotion_fen, 0x1404) == "e7e8q"
    assert c64_encoded_move_to_uci(promotion_fen, 0x1484) == "e7e8n"
    signed_cycle_output = "'debug' - Expected -2041243897 == 1345 in assertion 'ai-result'"
    match = AI_RESULT_RE.search(signed_cycle_output)
    assert match, "AI result parser should accept signed 32-bit cycle counts"
    assert normalize_sim_cycles(int(match.group("cycles"))) == 2253723399
    assert int(match.group("encoded")) == 1345
    print("Self-test passed.")
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Compare C64 AI moves against local Stockfish.")
    parser.add_argument("--repo-root", type=Path, default=repo_root_from_script())
    parser.add_argument("--stockfish-path", default=os.environ.get("STOCKFISH_PATH") or shutil.which("stockfish"))
    parser.add_argument("--sim-image", default=DEFAULT_IMAGE)
    parser.add_argument("--sim-pull", choices=["always", "missing", "never"], default=DEFAULT_PULL)
    parser.add_argument("--runner-target", choices=sorted(RUNNER_TARGETS), default="headless")
    parser.add_argument("--c64-backend", choices=C64_BACKENDS, default="sim6502")
    parser.add_argument("--difficulty", choices=sorted(DIFFICULTY), default="hard")
    parser.add_argument("--stockfish-depth", type=int, default=8)
    parser.add_argument("--multipv", type=int, default=3)
    parser.add_argument("--jobs", type=int, default=1, help="Run independent corpus probes in parallel.")
    parser.add_argument("--timeout-cycles", type=int, default=30_000_000)
    parser.add_argument("--corpus", action="append", type=Path, help="JSON corpus file to load. Can be provided multiple times.")
    parser.add_argument("--include-defaults", action="store_true", help="Include built-in starter positions along with corpus files.")
    parser.add_argument("--require-top-n", type=int, default=0, help="Fail positions outside Stockfish top N. 0 disables this gate.")
    parser.add_argument("--max-centipawn-loss", type=int, default=None, help="Fail positions above this centipawn loss.")
    parser.add_argument("--max-average-loss", type=float, default=None, help="Fail when average centipawn loss is above this value.")
    parser.add_argument("--max-average-cycles", type=float, default=None, help="Fail when average C64 cycles are above this value.")
    parser.add_argument("--max-cycles", type=int, default=None, help="Fail when any C64 move exceeds this cycle count.")
    parser.add_argument("--min-top1-rate", type=float, default=None, help="Fail when top-1 rate is below this fraction, e.g. 0.5.")
    parser.add_argument("--fen", action="append", help="Additional FEN to probe. Can be provided multiple times.")
    parser.add_argument("--only", action="append", help="Only run a named built-in position. Can be provided multiple times.")
    parser.add_argument("--category", action="append", help="Only run positions in this category. Can be provided multiple times.")
    parser.add_argument("--tag", action="append", help="Only run positions with this tag. Can be provided multiple times.")
    parser.add_argument("--list-positions", action="store_true")
    parser.add_argument("--json", type=Path, default=None)
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        return run_self_test()
    if args.jobs < 1:
        raise SystemExit("--jobs must be >= 1")

    require_chess()
    repo_root = args.repo_root.resolve()
    for required_name in runner_required_files(args.runner_target):
        required = repo_root / required_name
        if not required.exists():
            target = "make engine-build" if args.runner_target == "headless" else "make build"
            print(f"Missing required file: {required}. Run `{target}` first.", file=sys.stderr)
            return 2

    positions = load_positions(args)
    if args.list_positions:
        for position in positions:
            print(f"{position.name}: {position.fen}  # {position.description}")
        return 0
    if not positions:
        print("No positions selected.", file=sys.stderr)
        return 2
    if not args.stockfish_path:
        print("Could not find Stockfish. Set STOCKFISH_PATH or pass --stockfish-path.", file=sys.stderr)
        return 2
    args.stockfish_identity = stockfish_identity_for_path(args.stockfish_path)

    if args.jobs > 1:
        worker_pool = StrengthWorkerPool(args, repo_root)
        executor = ThreadPoolExecutor(max_workers=args.jobs)
        indexed_results: list[tuple[int, ProbeResult]] = []
        try:
            futures = {
                executor.submit(evaluate_position_with_worker, args, repo_root, worker_pool, position): (index, position)
                for index, position in enumerate(positions)
            }
            for future in as_completed(futures):
                index, position = futures[future]
                result, elapsed = future.result()
                indexed_results.append((index, result))
                print(
                    f"position={position.name} status={'passed' if result.passed else 'failed'} "
                    f"loss={result.centipawn_loss if result.centipawn_loss is not None else '-'} "
                    f"elapsed={elapsed:.1f}s",
                    flush=True,
                )
        finally:
            executor.shutdown(wait=True)
            worker_pool.close()
        results = [result for _, result in sorted(indexed_results)]
    else:
        stockfish = Stockfish(args.stockfish_path)
        sim6502_runner = None
        try:
            if args.c64_backend == "sim6502":
                sim6502_runner = create_sim6502_runner(repo_root, args.runner_target)
                sim6502_runner.start()
            results = [
                evaluate_position(
                    stockfish=stockfish,
                    position=position,
                    c64_move=None,
                    depth=args.stockfish_depth,
                    multipv=args.multipv,
                    difficulty=args.difficulty,
                    repo_root=repo_root,
                    image=args.sim_image,
                    pull=args.sim_pull,
                    runner_target=args.runner_target,
                    c64_backend=args.c64_backend,
                    sim6502_runner=sim6502_runner,
                    timeout=args.timeout_cycles,
                    require_top_n=args.require_top_n,
                    max_centipawn_loss=args.max_centipawn_loss,
                )
                for position in positions
            ]
        finally:
            if sim6502_runner is not None:
                sim6502_runner.close()
            stockfish.close()

    print_summary(results, args.difficulty, args.stockfish_depth, args.multipv)
    if args.json:
        overall = result_metrics(results)
        payload = {
            "stockfish_path": args.stockfish_path,
            "stockfish_identity": args.stockfish_identity,
            "sim_image": args.sim_image,
            "runner_target": args.runner_target,
            "c64_backend": args.c64_backend,
            "difficulty": args.difficulty,
            "stockfish_depth": args.stockfish_depth,
            "multipv": args.multipv,
            "summary": overall,
            "categories": category_metrics(results),
            "results": [asdict(result) for result in results],
        }
        args.json.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    overall = result_metrics(results)
    if not all(result.passed for result in results):
        return 1
    if args.max_average_loss is not None:
        average_loss = overall["average_centipawn_loss"]
        if average_loss is None or float(average_loss) > args.max_average_loss:
            return 1
    if args.max_average_cycles is not None:
        average_cycles = overall["average_cycles"]
        if average_cycles is None or float(average_cycles) > args.max_average_cycles:
            return 1
    if args.max_cycles is not None:
        max_cycles = overall["max_cycles"]
        if max_cycles is None or int(max_cycles) > args.max_cycles:
            return 1
    if args.min_top1_rate is not None and float(overall["top1_rate"]) < args.min_top1_rate:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
