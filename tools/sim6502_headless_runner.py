#!/usr/bin/env python3
"""Persistent sim6502 runner for the reusable headless chess engine."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any


class Sim6502BridgeError(RuntimeError):
    pass


class Sim6502HeadlessRunner:
    def __init__(
        self,
        *,
        repo_root: Path,
        program_path: Path | None = None,
        symbols_path: Path | None = None,
        find_best_move: str = "ChessFindBestMove",
        dotnet: str = "dotnet",
        configuration: str = "Release",
    ) -> None:
        self.repo_root = repo_root.resolve()
        self.program_path = program_path or (self.repo_root / "build" / "engine_harness.prg")
        self.symbols_path = symbols_path or (self.repo_root / "build" / "engine_harness.sym")
        self.find_best_move = find_best_move
        self.dotnet = dotnet
        self.configuration = configuration
        self.sim6502_output_dir = Path(
            os.environ.get("SIM6502_OUTPUT_DIR")
            or os.environ.get("Sim6502OutputDir")
            or Path.home() / "Git" / "sim6502" / "sim6502" / "bin" / "Release" / "net10.0"
        )
        self.sim6502_runner_dll = self.sim6502_output_dir / "Sim6502TestRunner.dll"
        self.project_path = self.repo_root / "tools" / "Sim6502HeadlessBridge" / "Sim6502HeadlessBridge.csproj"
        self.bridge_dll = (
            self.repo_root
            / "tools"
            / "Sim6502HeadlessBridge"
            / "bin"
            / configuration
            / "net10.0"
            / "Sim6502HeadlessBridge.dll"
        )
        self.proc: subprocess.Popen[str] | None = None
        self._next_id = 1

    def __enter__(self) -> "Sim6502HeadlessRunner":
        self.start()
        return self

    def __exit__(self, exc_type: object, exc: object, tb: object) -> None:
        self.close()

    def start(self) -> None:
        if self.proc is not None and self.proc.poll() is None:
            return
        self._ensure_built()
        for path in (self.program_path, self.symbols_path):
            if not path.exists():
                raise Sim6502BridgeError(f"Missing required file: {path}")

        cmd = [
            self.dotnet,
            str(self.bridge_dll),
            "--program",
            str(self.program_path),
            "--symbols",
            str(self.symbols_path),
            "--find-best-move",
            self.find_best_move,
        ]
        self.proc = subprocess.Popen(
            cmd,
            cwd=self.repo_root,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        ready = self._read_response()
        if not ready.get("ready"):
            raise Sim6502BridgeError(f"sim6502 bridge did not become ready: {ready}")

    def close(self) -> None:
        if self.proc is None:
            return
        if self.proc.poll() is None:
            try:
                self._send({"id": self._next_id, "command": "quit"})
                self._next_id += 1
                self.proc.wait(timeout=2)
            except Exception:
                self.proc.kill()
        self.proc = None

    def best_move(self, c64_position: object, difficulty: int, timeout_cycles: int) -> dict[str, Any]:
        self.start()
        assert self.proc is not None
        request_id = self._next_id
        self._next_id += 1
        request = {
            "id": request_id,
            "command": "bestmove",
            "board88": list(getattr(c64_position, "board88")),
            "currentplayer": int(getattr(c64_position, "currentplayer")),
            "whitekingsq": int(getattr(c64_position, "whitekingsq")),
            "blackkingsq": int(getattr(c64_position, "blackkingsq")),
            "castlerights": int(getattr(c64_position, "castlerights")),
            "enpassantsq": int(getattr(c64_position, "enpassantsq")),
            "halfmoveClock": int(getattr(c64_position, "halfmove_clock")),
            "fullmoveNumber": int(getattr(c64_position, "fullmove_number")),
            "difficulty": int(difficulty),
            "timeoutCycles": int(timeout_cycles),
        }
        self._send(request)
        response = self._read_response()
        if response.get("id") != request_id:
            raise Sim6502BridgeError(f"sim6502 bridge response id mismatch: {response}")
        if not response.get("ok"):
            raise Sim6502BridgeError(json.dumps(response, sort_keys=True))
        return response

    def ponder_search(
        self,
        c64_position: object,
        difficulty: int,
        timeout_cycles: int,
        predicted_from: int,
        predicted_to: int,
    ) -> dict[str, Any]:
        self.start()
        request_id = self._next_id
        self._next_id += 1
        request = {
            "id": request_id,
            "command": "ponder",
            "board88": list(getattr(c64_position, "board88")),
            "currentplayer": int(getattr(c64_position, "currentplayer")),
            "whitekingsq": int(getattr(c64_position, "whitekingsq")),
            "blackkingsq": int(getattr(c64_position, "blackkingsq")),
            "castlerights": int(getattr(c64_position, "castlerights")),
            "enpassantsq": int(getattr(c64_position, "enpassantsq")),
            "halfmoveClock": int(getattr(c64_position, "halfmove_clock")),
            "fullmoveNumber": int(getattr(c64_position, "fullmove_number")),
            "difficulty": int(difficulty),
            "timeoutCycles": int(timeout_cycles),
            "predictedFrom": int(predicted_from) & 0xFF,
            "predictedTo": int(predicted_to) & 0xFF,
        }
        self._send(request)
        response = self._read_response()
        if response.get("id") != request_id:
            raise Sim6502BridgeError(f"sim6502 bridge response id mismatch: {response}")
        if not response.get("ok"):
            raise Sim6502BridgeError(json.dumps(response, sort_keys=True))
        return response

    def ponder_use(self, actual_from: int, actual_to: int, timeout_cycles: int = 1_000_000) -> dict[str, Any]:
        self.start()
        request_id = self._next_id
        self._next_id += 1
        request = {
            "id": request_id,
            "command": "ponderuse",
            "actualFrom": int(actual_from) & 0xFF,
            "actualTo": int(actual_to) & 0xFF,
            "timeoutCycles": int(timeout_cycles),
        }
        self._send(request)
        response = self._read_response()
        if response.get("id") != request_id:
            raise Sim6502BridgeError(f"sim6502 bridge response id mismatch: {response}")
        if not response.get("ok"):
            raise Sim6502BridgeError(json.dumps(response, sort_keys=True))
        return response

    def zobrist(self, c64_position: object, timeout_cycles: int = 100_000_000) -> dict[str, Any]:
        """Return the engine's own 16-bit Zobrist key for a position.

        Drives ComputeZobristHash inside the engine (never reimplements the hash)
        so the opening-book compiler keys positions exactly as the engine does.
        Response carries ``key`` (16-bit int), ``keyLo`` and ``keyHi``.
        """
        self.start()
        assert self.proc is not None
        request_id = self._next_id
        self._next_id += 1
        request = {
            "id": request_id,
            "command": "zobrist",
            "board88": list(getattr(c64_position, "board88")),
            "currentplayer": int(getattr(c64_position, "currentplayer")),
            "whitekingsq": int(getattr(c64_position, "whitekingsq")),
            "blackkingsq": int(getattr(c64_position, "blackkingsq")),
            "castlerights": int(getattr(c64_position, "castlerights")),
            "enpassantsq": int(getattr(c64_position, "enpassantsq")),
            "halfmoveClock": int(getattr(c64_position, "halfmove_clock")),
            "fullmoveNumber": int(getattr(c64_position, "fullmove_number")),
            "difficulty": 0,
            "timeoutCycles": int(timeout_cycles),
        }
        self._send(request)
        response = self._read_response()
        if response.get("id") != request_id:
            raise Sim6502BridgeError(f"sim6502 bridge response id mismatch: {response}")
        if not response.get("ok"):
            raise Sim6502BridgeError(json.dumps(response, sort_keys=True))
        return response

    def evaluate(self, c64_position: object, timeout_cycles: int = 100_000_000, lazy: int = 0) -> dict[str, Any]:
        """Return the engine's static eval for a position.

        Drives EvaluatePosition inside the engine, so the ``eval`` field is the
        engine's own 16-bit signed white-POV score in engine units (10cp = 1
        unit). lazy=1 returns material + PST + phase counters only (for
        incremental Texel port verification); lazy=0 (default) runs every term.
        """
        self.start()
        assert self.proc is not None
        request_id = self._next_id
        self._next_id += 1
        request = {
            "id": request_id,
            "command": "eval",
            "lazy": int(lazy),
            "board88": list(getattr(c64_position, "board88")),
            "currentplayer": int(getattr(c64_position, "currentplayer")),
            "whitekingsq": int(getattr(c64_position, "whitekingsq")),
            "blackkingsq": int(getattr(c64_position, "blackkingsq")),
            "castlerights": int(getattr(c64_position, "castlerights")),
            "enpassantsq": int(getattr(c64_position, "enpassantsq")),
            "halfmoveClock": int(getattr(c64_position, "halfmove_clock")),
            "fullmoveNumber": int(getattr(c64_position, "fullmove_number")),
            "difficulty": 0,
            "timeoutCycles": int(timeout_cycles),
        }
        self._send(request)
        response = self._read_response()
        if response.get("id") != request_id:
            raise Sim6502BridgeError(f"sim6502 bridge response id mismatch: {response}")
        if not response.get("ok"):
            raise Sim6502BridgeError(json.dumps(response, sort_keys=True))
        return response

    def _bridge_is_current(self) -> bool:
        if not (self.bridge_dll.exists() and self.bridge_dll.stat().st_mtime >= self.project_path.stat().st_mtime):
            return False
        program_cs = self.project_path.with_name("Program.cs")
        return (
            self.bridge_dll.stat().st_mtime >= program_cs.stat().st_mtime
            and (
                not self.sim6502_runner_dll.exists()
                or self.bridge_dll.stat().st_mtime >= self.sim6502_runner_dll.stat().st_mtime
            )
        )

    def _ensure_built(self) -> None:
        if self._bridge_is_current():
            return
        # `dotnet build` is NOT safe to run concurrently against the same
        # obj/bin (CS2012 "being used by another process"). Parallel launchers
        # spin up many runners at once, so serialize the build behind an
        # inter-process lock and re-check inside the critical section -- the
        # first worker builds, the rest see a current dll and skip. This
        # turned a silently-wasted parallel run into a reliable one.
        lock_path = self.project_path.with_name(".bridge_build.lock")
        with open(lock_path, "w") as lock_file:
            try:
                import fcntl

                fcntl.flock(lock_file, fcntl.LOCK_EX)
            except (ImportError, OSError):
                pass  # No flock (non-POSIX): fall through; mtime recheck still helps.
            if self._bridge_is_current():
                return
            result = subprocess.run(
                [
                    self.dotnet,
                    "build",
                    str(self.project_path),
                    "-c",
                    self.configuration,
                    f"-p:Sim6502OutputDir={self.sim6502_output_dir}",
                ],
                cwd=self.repo_root,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
            if result.returncode != 0:
                raise Sim6502BridgeError(f"Could not build sim6502 bridge.\n{result.stdout}")

    def _send(self, payload: dict[str, Any]) -> None:
        assert self.proc is not None and self.proc.stdin is not None
        self.proc.stdin.write(json.dumps(payload, separators=(",", ":")) + "\n")
        self.proc.stdin.flush()

    def _read_response(self) -> dict[str, Any]:
        assert self.proc is not None and self.proc.stdout is not None
        line = self.proc.stdout.readline()
        if line == "":
            stderr = ""
            if self.proc.stderr is not None:
                stderr = self.proc.stderr.read()
            raise Sim6502BridgeError(f"sim6502 bridge exited unexpectedly.\n{stderr}")
        try:
            return json.loads(line)
        except json.JSONDecodeError as exc:
            raise Sim6502BridgeError(f"sim6502 bridge returned non-JSON output: {line.strip()}") from exc


def repo_root_from_script() -> Path:
    return Path(__file__).resolve().parents[1]


def run_self_test(repo_root: Path) -> int:
    from run_stockfish_strength import DIFFICULTY, c64_encoded_move_to_uci, fen_to_c64, square_to_0x88

    import chess

    fen = "k7/8/1K6/8/8/8/7R/8 w - - 0 1"
    c64 = fen_to_c64(fen)
    with Sim6502HeadlessRunner(repo_root=repo_root) as runner:
        response = runner.best_move(c64, DIFFICULTY["hard"], timeout_cycles=30_000_000)
        ponder_board = chess.Board("k7/8/4K3/8/8/8/4p3/8 b - - 0 1")
        predicted = chess.Move.from_uci("e2e1q")
        ponder_response = runner.ponder_search(
            fen_to_c64(ponder_board.fen()),
            DIFFICULTY["hard"],
            30_000_000,
            square_to_0x88(predicted.from_square),
            square_to_0x88(predicted.to_square),
        )
        use_response = runner.ponder_use(square_to_0x88(predicted.from_square), square_to_0x88(predicted.to_square))
    move = c64_encoded_move_to_uci(fen, int(response["encoded"]))
    assert move == "h2h8", f"expected h2h8, got {move}"
    assert int(response["cycles"]) > 0
    assert ponder_response["valid"], f"ponder search failed: {ponder_response}"
    assert use_response["accepted"], f"ponder use failed: {use_response}"
    print(
        f"Self-test passed: move={move} cycles={int(response['cycles']):,} "
        f"ponder_cycles={int(ponder_response['cycles']):,}"
    )
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the headless chess engine through persistent sim6502.")
    parser.add_argument("--repo-root", type=Path, default=repo_root_from_script())
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        return run_self_test(args.repo_root.resolve())
    print("Use --self-test, or import Sim6502HeadlessRunner from another tool.", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
