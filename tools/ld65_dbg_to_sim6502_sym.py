#!/usr/bin/env python3
"""Convert an ld65 debug file into Sim6502TestRunner's Kick-style .sym file."""
from __future__ import annotations

import re
import sys
from pathlib import Path

SYM_RE = re.compile(r'^sym\t.*?name="([^"]+)".*?val=0x([0-9a-fA-F]+).*?type=(lab|equ)')


def main() -> int:
    if len(sys.argv) != 3:
        print('usage: ld65_dbg_to_sim6502_sym.py <input.dbg> <output.sym>', file=sys.stderr)
        return 2
    dbg_path = Path(sys.argv[1])
    sym_path = Path(sys.argv[2])
    labels = []
    for line in dbg_path.read_text().splitlines():
        match = SYM_RE.match(line)
        if not match:
            continue
        name, value, _kind = match.groups()
        if name.startswith('@'):
            continue
        labels.append((name, int(value, 16)))
    labels.sort(key=lambda item: item[0].lower())
    sym_path.write_text(''.join(f'.label {name}=${value:x}\n' for name, value in labels))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
