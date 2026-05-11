#!/usr/bin/env python3
"""Boot Colossus in VICE and dump a raw 64K runtime RAM image."""

from __future__ import annotations

import argparse
import json
import os
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


DEFAULT_OUTPUT_DIR = Path("build") / "colossus_extract" / "runtime"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vice-url", default=os.environ.get("VICE_MCP_URL", DEFAULT_VICE_MCP_URL))
    parser.add_argument("--d64", type=Path, default=Path(os.environ.get("COLOSSUS_D64", DEFAULT_D64)))
    parser.add_argument("--program-index", type=int, default=DEFAULT_PROGRAM_INDEX)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--tag", default="ready", help="Tag used in output filenames.")
    parser.add_argument("--no-boot", action="store_true", help="Dump the current VICE state without rebooting.")
    parser.add_argument("--boot-timeout-seconds", type=float, default=120.0)
    parser.add_argument("--poll-seconds", type=float, default=1.0)
    parser.add_argument("--warp-speed", type=int, default=10000)
    parser.add_argument("--bank", default="ram", help="VICE memory bank to dump; pass empty string for default CPU view.")
    parser.add_argument("--move", help="Optional UCI-like move to enter before dumping, e.g. e2e4.")
    parser.add_argument("--move-input", default="safe-petscii")
    parser.add_argument("--post-move-wait-seconds", type=float, default=2.0)
    return parser.parse_args()


def set_warp(vice: ViceMCPClient, speed: int) -> None:
    vice.call("vice.machine.config.set", {"resources": {"WarpMode": 1, "Speed": speed}})
    vice.call("vice.execution.run")


def read_screen(vice: ViceMCPClient) -> tuple[bytes, str]:
    screen_ram = vice.call("vice.memory.read", {"address": "$0400", "size": 1000})
    screen_bytes = bytes_from_mcp_data(screen_ram.get("data", []))
    return screen_bytes, decode_screen(screen_ram.get("data", []))


def wait_for_ready(vice: ViceMCPClient, timeout_seconds: float, poll_seconds: float, warp_speed: int) -> str:
    deadline = time.monotonic() + timeout_seconds
    last_screen = ""
    while time.monotonic() < deadline:
        set_warp(vice, warp_speed)
        _, last_screen = read_screen(vice)
        upper = last_screen.upper()
        if "COLOSSUS 4.0" in upper and "LOADING" not in upper:
            return last_screen
        time.sleep(poll_seconds)
    raise TimeoutError(f"Colossus did not reach the board within {timeout_seconds:.1f}s\n{last_screen}")


def bytes_from_mcp_data(data: list[Any]) -> bytes:
    values: list[int] = []
    for value in data:
        if isinstance(value, str):
            values.append(int(value, 16) & 0xFF)
        else:
            values.append(int(value) & 0xFF)
    return bytes(values)


def read_memory(vice: ViceMCPClient, bank: str | None) -> bytes:
    chunks: list[bytes] = []
    for address in range(0, 0x10000, 0x1000):
        args: dict[str, Any] = {"address": f"${address:04x}", "size": min(0x1000, 0x10000 - address)}
        if bank:
            args["bank"] = bank
        result = vice.call("vice.memory.read", args)
        chunk = bytes_from_mcp_data(result.get("data", []))
        if len(chunk) != args["size"]:
            raise RuntimeError(f"memory read at ${address:04x} returned {len(chunk)} bytes, expected {args['size']}")
        chunks.append(chunk)
    return b"".join(chunks)


def try_call(vice: ViceMCPClient, tool: str, args: dict[str, Any] | None = None) -> Any:
    try:
        return vice.call(tool, args or {})
    except Exception as exc:  # Keep dumps useful even if an optional tool is missing.
        return {"error": str(exc)}


def boot_colossus(vice: ViceMCPClient, args: argparse.Namespace) -> str:
    vice.call("vice.disk.attach", {"unit": 8, "path": str(args.d64)})
    vice.call("vice.machine.reset", {"mode": "hard", "run_after": True})
    vice.call("vice.autostart", {"path": str(args.d64), "index": args.program_index, "run": True})
    return wait_for_ready(vice, args.boot_timeout_seconds, args.poll_seconds, args.warp_speed)


def main() -> int:
    args = parse_args()
    if not args.no_boot and not args.d64.exists():
        raise FileNotFoundError(f"missing Colossus D64: {args.d64}")

    args.output_dir.mkdir(parents=True, exist_ok=True)
    bank = args.bank.strip() or None
    vice = ViceMCPClient(args.vice_url)
    ping = vice.call("vice.ping")

    ready_screen = None
    if not args.no_boot:
        ready_screen = boot_colossus(vice, args)
    else:
        set_warp(vice, args.warp_speed)

    move_input = None
    if args.move:
        move_input = send_colossus_move(
            vice,
            args.move,
            input_mode=args.move_input,
            hold_frames=5,
            key_gap=0.08,
        )
        time.sleep(args.post_move_wait_seconds)

    screen_bytes, decoded_screen = read_screen(vice)
    memory = read_memory(vice, bank)
    registers = try_call(vice, "vice.registers.get")
    banks = try_call(vice, "vice.memory.banks")

    prefix = args.output_dir / args.tag
    ram_path = prefix.with_suffix(".ram.bin")
    screen_bin_path = prefix.with_suffix(".screen.bin")
    screen_txt_path = prefix.with_suffix(".screen.txt")
    meta_path = prefix.with_suffix(".json")

    ram_path.write_bytes(memory)
    screen_bin_path.write_bytes(screen_bytes)
    screen_txt_path.write_text(decoded_screen + "\n", encoding="utf-8")
    meta = {
        "vice": ping,
        "d64": str(args.d64),
        "program_index": args.program_index,
        "bank": bank,
        "tag": args.tag,
        "move": args.move,
        "move_input": move_input,
        "registers": registers,
        "banks": banks,
        "ready_screen": ready_screen,
        "decoded_screen": decoded_screen,
        "paths": {
            "ram": str(ram_path),
            "screen_bin": str(screen_bin_path),
            "screen_txt": str(screen_txt_path),
        },
    }
    meta_path.write_text(json.dumps(meta, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    print(f"wrote {ram_path} ({len(memory)} bytes)")
    print(f"wrote {screen_txt_path}")
    print(f"wrote {meta_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
