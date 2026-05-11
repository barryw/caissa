#!/usr/bin/env python3
"""Benchmark a VICE-hosted Colossus reply from a clean boot."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
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


MOVE_LINE_RE = re.compile(
    r"^\s*(\d+)\s+([a-h][1-8])\s*[-x]\s*([a-h][1-8])"
    r"[+#]?(?:\s+([a-h][1-8])\s*[-x]\s*([a-h][1-8])[+#]?)?",
    re.IGNORECASE,
)

PRESETS: dict[str, dict[str, Any]] = {
    "book": {
        "description": "book enabled, prediction disabled",
        "pokes": [(0xB49B, 0x00)],
    },
    "hard": {
        "description": "book disabled, max line setting, prediction disabled",
        "pokes": [(0xB407, 0x00), (0xB413, 0x0F), (0xB49B, 0x00)],
    },
}


def bytes_from_mcp_data(data: list[Any]) -> bytes:
    values: list[int] = []
    for value in data:
        if isinstance(value, str):
            values.append(int(value, 16) & 0xFF)
        else:
            values.append(int(value) & 0xFF)
    return bytes(values)


def read_screen(vice: ViceMCPClient) -> str:
    screen_ram = vice.call("vice.memory.read", {"address": "$0400", "size": 1000})
    return decode_screen(screen_ram.get("data", []))


def screen_moves(screen: str) -> list[str]:
    moves: list[str] = []
    for line in screen.splitlines():
        match = MOVE_LINE_RE.match(line)
        if not match:
            continue
        _, white_from, white_to, black_from, black_to = match.groups()
        moves.append((white_from + white_to).lower())
        if black_from and black_to:
            moves.append((black_from + black_to).lower())
    return moves


def set_warp(vice: ViceMCPClient, speed: int) -> None:
    vice.call("vice.machine.config.set", {"resources": {"WarpMode": 1, "Speed": speed}})
    vice.call("vice.execution.run")


def boot_colossus(args: argparse.Namespace, vice: ViceMCPClient) -> str:
    vice.call("vice.disk.attach", {"unit": 8, "path": str(args.d64)})
    vice.call("vice.machine.reset", {"mode": "hard", "run_after": True})
    vice.call("vice.autostart", {"path": str(args.d64), "index": args.program_index, "run": True})
    set_warp(vice, args.warp_speed)

    deadline = time.monotonic() + args.boot_timeout_seconds
    last_screen = ""
    while time.monotonic() < deadline:
        last_screen = read_screen(vice)
        upper = last_screen.upper()
        if "COLOSSUS 4.0" in upper and "LOADING" not in upper:
            return last_screen
        time.sleep(args.poll_seconds)
    raise TimeoutError(f"Colossus did not boot within {args.boot_timeout_seconds:.1f}s\n{last_screen}")


def apply_preset(vice: ViceMCPClient, preset: str) -> None:
    for address, value in PRESETS[preset]["pokes"]:
        vice.call("vice.memory.write", {"address": f"${address:04x}", "data": [value], "bank": "ram"})


def wait_for_reply(args: argparse.Namespace, vice: ViceMCPClient, target_plies: int) -> tuple[float, str, list[str]]:
    deadline = time.monotonic() + args.reply_timeout_seconds
    start = time.monotonic()
    last_screen = ""
    last_moves: list[str] = []
    last_warp_refresh = 0.0
    while time.monotonic() < deadline:
        now = time.monotonic()
        if now - last_warp_refresh > 5.0:
            set_warp(vice, args.warp_speed)
            last_warp_refresh = now
        last_screen = read_screen(vice)
        last_moves = screen_moves(last_screen)
        if len(last_moves) >= target_plies:
            return time.monotonic() - start, last_screen, last_moves
        time.sleep(args.poll_seconds)
    raise TimeoutError(
        f"Colossus reached {len(last_moves)} plies, expected {target_plies}, "
        f"within {args.reply_timeout_seconds:.1f}s\n{last_screen}"
    )


def wait_for_move_count(
    args: argparse.Namespace,
    vice: ViceMCPClient,
    target_plies: int,
    timeout_seconds: float,
) -> tuple[str, list[str]]:
    deadline = time.monotonic() + timeout_seconds
    last_screen = ""
    last_moves: list[str] = []
    while time.monotonic() < deadline:
        last_screen = read_screen(vice)
        last_moves = screen_moves(last_screen)
        if len(last_moves) >= target_plies:
            return last_screen, last_moves
        time.sleep(args.poll_seconds)
    raise TimeoutError(
        f"Colossus reached {len(last_moves)} plies, expected {target_plies}, "
        f"within {timeout_seconds:.1f}s\n{last_screen}"
    )


def send_move_with_ack(
    args: argparse.Namespace,
    vice: ViceMCPClient,
    before_plies: int,
) -> tuple[str, list[str]]:
    target_plies = before_plies + 1
    last_error: TimeoutError | None = None
    for _ in range(args.move_attempts):
        send_colossus_move(
            vice,
            args.move,
            input_mode=args.move_input,
            hold_frames=args.move_hold_frames,
            key_gap=args.move_key_gap,
        )
        try:
            return wait_for_move_count(args, vice, target_plies, args.move_ack_timeout_seconds)
        except TimeoutError as exc:
            last_error = exc
            set_warp(vice, args.warp_speed)
    if last_error is not None:
        raise last_error
    raise RuntimeError("move send was not attempted")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vice-url", default=os.environ.get("VICE_MCP_URL", DEFAULT_VICE_MCP_URL))
    parser.add_argument("--d64", type=Path, default=Path(os.environ.get("COLOSSUS_D64", DEFAULT_D64)))
    parser.add_argument("--program-index", type=int, default=DEFAULT_PROGRAM_INDEX)
    parser.add_argument("--preset", choices=sorted(PRESETS), default="hard")
    parser.add_argument("--move", default="e2e4")
    parser.add_argument(
        "--move-input",
        default="type",
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
    )
    parser.add_argument("--move-hold-frames", type=int, default=5)
    parser.add_argument("--move-key-gap", type=float, default=0.08)
    parser.add_argument("--move-attempts", type=int, default=3)
    parser.add_argument("--move-ack-timeout-seconds", type=float, default=8.0)
    parser.add_argument("--warp-speed", type=int, default=10000)
    parser.add_argument("--boot-timeout-seconds", type=float, default=120.0)
    parser.add_argument("--post-boot-settle-seconds", type=float, default=2.0)
    parser.add_argument("--reply-timeout-seconds", type=float, default=300.0)
    parser.add_argument("--poll-seconds", type=float, default=0.05)
    parser.add_argument("--json", type=Path)
    parser.add_argument("--no-boot", action="store_true", help="Use the currently running Colossus board.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not args.d64.exists():
        print(f"missing Colossus disk: {args.d64}", file=sys.stderr)
        return 2

    vice = ViceMCPClient(args.vice_url)
    ping = vice.call("vice.ping")
    if args.no_boot:
        set_warp(vice, args.warp_speed)
        ready_screen = read_screen(vice)
    else:
        ready_screen = boot_colossus(args, vice)

    time.sleep(args.post_boot_settle_seconds)
    apply_preset(vice, args.preset)
    before_moves = screen_moves(ready_screen)
    target_plies = len(before_moves) + 2
    ready_screen, _ack_moves = send_move_with_ack(args, vice, len(before_moves))
    elapsed, final_screen, moves = wait_for_reply(args, vice, target_plies)

    report = {
        "vice": ping,
        "preset": args.preset,
        "description": PRESETS[args.preset]["description"],
        "move": args.move,
        "wall_seconds": elapsed,
        "moves": moves,
        "reply": moves[target_plies - 1] if len(moves) >= target_plies else None,
        "screen": final_screen,
    }
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    print(
        f"{args.preset}: {args.move} {report['reply']} in {elapsed:.2f}s "
        f"({PRESETS[args.preset]['description']})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
