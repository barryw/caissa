#!/usr/bin/env python3
"""Summarize Colossus PRG and runtime RAM layout."""

from __future__ import annotations

import argparse
import difflib
import json
import re
from pathlib import Path


DEFAULT_PRG_DIR = Path("build") / "colossus_extract" / "prgs"
DEFAULT_READY_RAM = Path("build") / "colossus_extract" / "runtime" / "ready.ram.bin"
DEFAULT_AFTER_RAM = Path("build") / "colossus_extract" / "runtime" / "after_e2e4.ram.bin"
DEFAULT_RUNTIME_DIR = Path("build") / "colossus_extract" / "runtime"
DEFAULT_REPORT = Path("build") / "colossus_extract" / "analysis.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prg-dir", type=Path, default=DEFAULT_PRG_DIR)
    parser.add_argument("--ready-ram", type=Path, default=DEFAULT_READY_RAM)
    parser.add_argument("--after-ram", type=Path, default=DEFAULT_AFTER_RAM)
    parser.add_argument("--runtime-dir", type=Path, default=DEFAULT_RUNTIME_DIR)
    parser.add_argument("--json", type=Path, default=DEFAULT_REPORT)
    return parser.parse_args()


def contiguous_ranges(offsets: list[int]) -> list[dict[str, int]]:
    if not offsets:
        return []
    ranges: list[dict[str, int]] = []
    start = prev = offsets[0]
    for offset in offsets[1:]:
        if offset == prev + 1:
            prev = offset
            continue
        ranges.append({"start": start, "end": prev, "size": prev - start + 1})
        start = prev = offset
    ranges.append({"start": start, "end": prev, "size": prev - start + 1})
    return ranges


def non_fill_ranges(data: bytes, fill: int = 0) -> list[dict[str, int]]:
    return contiguous_ranges([index for index, value in enumerate(data) if value != fill])


def load_prg(path: Path) -> dict[str, object]:
    data = path.read_bytes()
    if len(data) < 2:
        raise ValueError(f"{path} is too small to be a PRG")
    load = data[0] | (data[1] << 8)
    payload = data[2:]
    return {
        "path": str(path),
        "name": path.name,
        "load": load,
        "size": len(payload),
        "end": load + len(payload) - 1,
        "payload": payload,
    }


def compare_at_load(prg: dict[str, object], ram: bytes) -> dict[str, object]:
    load = int(prg["load"])
    payload = prg["payload"]
    assert isinstance(payload, bytes)
    if load + len(payload) > len(ram):
        return {"matches": 0, "size": len(payload), "ratio": 0.0, "first_mismatch": load}
    ram_slice = ram[load : load + len(payload)]
    matches = sum(1 for left, right in zip(payload, ram_slice) if left == right)
    first_mismatch = next((load + index for index, (left, right) in enumerate(zip(payload, ram_slice)) if left != right), None)
    return {
        "matches": matches,
        "size": len(payload),
        "ratio": matches / len(payload) if payload else 1.0,
        "first_mismatch": first_mismatch,
    }


def find_payload_chunks(prg: dict[str, object], ram: bytes, chunk_size: int = 32, limit: int = 12) -> list[dict[str, int]]:
    payload = prg["payload"]
    assert isinstance(payload, bytes)
    hits: list[dict[str, int]] = []
    seen: set[tuple[int, int]] = set()
    for offset in range(0, max(0, len(payload) - chunk_size + 1), chunk_size):
        chunk = payload[offset : offset + chunk_size]
        if chunk.count(chunk[:1]) == len(chunk):
            continue
        address = ram.find(chunk)
        if address < 0:
            continue
        key = (offset, address)
        if key in seen:
            continue
        seen.add(key)
        hits.append({"prg_offset": offset, "ram_address": address, "size": chunk_size})
        if len(hits) >= limit:
            break
    return hits


def changed_ranges(before: bytes, after: bytes) -> list[dict[str, int]]:
    return contiguous_ranges([index for index, (left, right) in enumerate(zip(before, after)) if left != right])


def load_meta(path: Path) -> dict[str, object]:
    meta = sibling_artifact(path, ".json")
    if not meta.exists():
        return {}
    return json.loads(meta.read_text(encoding="utf-8"))


def sibling_artifact(path: Path, suffix: str) -> Path:
    name = path.name
    if name.endswith(".ram.bin"):
        name = name[: -len(".ram.bin")]
    else:
        name = path.stem
    return path.with_name(name + suffix)


def format_addr(value: int | None) -> str:
    return "none" if value is None else f"${value:04x}"


def main() -> int:
    args = parse_args()
    ready = args.ready_ram.read_bytes()
    after = args.after_ram.read_bytes() if args.after_ram.exists() else b""
    prgs = [load_prg(path) for path in sorted(args.prg_dir.glob("*.prg"))]

    report: dict[str, object] = {
        "ready_ram": str(args.ready_ram),
        "after_ram": str(args.after_ram) if args.after_ram.exists() else None,
        "ready_meta": load_meta(args.ready_ram),
        "after_meta": load_meta(args.after_ram) if args.after_ram.exists() else {},
        "prgs": [],
        "ready_nonzero_ranges": non_fill_ranges(ready),
        "changed_ranges": changed_ranges(ready, after) if after else [],
    }

    print("PRGs:")
    for prg in prgs:
        at_load = compare_at_load(prg, ready)
        chunks = find_payload_chunks(prg, ready)
        item = {
            "name": prg["name"],
            "path": prg["path"],
            "load": prg["load"],
            "end": prg["end"],
            "size": prg["size"],
            "ready_match_at_load": at_load,
            "ready_chunk_hits": chunks,
        }
        report["prgs"].append(item)
        print(
            f"  {prg['name']}: load=${int(prg['load']):04x} "
            f"size={int(prg['size']):5d} end=${int(prg['end']):04x} "
            f"ready-match={at_load['matches']}/{at_load['size']} "
            f"first-mismatch={format_addr(at_load['first_mismatch'])}"
        )
        for hit in chunks[:4]:
            print(f"    chunk prg+${hit['prg_offset']:04x} -> ram ${hit['ram_address']:04x}")

    if after:
        ranges = report["changed_ranges"]
        assert isinstance(ranges, list)
        print("\nReady -> after_e2e4 changed ranges:")
        for item in ranges[:40]:
            print(f"  ${item['start']:04x}-${item['end']:04x} ({item['size']} bytes)")
        if len(ranges) > 40:
            print(f"  ... {len(ranges) - 40} more")

        ready_screen_path = sibling_artifact(args.ready_ram, ".screen.txt")
        after_screen_path = sibling_artifact(args.after_ram, ".screen.txt")
        before_screen = ready_screen_path.read_text(encoding="utf-8", errors="replace")
        after_screen = after_screen_path.read_text(encoding="utf-8", errors="replace")
        diff = list(
            difflib.unified_diff(
                before_screen.splitlines(),
                after_screen.splitlines(),
                fromfile=ready_screen_path.name,
                tofile=after_screen_path.name,
                lineterm="",
            )
        )
        report["screen_diff"] = diff

    args.json.parent.mkdir(parents=True, exist_ok=True)
    def scrub(value: object) -> object:
        if isinstance(value, bytes):
            return f"<{len(value)} bytes>"
        if isinstance(value, list):
            return [scrub(item) for item in value]
        if isinstance(value, dict):
            return {str(key): scrub(item) for key, item in value.items() if key != "payload"}
        return value

    args.json.write_text(json.dumps(scrub(report), indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"\nwrote {args.json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
