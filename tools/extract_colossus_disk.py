#!/usr/bin/env python3
"""Extract Colossus Chess 4 PRGs from the D64 into build/colossus_extract."""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
from pathlib import Path


DEFAULT_D64_CANDIDATES = (
    Path.home() / "Downloads" / "Colossus-Chess-4_C64_EN" / "COLOSS40.D64",
    Path.home() / "Downloads" / "Colossus_Chess_4-[manik].d64",
)
DEFAULT_D64 = next((path for path in DEFAULT_D64_CANDIDATES if path.exists()), DEFAULT_D64_CANDIDATES[0])
DEFAULT_OUTPUT_DIR = Path("build") / "colossus_extract" / "prgs"
DEFAULT_FILES = (
    "colossus 4.0 (t)",
    "colossus dox",
    "colossus 4.0 (d)",
    "part1",
    "part2",
    "part3",
)
KNOWN_C1541_PATHS = (
    Path("/Users/barry/Git/vice-mcp/vice/build-headless/src/c1541"),
    Path("/Users/barry/Git/vice-mcp/vice/build-test-with-mcp/src/c1541"),
    Path("/Users/barry/Git/vice-mcp/vice/build-test-no-mcp/src/c1541"),
)
LISTING_RE = re.compile(r'^\s*(\d+)\s+"([^"]*)"\s+([a-z]+)\s*$', re.IGNORECASE)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--d64", type=Path, default=Path(os.environ.get("COLOSSUS_D64", DEFAULT_D64)))
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--c1541", type=Path, default=None, help="Path to c1541; auto-detected if omitted.")
    parser.add_argument("--include-books", action="store_true", help="Also extract gNN opening/book files.")
    parser.add_argument("--list-only", action="store_true", help="Print the disk listing and exit.")
    return parser.parse_args()


def find_c1541(explicit: Path | None) -> Path:
    candidates: list[Path] = []
    if explicit is not None:
        candidates.append(explicit)
    if os.environ.get("C1541"):
        candidates.append(Path(os.environ["C1541"]))
    candidates.extend(KNOWN_C1541_PATHS)
    found = shutil.which("c1541")
    if found:
        candidates.append(Path(found))

    for candidate in candidates:
        if candidate.exists() and os.access(candidate, os.X_OK):
            return candidate
    raise FileNotFoundError("could not find c1541; build VICE MCP or pass --c1541")


def c1541_output(c1541: Path, d64: Path, *commands: str) -> str:
    result = subprocess.run(
        [str(c1541), str(d64), *commands],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    return result.stdout


def parse_listing(text: str) -> list[str]:
    files: list[str] = []
    for line in text.splitlines():
        match = LISTING_RE.match(line)
        if not match:
            continue
        file_type = match.group(3).lower()
        name = match.group(2).rstrip()
        if file_type == "prg" and name:
            files.append(name)
    return files


def safe_name(name: str) -> str:
    cleaned = re.sub(r"[^a-z0-9]+", "_", name.strip().lower()).strip("_")
    return f"{cleaned or 'file'}.prg"


def main() -> int:
    args = parse_args()
    if not args.d64.exists():
        raise FileNotFoundError(f"missing Colossus D64: {args.d64}")

    c1541 = find_c1541(args.c1541)
    listing = c1541_output(c1541, args.d64, "-list")
    print(listing.rstrip())
    if args.list_only:
        return 0

    available = parse_listing(listing)
    wanted = list(DEFAULT_FILES)
    if args.include_books:
        wanted.extend(name for name in available if re.fullmatch(r"g\d+", name.strip(), re.IGNORECASE))

    args.output_dir.mkdir(parents=True, exist_ok=True)
    missing = [name for name in wanted if name not in available]
    if missing:
        raise RuntimeError(f"missing expected disk files: {', '.join(missing)}")

    for name in wanted:
        destination = args.output_dir / safe_name(name)
        output = c1541_output(c1541, args.d64, "-read", name, str(destination))
        print(output.rstrip())
        print(f"extracted {name!r} -> {destination}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
