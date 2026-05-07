#!/usr/bin/env python3
"""Report ld65 segment sizes and broad symbol range for the engine harness."""
from __future__ import annotations

import argparse
import re
from pathlib import Path

SEG_RE = re.compile(r'^seg\tid=\d+,name="(?P<name>[^"]+)",start=0x(?P<start>[0-9a-fA-F]+),size=0x(?P<size>[0-9a-fA-F]+)')
SYM_RE = re.compile(r'^sym\t.*?name="(?P<name>[^"]+)".*?val=0x(?P<value>[0-9a-fA-F]+).*?type=lab')


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Report engine harness sizes from an ld65 debug file.")
    parser.add_argument("dbg", nargs="?", type=Path, default=Path("build/engine_harness.dbg"))
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not args.dbg.exists():
        raise SystemExit(f"Missing debug file: {args.dbg}")
    segments = []
    labels = []
    for line in args.dbg.read_text().splitlines():
        seg = SEG_RE.match(line)
        if seg:
            size = int(seg.group("size"), 16)
            if size:
                segments.append((seg.group("name"), int(seg.group("start"), 16), size))
            continue
        sym = SYM_RE.match(line)
        if sym:
            labels.append((sym.group("name"), int(sym.group("value"), 16)))

    print("Segment sizes:")
    total = 0
    for name, start, size in sorted(segments, key=lambda item: item[1]):
        total += size
        print(f"  {name:8} ${start:04x}-${start + size - 1:04x} {size:6} bytes")
    print(f"  {'TOTAL':8} {'':11} {total:6} bytes")

    code_labels = [(name, value) for name, value in labels if 0x0801 <= value < 0xa000]
    if code_labels:
        low = min(value for _name, value in code_labels)
        high = max(value for _name, value in code_labels)
        print(f"Label span: ${low:04x}-${high:04x}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
