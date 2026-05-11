#!/usr/bin/env python3
"""Drive Colossus Chess 4 through the raw sim6502 runner."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path
from typing import Any


DEFAULT_RUNTIME_DIR = Path("build") / "colossus_extract" / "runtime"
DEFAULT_OUTPUT_DIR = Path("build") / "colossus_raw_game"
DEFAULT_RUNNER_DLL = Path("tools") / "ColossusRawRunner" / "bin" / "Release" / "net10.0" / "ColossusRawRunner.dll"
PROFILE_PRESETS = {
    "default": {
        "cycles": 1_000_000_000,
        "tod_cycles_per_tick": 100_000,
        "pokes": [],
    },
    "easy-match": {
        "cycles": 1_000_000_000,
        "tod_cycles_per_tick": 100_000,
        "pokes": ["0xb49b=0x00"],
    },
    "no-book": {
        "cycles": 1_000_000_000,
        "tod_cycles_per_tick": 100_000,
        "pokes": ["0xb407=0x00", "0xb49b=0x00"],
    },
    "hard": {
        "cycles": 5_000_000_000,
        "tod_cycles_per_tick": 1_000_000,
        "pokes": ["0xb407=0x00", "0xb413=0x0f", "0xb49b=0x00"],
    },
    "hard-30m": {
        "cycles": 1_800_000_000,
        "tod_cycles_per_tick": 100_000,
        "pokes": ["0xb407=0x00", "0xb413=0x0f", "0xb49b=0x00"],
    },
    "hard-move-1m": {
        "cycles": 0,
        "tod_cycles_per_tick": 100_000,
        "pokes": [
            "0xb407=0x00",
            "0xb413=0x0f",
            "0xb468=0x00",
            "0xb469=0x02",
            "0xb46a=0x00",
            "0xb46e=0x02",
            "0xb46f=0x00",
            "0xb49b=0x00",
        ],
    },
    "hard-move-5m": {
        "cycles": 0,
        "tod_cycles_per_tick": 100_000,
        "pokes": [
            "0xb407=0x00",
            "0xb413=0x0f",
            "0xb468=0x00",
            "0xb469=0x0a",
            "0xb46a=0x00",
            "0xb46e=0x0a",
            "0xb46f=0x00",
            "0xb49b=0x00",
        ],
    },
    "match-move-1m": {
        "cycles": 0,
        "tod_cycles_per_tick": 100_000,
        "pokes": [
            "0xb413=0x0f",
            "0xb468=0x00",
            "0xb469=0x02",
            "0xb46a=0x00",
            "0xb46e=0x02",
            "0xb46f=0x00",
            "0xb49b=0x00",
        ],
    },
    "match-move-5m": {
        "cycles": 0,
        "tod_cycles_per_tick": 100_000,
        "pokes": [
            "0xb413=0x0f",
            "0xb468=0x00",
            "0xb469=0x0a",
            "0xb46a=0x00",
            "0xb46e=0x0a",
            "0xb46f=0x00",
            "0xb49b=0x00",
        ],
    },
    "beast": {
        "cycles": 0,
        "tod_cycles_per_tick": 1_000_000,
        "pokes": ["0xb407=0x00", "0xb413=0x0f", "0xb49b=0x00"],
    },
    "match": {
        "cycles": 0,
        "tod_cycles_per_tick": 1_000_000,
        "pokes": ["0xb49b=0x00"],
    },
    "correspondence": {
        "cycles": 0,
        "tod_cycles_per_tick": 1_000_000,
        "pokes": ["0xb407=0x00", "0xb413=0x0f", "0xb465=0x05", "0xb49b=0x00"],
    },
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime-dir", type=Path, default=DEFAULT_RUNTIME_DIR)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--runner", type=Path, default=DEFAULT_RUNNER_DLL)
    parser.add_argument("--moves", nargs="+", default=["e2e4", "g1f3"], help="White moves to feed Colossus.")
    parser.add_argument("--profile", choices=sorted(PROFILE_PRESETS), default="default")
    parser.add_argument("--cycles", type=int, help="Raw cycle cap; 0 means run until a stop condition fires.")
    parser.add_argument("--wall-time-limit-seconds", type=float, default=0.0)
    parser.add_argument("--poll-steps", type=int, default=8192)
    parser.add_argument("--tod-cycles-per-tick", type=int)
    parser.add_argument("--poke", action="append", default=[], help="Patch Colossus RAM before running, e.g. 0xb466=0xff.")
    return parser.parse_args()


def move_for_screen(move: str) -> str:
    normalized = move.strip().lower()
    if not re.fullmatch(r"[a-h][1-8][a-h][1-8][qrbn]?", normalized):
        raise ValueError(f"expected UCI-like move, got {move!r}")
    return f"{normalized[:2]}[-x]{normalized[2:4]}[+#]?"


def run_raw(args: argparse.Namespace, command: list[str]) -> dict[str, Any]:
    result = subprocess.run(command, check=False, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode != 0:
        raise RuntimeError(f"raw runner failed with {result.returncode}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}")
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    if not lines:
        raise RuntimeError(f"raw runner produced no JSON\nstderr:\n{result.stderr}")
    return json.loads(lines[-1])


def screen_search_stats(screen: str) -> tuple[str, str]:
    match = re.search(r"Lookahead=(\d+)\s+Positions=([0-9]+)", screen)
    if not match:
        return "?", "?"
    return match.group(1), str(int(match.group(2)))


def best_line(screen: str) -> str:
    lines = screen.splitlines()
    for index, line in enumerate(lines):
        if line.startswith("Best line") and index + 1 < len(lines):
            return lines[index + 1].strip()
    return ""


def rate_text(result: dict[str, Any]) -> str:
    cycles_per_second = result.get("cyclesPerSecond")
    wall_ms = result.get("wallMilliseconds")
    if cycles_per_second is None or wall_ms is None:
        return ""
    return f", wall={float(wall_ms) / 1000.0:.2f}s, sim={float(cycles_per_second):.0f} cyc/s"


def main() -> int:
    args = parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    profile = PROFILE_PRESETS[args.profile]
    cycles = args.cycles if args.cycles is not None else profile["cycles"]
    tod_cycles_per_tick = (
        args.tod_cycles_per_tick if args.tod_cycles_per_tick is not None else profile["tod_cycles_per_tick"]
    )
    pokes = [*profile["pokes"], *args.poke]

    ram = args.runtime_dir / "ready.ram.bin"
    cpu_view = args.runtime_dir / "ready_cpu.ram.bin"
    meta = args.runtime_dir / "ready.json"
    if not args.runner.exists():
        subprocess.run(["dotnet", "build", "tools/ColossusRawRunner/ColossusRawRunner.csproj", "-c", "Release"], check=True)

    all_moves: list[str] = []
    for index, move in enumerate(args.moves, start=1):
        target_ply = index * 2
        out_prefix = args.output_dir / f"ply{target_ply:02d}"
        stop_regex = rf"^\s*{index}\s+{move_for_screen(move)}\s+[a-h][1-8][-x][a-h][1-8]"
        command = [
            "dotnet",
            str(args.runner),
            "--ram",
            str(ram),
            "--cpu-view",
            str(cpu_view),
            "--meta",
            str(meta),
            "--move",
            move,
            "--cycles",
            str(cycles),
            "--tod-cycles-per-tick",
            str(tod_cycles_per_tick),
            "--stop-when-screen-regex",
            stop_regex,
            "--poll-steps",
            str(args.poll_steps),
            "--ram-out",
            str(out_prefix.with_suffix(".ram.bin")),
            "--json",
            str(out_prefix.with_suffix(".json")),
            "--screen",
            str(out_prefix.with_suffix(".screen.txt")),
        ]
        if args.wall_time_limit_seconds > 0:
            command.extend(["--wall-time-limit-seconds", str(args.wall_time_limit_seconds)])
        for poke in pokes:
            command.extend(["--poke", poke])
        result = run_raw(args, command)
        screen_moves = result.get("screenMoves", [])
        if len(screen_moves) < target_ply:
            cycle_limit_text = "uncapped" if cycles <= 0 else f"{cycles} cycles"
            wall_limit_text = (
                f", {args.wall_time_limit_seconds:g}s wall"
                if args.wall_time_limit_seconds > 0
                else ""
            )
            print(
                f"{index}. {move} -> no reply within {cycle_limit_text}{wall_limit_text} "
                f"(got {len(screen_moves)} plies, stop={result.get('stopReason')})"
            )
            print(result.get("screen", ""))
            return 1

        all_moves = screen_moves
        reply = screen_moves[target_ply - 1]
        lookahead, positions = screen_search_stats(result.get("screen", ""))
        best = best_line(result.get("screen", ""))
        print(
            f"{index}. {move} {reply} "
            f"(lookahead={lookahead}, positions={positions}, cycles={result.get('cycles')}, "
            f"steps={result.get('steps')}{rate_text(result)}, stop={result.get('stopReason')})"
        )
        if best:
            print(f"   best line: {best}")
        ram = out_prefix.with_suffix(".ram.bin")
        meta = out_prefix.with_suffix(".json")

    print("moves:", " ".join(all_moves))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
