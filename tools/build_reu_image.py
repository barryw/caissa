#!/usr/bin/env python3
"""build_reu_image.py -- assemble a VICE REU image that preloads the EGTB tables.

The on-chip EGTB probe (src/egtb.c, CREF_TT_REU build) reads the 3-man tablebase
from the REU just ABOVE the transposition table. To validate that DMA read path on
real emulation we don't need the (harder) on-hardware loader yet -- we hand VICE a
REU image so the table is already in REU RAM at boot, then run the search and check
every move/score against a host oracle.

REU image layout (matches egtb.c CREF_EGTB_REU_BASE + the kk_idx tail):

    offset 0                : transposition table region (TT_SIZE*12 bytes, left 0 --
                              the search clears + writes it in emulated RAM)
    CREF_EGTB_REU_BASE      : the 3-man DTM tables, verbatim from egtb_tables.bin
      = (1<<TT_BITS)*12       (EGTB_TOTAL_BYTES = 340992)
    +EGTB_TOTAL_BYTES       : kk_idx[4096] as little-endian u16 (egtb.c DMAs this
                              instead of carrying the 8 KB const in low RAM)
    ...                     : zero-padded to --size-kib (default 512 KiB)

kk_idx is read from the GENERATED src/egtb_tables.h (same artifact as the .bin), so
this stays a single source of truth -- regenerate both with tools/egtb_gen.py.

    tools/build_reu_image.py            -> build/egtb_reu.img (TT13, 512 KiB)
    tools/build_reu_image.py --tt-bits 13 --size-kib 512 --out build/egtb_reu.img

Attach it in VICE: x64sc -reu -reusize 512 -reuimage build/egtb_reu.img +reuimagerw
(+reuimagerw keeps the file read-only; emulated REU RAM stays writable for the TT).
tools/reu_validate.py passes it via CAISSA_REUIMAGE.
"""
from __future__ import annotations
import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]


def parse_define(text: str, name: str) -> int:
    m = re.search(rf"#define\s+{name}\s+(\d+)", text)
    if not m:
        raise SystemExit(f"{name} not found in egtb_tables.h")
    return int(m.group(1))


def parse_kk_idx(text: str) -> list[int]:
    """Extract the egtb_kk_idx[] initializer ints from the generated header."""
    m = re.search(r"egtb_kk_idx\s*\[[^\]]*\]\s*=\s*\{(.*?)\};", text, re.DOTALL)
    if not m:
        raise SystemExit("egtb_kk_idx[] initializer not found in egtb_tables.h")
    vals = [int(x) for x in re.findall(r"\d+", m.group(1))]
    return vals


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bin", default=str(REPO / "build" / "egtb_tables.bin"))
    ap.add_argument("--header", default=str(REPO / "src" / "egtb_tables.h"))
    ap.add_argument("--tt-bits", type=int, default=13,
                    help="must match the REU+EGTB build's CREF_TT_BITS (default 13)")
    ap.add_argument("--size-kib", type=int, default=512)
    ap.add_argument("--out", default=str(REPO / "build" / "egtb_reu.img"))
    a = ap.parse_args(argv)

    header = Path(a.header).read_text()
    total = parse_define(header, "EGTB_TOTAL_BYTES")
    kk = parse_kk_idx(header)
    if len(kk) != 64 * 64:
        raise SystemExit(f"kk_idx has {len(kk)} entries, expected {64*64}")

    tables = Path(a.bin).read_bytes()
    if len(tables) != total:
        raise SystemExit(f"{a.bin} is {len(tables)} bytes, header says EGTB_TOTAL_BYTES={total}")

    base = (1 << a.tt_bits) * 12               # CREF_EGTB_REU_BASE (TTEntry == 12 B)
    size = a.size_kib * 1024
    kk_bytes = b"".join(int(v & 0xFFFF).to_bytes(2, "little") for v in kk)

    end = base + len(tables) + len(kk_bytes)
    if end > size:
        raise SystemExit(
            f"layout needs {end} bytes (TT base {base} + tables {len(tables)} + "
            f"kk_idx {len(kk_bytes)}) but image is only {size} -- raise --size-kib "
            f"or lower --tt-bits")

    img = bytearray(size)                       # zero-filled (TT region stays 0)
    img[base:base + len(tables)] = tables
    img[base + len(tables):end] = kk_bytes

    Path(a.out).write_bytes(img)
    print(f"wrote {a.out}: {size} bytes ({a.size_kib} KiB REU)")
    print(f"  TT region    [0 .. {base})            ({base} bytes, TT{a.tt_bits}, zeroed)")
    print(f"  EGTB tables  [{base} .. {base+len(tables)})   ({len(tables)} bytes)")
    print(f"  kk_idx       [{base+len(tables)} .. {end})   ({len(kk_bytes)} bytes, LE u16)")
    print(f"  free above   [{end} .. {size})            ({size-end} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
