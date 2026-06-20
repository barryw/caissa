#!/usr/bin/env python3
"""reu_validate.py -- validate the C64 REU-backed TT engine on REAL emulated hardware.

The REU profile (CREF_PROFILE_REU) hosts the transposition table in the RAM
Expansion Unit via $DF00 DMA. Structural checks and isolated DMA round-trip tests
(test/reu_dma_test.c, test/reu_stress3_test.c) are NECESSARY but NOT SUFFICIENT:
the IRQ-during-DMA-setup bug fixed in src/search.c reu_xfer passed every isolated
test yet corrupted a real search. The only trustworthy check is to run the actual
search inside x64sc -reu and compare every best move (and node count) to a matched
host oracle.

Oracle = cref built with the SAME profile but the DMA disabled (flat in-RAM shim):
    cc -DCREF_PROFILE_REU -DCREF_TT_REU=0 ... apps/cli/cref.c -o <oracle>
6502 server = caissa_server.prg built with -DCREF_PROFILE_REU (real $DF00 DMA),
driven by tools/vice_caissa.py with CAISSA_REU=1 (attaches -reu -reusize 512).

Move-exactness is the project's validation bar (the same one the Ultimate profile
shipped on). Node counts also match at d4; at d5+ the MAX_PLY-8 profiles show a
pre-existing 6502-vs-host node-ORDERING divergence (moves stay correct) that is
independent of the REU -- see docs/xram-tt-design.md.

Usage:
    tools/reu_validate.py --oracle /tmp/cref_reu_oracle --prg build/caissa_server_reu.prg \\
        --depth 4 --fens data/...   [--port 6611] [--x64sc /tmp/x64sc_stable]
"""
from __future__ import annotations
import argparse, json, os, subprocess, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))


def load_fens(spec: str, limit: int) -> list[str]:
    p = Path(spec)
    if p.suffix == ".json":
        fens = [x["fen"] for x in json.loads(p.read_text())["positions"]]
    else:
        fens = [l.strip() for l in p.read_text().splitlines() if l.strip()]
    seen, uniq = set(), []
    for f in fens:
        if f not in seen:
            seen.add(f); uniq.append(f)
    return uniq[:limit] if limit else uniq


def oracle_move(oracle: str, fen: str, depth: int) -> tuple[str, int]:
    t = subprocess.run([oracle, "bestmove", fen, str(depth)],
                       capture_output=True, text=True).stdout.split()
    return t[1], int(t[t.index("nodes") + 1])


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--oracle", required=True, help="host cref built with -DCREF_TT_REU=0")
    ap.add_argument("--prg", required=True, help="caissa_server.prg built with -DCREF_PROFILE_REU")
    ap.add_argument("--fens", required=True, help="FEN list (.txt) or strength corpus (.json)")
    ap.add_argument("--depth", type=int, default=4)
    ap.add_argument("--limit", type=int, default=12)
    ap.add_argument("--port", type=int, default=6611)
    ap.add_argument("--x64sc", default="/tmp/x64sc_stable")
    ap.add_argument("--reusize", default="512")
    a = ap.parse_args(argv)

    os.environ["CAISSA_REU"] = "1"
    os.environ["CAISSA_REUSIZE"] = a.reusize
    from vice_caissa import CaissaServer  # imported after CAISSA_REU is set

    fens = load_fens(a.fens, a.limit)
    mm = mn = 0
    with CaissaServer(prg=a.prg, port=a.port, x64sc=a.x64sc) as srv:
        for i, fen in enumerate(fens):
            r = srv.bestmove(fen, a.depth, timeout=300)
            ou, on = oracle_move(a.oracle, fen, a.depth)
            mvok, ndok = r["uci"] == ou, r["nodes"] == on
            mm += not mvok; mn += not ndok
            tag = "OK   " if mvok and ndok else ("MOVE!" if not mvok else "nodes")
            print(f"[{tag}] {i:2d} reu={r['uci']:6s} n={r['nodes']:6d} | "
                  f"orc={ou:6s} n={on:6d} | {fen}")
    print(f"\n=== {len(fens)} FENs @ d{a.depth}: "
          f"move-mismatch={mm}  node-mismatch={mn} ===")
    return 1 if mm else 0  # move mismatch = FAIL; node mismatch = warn (see docstring)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
