#!/usr/bin/env python3
"""Probe a Colossus Chess 4 disk through the VICE MCP HTTP endpoint."""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


DEFAULT_VICE_MCP_URL = "http://localhost:6510/mcp"
DEFAULT_D64_CANDIDATES = (
    Path.home() / "Downloads" / "Colossus-Chess-4_C64_EN" / "COLOSS40.D64",
    Path.home() / "Downloads" / "Colossus_Chess_4-[manik].d64",
)
DEFAULT_D64 = next((path for path in DEFAULT_D64_CANDIDATES if path.exists()), DEFAULT_D64_CANDIDATES[0])
DEFAULT_PROGRAM_INDEX = int(os.environ.get("COLOSSUS_PROGRAM_INDEX", "4"))


PETSCII_TO_ASCII = {
    0x0d: "\n",
    0x20: " ",
    **{value: chr(value) for value in range(0x30, 0x3a)},
    **{value: chr(ord("a") + value - 0x01) for value in range(0x01, 0x1b)},
    **{value: chr(value) for value in range(0x21, 0x30)},
    **{value: chr(value) for value in range(0x3a, 0x5b)},
}


class ViceMCPError(RuntimeError):
    pass


class ViceMCPClient:
    def __init__(self, url: str) -> None:
        self.url = url
        self.next_id = 1

    def call(self, tool: str, arguments: dict[str, Any] | None = None) -> Any:
        request_id = self.next_id
        self.next_id += 1
        payload = {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "tools/call",
            "params": {"name": tool, "arguments": arguments or {}},
        }
        data = json.dumps(payload).encode("utf-8")
        request = urllib.request.Request(
            self.url,
            data=data,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                body = json.loads(response.read().decode("utf-8"))
        except urllib.error.URLError as exc:
            raise ViceMCPError(f"could not reach VICE MCP at {self.url}: {exc}") from exc

        if body.get("error"):
            raise ViceMCPError(f"{tool} failed: {body['error']}")

        content = body.get("result", {}).get("content", [])
        if content and content[0].get("type") == "text":
            text = content[0].get("text", "")
            try:
                return json.loads(text)
            except json.JSONDecodeError:
                return text
        return body.get("result")


def decode_screen(data: list[str]) -> str:
    values = [int(value, 16) if isinstance(value, str) else int(value) for value in data]
    rows: list[str] = []
    for offset in range(0, min(len(values), 1000), 40):
        chars = [PETSCII_TO_ASCII.get(value & 0x7f, ".") for value in values[offset : offset + 40]]
        rows.append("".join(chars).rstrip())
    return "\n".join(rows).rstrip()


def disk_has_file(disk: dict[str, Any], wanted: str) -> bool:
    normalized = wanted.strip('"').lower()
    for item in disk.get("files", []):
        name = str(item.get("name", "")).strip().strip('"').strip().lower()
        if name == normalized:
            return True
    return False


def square_to_colossus_safe_text(square: str) -> str:
    file_name, rank = square[0], square[1]
    if file_name == "g":
        return f"{rank}H\\x9d"
    return f"{rank}{file_name.upper()}"


def move_to_colossus_text(move: str) -> str:
    normalized = move.strip().lower()
    if len(normalized) < 4:
        raise ValueError(f"expected UCI-like move such as e2e4, got {move!r}")
    from_file, from_rank, to_file, to_rank = normalized[:4]
    if from_file not in "abcdefgh" or to_file not in "abcdefgh":
        raise ValueError(f"move files must be a-h, got {move!r}")
    if from_rank not in "12345678" or to_rank not in "12345678":
        raise ValueError(f"move ranks must be 1-8, got {move!r}")
    return f"{from_rank}{from_file.upper()}\n{to_rank}{to_file.upper()}\n"


def move_to_colossus_safe_text(move: str) -> str:
    normalized = move.strip().lower()
    if len(normalized) < 4:
        raise ValueError(f"expected UCI-like move such as e2e4, got {move!r}")
    from_square = normalized[:2]
    to_square = normalized[2:4]
    for square in (from_square, to_square):
        if square[0] not in "abcdefgh" or square[1] not in "12345678":
            raise ValueError(f"invalid square in move {move!r}")
    return f"{square_to_colossus_safe_text(from_square)}\\x0d{square_to_colossus_safe_text(to_square)}\\x0d"


def square_to_colossus_petscii(square: str) -> list[int]:
    file_name, rank = square[0], square[1]
    return [ord(rank), 0xC1 + ord(file_name) - ord("a"), 0x0D]


def square_to_colossus_safe_petscii(square: str) -> list[int]:
    file_name, rank = square[0], square[1]
    if file_name == "g":
        return [ord(rank), ord("H"), 0x9D, 0x0D]
    return [ord(rank), ord(file_name.upper()), 0x0D]


def move_to_colossus_petscii(move: str) -> list[int]:
    normalized = move.strip().lower()
    if len(normalized) < 4:
        raise ValueError(f"expected UCI-like move such as e2e4, got {move!r}")
    from_square = normalized[:2]
    to_square = normalized[2:4]
    for square in (from_square, to_square):
        if square[0] not in "abcdefgh" or square[1] not in "12345678":
            raise ValueError(f"invalid square in move {move!r}")
    return square_to_colossus_petscii(from_square) + square_to_colossus_petscii(to_square)


def move_to_colossus_safe_petscii(move: str) -> list[int]:
    normalized = move.strip().lower()
    if len(normalized) < 4:
        raise ValueError(f"expected UCI-like move such as e2e4, got {move!r}")
    from_square = normalized[:2]
    to_square = normalized[2:4]
    for square in (from_square, to_square):
        if square[0] not in "abcdefgh" or square[1] not in "12345678":
            raise ValueError(f"invalid square in move {move!r}")
    return square_to_colossus_safe_petscii(from_square) + square_to_colossus_safe_petscii(to_square)


def format_petscii(data: list[int]) -> str:
    return " ".join(f"{value:02x}" for value in data)


def matrix_tap(vice: ViceMCPClient, key: str, hold_frames: int, key_gap: float) -> None:
    vice.call("vice.keyboard.matrix", {"key": key, "pressed": True, "hold_frames": hold_frames})
    time.sleep(key_gap)


def matrix_chord_tap(vice: ViceMCPClient, *keys: str, hold_frames: int, key_gap: float) -> None:
    vice.call("vice.keyboard.chord", {"keys": list(keys), "hold_frames": hold_frames})
    time.sleep(key_gap)


def matrix_shift_tap(vice: ViceMCPClient, key: str, hold_frames: int, key_gap: float) -> None:
    vice.call("vice.keyboard.matrix", {"key": "LSHIFT", "pressed": True})
    time.sleep(key_gap)
    matrix_tap(vice, key, hold_frames, key_gap)
    vice.call("vice.keyboard.matrix", {"key": "LSHIFT", "pressed": False})
    time.sleep(key_gap)


def keypress_tap(
    vice: ViceMCPClient,
    key: str,
    *,
    shifted: bool,
    hold_frames: int,
    key_gap: float,
) -> None:
    args: dict[str, Any] = {"key": key, "hold_frames": hold_frames}
    if shifted:
        args["modifiers"] = ["shift"]
    vice.call("vice.keyboard.key_press", args)
    time.sleep(key_gap)


def send_colossus_move(
    vice: ViceMCPClient,
    move: str,
    *,
    input_mode: str,
    hold_frames: int,
    key_gap: float,
) -> str:
    if input_mode == "safe-petscii":
        data = move_to_colossus_safe_petscii(move)
        vice.call("vice.keyboard.petscii", {"data": data})
        return format_petscii(data)

    if input_mode == "petscii":
        data = move_to_colossus_petscii(move)
        vice.call("vice.keyboard.petscii", {"data": data})
        return format_petscii(data)

    if input_mode == "safe-type":
        text = move_to_colossus_safe_text(move)
        vice.call("vice.keyboard.type", {"text": text, "petscii_upper": True})
        return text

    text = move_to_colossus_text(move)
    if input_mode == "type":
        vice.call("vice.keyboard.type", {"text": text, "petscii_upper": True})
        return text

    for char in text:
        if char == "\n":
            if input_mode.startswith("matrix"):
                matrix_tap(vice, "RETURN", hold_frames, key_gap)
            else:
                keypress_tap(vice, "Return", shifted=False, hold_frames=hold_frames, key_gap=key_gap)
            continue
        if char in "12345678":
            if input_mode.startswith("matrix"):
                matrix_tap(vice, char, hold_frames, key_gap)
            else:
                keypress_tap(vice, char, shifted=False, hold_frames=hold_frames, key_gap=key_gap)
            continue
        if input_mode == "matrix-chord":
            matrix_chord_tap(vice, "LSHIFT", char, hold_frames=hold_frames, key_gap=key_gap)
        elif input_mode == "matrix-shift":
            matrix_shift_tap(vice, char, hold_frames, key_gap)
        elif input_mode == "keypress-shift":
            keypress_tap(vice, char.lower(), shifted=True, hold_frames=hold_frames, key_gap=key_gap)
        elif input_mode == "matrix":
            matrix_tap(vice, char, hold_frames, key_gap)
        elif input_mode == "keypress":
            keypress_tap(vice, char, shifted=False, hold_frames=hold_frames, key_gap=key_gap)
        else:
            raise ValueError(f"unknown input mode: {input_mode}")
    return text


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vice-url", default=os.environ.get("VICE_MCP_URL", DEFAULT_VICE_MCP_URL))
    parser.add_argument(
        "--d64",
        type=Path,
        default=Path(os.environ.get("COLOSSUS_D64", DEFAULT_D64)),
        help="Path to the Colossus Chess 4 D64 image.",
    )
    parser.add_argument("--program-index", type=int, default=DEFAULT_PROGRAM_INDEX)
    parser.add_argument("--wait-seconds", type=float, default=20.0)
    parser.add_argument(
        "--warp",
        action="store_true",
        help="Enable VICE warp mode after autostart; VICE autostart may turn it off while loading.",
    )
    parser.add_argument(
        "--screenshot",
        type=Path,
        default=Path("build") / "colossus_probe.png",
        help="Where to save the post-boot screenshot.",
    )
    parser.add_argument("--json", type=Path, help="Optional JSON report path.")
    parser.add_argument(
        "--require-second-stage",
        action="store_true",
        help="Exit nonzero if the disk listing does not contain a known runtime file.",
    )
    parser.add_argument(
        "--screen-only",
        action="store_true",
        help="Only read and decode current VICE screen RAM; do not attach, reset, or autostart.",
    )
    parser.add_argument(
        "--move",
        help="Send a UCI-like move to the currently running Colossus board, e.g. e2e4.",
    )
    parser.add_argument(
        "--move-input",
        default="safe-petscii",
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
        help="Input strategy used by --move.",
    )
    parser.add_argument("--move-hold-frames", type=int, default=5)
    parser.add_argument("--move-key-gap", type=float, default=0.08)
    parser.add_argument("--post-move-wait-seconds", type=float, default=2.0)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not args.d64.exists():
        print(f"missing Colossus disk: {args.d64}", file=sys.stderr)
        return 2

    args.screenshot.parent.mkdir(parents=True, exist_ok=True)
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)

    vice = ViceMCPClient(args.vice_url)
    ping = vice.call("vice.ping")
    if args.move:
        vice.call("vice.machine.config.set", {"resources": {"WarpMode": 1, "Speed": 10000}})
        typed = send_colossus_move(
            vice,
            args.move,
            input_mode=args.move_input,
            hold_frames=args.move_hold_frames,
            key_gap=args.move_key_gap,
        )
        time.sleep(args.post_move_wait_seconds)
        screen_ram = vice.call("vice.memory.read", {"address": "$0400", "size": 1000})
        decoded_screen = decode_screen(screen_ram.get("data", []))
        screenshot = vice.call(
            "vice.display.screenshot",
            {"path": str(args.screenshot.resolve()), "format": "PNG", "return_base64": False},
        )
        report = {
            "vice": ping,
            "move": args.move,
            "move_input": args.move_input,
            "typed": typed,
            "screenshot": screenshot,
            "decoded_screen": decoded_screen,
        }
        if args.json:
            args.json.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(decoded_screen)
        return 0
    if args.screen_only:
        screen_ram = vice.call("vice.memory.read", {"address": "$0400", "size": 1000})
        decoded_screen = decode_screen(screen_ram.get("data", []))
        print(decoded_screen)
        if args.json:
            args.json.write_text(
                json.dumps({"vice": ping, "decoded_screen": decoded_screen}, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
        return 0

    disk = vice.call("vice.disk.attach", {"unit": 8, "path": str(args.d64)})
    listing = vice.call("vice.disk.list", {"unit": 8})
    missing_runtime_file = not (disk_has_file(listing, "part1") or disk_has_file(listing, "c"))

    vice.call("vice.machine.reset", {"mode": "hard", "run_after": True})
    autostart = vice.call(
        "vice.autostart",
        {"path": str(args.d64), "index": args.program_index, "run": True},
    )
    warp = None
    if args.warp:
        warp = vice.call("vice.machine.config.set", {"resources": {"WarpMode": 1}})
        vice.call("vice.execution.run")
    time.sleep(args.wait_seconds)
    screenshot = vice.call(
        "vice.display.screenshot",
        {"path": str(args.screenshot.resolve()), "format": "PNG", "return_base64": False},
    )
    screen_ram = vice.call("vice.memory.read", {"address": "$0400", "size": 1000})
    decoded_screen = decode_screen(screen_ram.get("data", []))

    report = {
        "vice": ping,
        "disk_attach": disk,
        "disk_listing": listing,
        "autostart": autostart,
        "warp": warp,
        "screenshot": screenshot,
        "decoded_screen": decoded_screen,
        "warnings": [],
    }
    if missing_runtime_file:
        report["warnings"].append(
            'disk listing does not contain a known runtime file ("part1" or "c"); this image may stop at a loader/title screen'
        )

    if args.json:
        args.json.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    print(f"VICE: {ping.get('machine')} {ping.get('execution')}")
    print(f"Disk: {args.d64}")
    for item in listing.get("files", []):
        print(f"  {item.get('blocks')} blocks {item.get('type', '').strip()} {item.get('name')}")
    for warning in report["warnings"]:
        print(f"warning: {warning}", file=sys.stderr)
    print(f"Screenshot: {args.screenshot}")
    if decoded_screen:
        print("\nScreen RAM:")
        print(decoded_screen)

    return 1 if args.require_second_stage and report["warnings"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
