#!/usr/bin/env python3
"""Hunt for Colossus board and move-state locations from controlled RAM dumps."""

from __future__ import annotations

import argparse
from pathlib import Path


DEFAULT_RUNTIME_DIR = Path("build") / "colossus_extract" / "runtime"
DEFAULT_MOVES = ("e2e4", "d2d4", "g1f3", "b1c3")
BOARD_BASE = 0xA700
BOARD_ORIGIN = 13
BOARD_STRIDE = 10
PIECES = {
    0x00: ".",
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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime-dir", type=Path, default=DEFAULT_RUNTIME_DIR)
    parser.add_argument("--moves", nargs="*", default=list(DEFAULT_MOVES))
    parser.add_argument(
        "--extra-tags",
        nargs="*",
        default=[],
        help="Additional dump tags to decode as board states, e.g. raw_after_e2e4_reply_stop.",
    )
    parser.add_argument("--max-address", type=lambda text: int(text, 0), default=0x0200)
    return parser.parse_args()


def load_dump(runtime_dir: Path, tag: str) -> bytes:
    path = runtime_dir / f"{tag}.ram.bin"
    if not path.exists():
        raise FileNotFoundError(path)
    return path.read_bytes()


def ranges(offsets: list[int]) -> list[tuple[int, int]]:
    if not offsets:
        return []
    out: list[tuple[int, int]] = []
    start = prev = offsets[0]
    for offset in offsets[1:]:
        if offset == prev + 1:
            prev = offset
            continue
        out.append((start, prev))
        start = prev = offset
    out.append((start, prev))
    return out


def fmt(value: int) -> str:
    return f"${value:02x}"


def print_diff_summary(ready: bytes, dumps: dict[str, bytes], max_address: int) -> None:
    for move, data in dumps.items():
        offsets = [index for index in range(max_address) if ready[index] != data[index]]
        print(f"{move} low-memory diffs ({len(offsets)}):")
        for start, end in ranges(offsets)[:30]:
            parts = []
            for address in range(start, min(end + 1, start + 12)):
                parts.append(f"${address:04x}:{ready[address]:02x}->{data[address]:02x}")
            suffix = "" if end - start < 12 else " ..."
            print(f"  ${start:04x}-${end:04x}: {' '.join(parts)}{suffix}")
        print()


def candidate_board_ranges(ready: bytes, dumps: dict[str, bytes], max_address: int) -> list[tuple[int, int, int]]:
    candidates: list[tuple[int, int, int]] = []
    for start in range(0, max_address):
        for length in range(32, min(144, max_address - start) + 1):
            score = 0
            ok = True
            for data in dumps.values():
                diffs = [address for address in range(start, start + length) if ready[address] != data[address]]
                if len(diffs) != 2:
                    ok = False
                    break
                a, b = diffs
                swap_like = ready[a] == data[b] and ready[b] == data[a]
                move_like = (data[a] == 0 or data[b] == 0) and (ready[a] == data[b] or ready[b] == data[a])
                if swap_like or move_like:
                    score += 2
                elif ready[a] == data[b] or ready[b] == data[a]:
                    score += 1
                else:
                    ok = False
                    break
            if ok:
                candidates.append((score, start, length))
    candidates.sort(key=lambda item: (-item[0], item[2], item[1]))
    return candidates


def print_candidate_details(ready: bytes, dumps: dict[str, bytes], candidates: list[tuple[int, int, int]]) -> None:
    print("board-like candidate ranges:")
    for _, start, length in candidates[:20]:
        print(f"  ${start:04x}-${start + length - 1:04x} ({length} bytes)")
        for move, data in dumps.items():
            diffs = [address for address in range(start, start + length) if ready[address] != data[address]]
            detail = " ".join(
                f"${address:04x}:{ready[address]:02x}->{data[address]:02x}"
                for address in diffs
            )
            print(f"    {move}: {detail}")
    if not candidates:
        print("  none found")


def infer_square_indexes(ready: bytes, dumps: dict[str, bytes], start: int, length: int) -> None:
    print(f"\nrelative index clues for ${start:04x}-${start + length - 1:04x}:")
    for move, data in dumps.items():
        diffs = [address for address in range(start, start + length) if ready[address] != data[address]]
        if len(diffs) != 2:
            print(f"  {move}: expected 2 diffs, got {len(diffs)}")
            continue
        from_address, to_address = diffs
        if ready[from_address] == data[to_address]:
            source, dest = from_address, to_address
        elif ready[to_address] == data[from_address]:
            source, dest = to_address, from_address
        else:
            source, dest = from_address, to_address
        print(
            f"  {move}: source index={source - start:02x} dest index={dest - start:02x} "
            f"piece={fmt(ready[source])} empty={fmt(ready[dest])}"
        )


def square_offset(square: str) -> int:
    file_index = ord(square[0]) - ord("a")
    rank = int(square[1])
    return BOARD_ORIGIN + (8 - rank) * BOARD_STRIDE + file_index


def decode_board(data: bytes) -> list[str]:
    rows: list[str] = []
    for rank in range(8, 0, -1):
        chars = []
        for file_index in range(8):
            offset = square_offset(chr(ord("a") + file_index) + str(rank))
            chars.append(PIECES.get(data[BOARD_BASE + offset], "?"))
        rows.append(f"{rank} " + " ".join(chars))
    rows.append("  a b c d e f g h")
    return rows


def print_board_states(ready: bytes, dumps: dict[str, bytes], extra: dict[str, bytes]) -> None:
    print("\nboard at $a700:")
    print("ready:")
    for row in decode_board(ready):
        print(f"  {row}")
    for move, data in dumps.items():
        print(f"{move}:")
        for row in decode_board(data):
            print(f"  {row}")
        from_square = move[:2]
        to_square = move[2:4]
        from_addr = BOARD_BASE + square_offset(from_square)
        to_addr = BOARD_BASE + square_offset(to_square)
        print(
            f"  {from_square} ${from_addr:04x}: {ready[from_addr]:02x}->{data[from_addr]:02x}; "
            f"{to_square} ${to_addr:04x}: {ready[to_addr]:02x}->{data[to_addr]:02x}"
        )
    for tag, data in extra.items():
        print(f"{tag}:")
        for row in decode_board(data):
            print(f"  {row}")


def main() -> int:
    args = parse_args()
    ready = load_dump(args.runtime_dir, "ready")
    dumps = {move: load_dump(args.runtime_dir, f"after_{move}") for move in args.moves}
    extra = {tag: load_dump(args.runtime_dir, tag) for tag in args.extra_tags}

    print_diff_summary(ready, dumps, args.max_address)
    candidates = candidate_board_ranges(ready, dumps, args.max_address)
    print_candidate_details(ready, dumps, candidates)
    if candidates:
        _, start, length = candidates[0]
        infer_square_indexes(ready, dumps, start, length)
    infer_square_indexes(ready, dumps, 0x0002, 0x0080)
    print_board_states(ready, dumps, extra)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
