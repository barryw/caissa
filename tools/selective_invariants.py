#!/usr/bin/env python3
"""Deterministic invariant suite for the SELECTIVE search (Phase-2 safety bar).

Selective search is a forward-pruning policy: it is NOT node-exact to full-width,
so it cannot be guarded by the golden node-count gate. Instead it must satisfy
three hard invariants on EVERY position it is asked about:

  1. RETURNS A MOVE   -- the subprocess prints a `bestmove <uci>` line.
  2. LEGAL            -- that move is legal in the position (validated by python-chess).
  3. TERMINATES       -- the search finishes within a per-position timeout (a hang
                         / non-termination is caught, not allowed to block forever).

Any violation (illegal move, missing move, or timeout) -> nonzero exit. This is the
non-negotiable bar: a pruning bug that drops the only legal escape, or that fails
to return / loops, must fail this suite.

Build: by default this script does a CLEAN build of the selective engine itself
(`make clean` then `make SEARCH=selective cli` -> build/cref). The clean is REQUIRED
because the Makefile reuses stale objects when only SEARCH changes. Pass an existing
binary with `--cref PATH` to skip the build (the caller is then responsible for
having built the selective engine).

Corpus: openings + sparse endgames from the repo's FEN files, deduped. python-chess
rejects malformed FENs (skipped, not counted); every VALID position must pass.

Usage:
  python3 -u tools/selective_invariants.py
  python3 -u tools/selective_invariants.py --cref build/cref --depth 6 --timeout 60
"""
import argparse
import os
import subprocess
import sys

try:
    import chess
except ImportError:
    print("FATAL: python-chess not installed (pip install chess)", file=sys.stderr)
    sys.exit(2)

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# FEN corpus sources (relative to repo root). The two named in the task plus extra
# breadth: openings_big (2000 balanced openings), the bench regression set
# (openings + tactical middlegames), and the 3-man endgame corpus (sparse endgames).
CORPUS_FILES = [
    "data/stockfish_opening_fens.txt",
    "data/egtb_3man_corpus.txt",
    "data/openings_big.txt",
    "tools/llvmmos_bench/regression_fens.txt",
]

# Cap so the run stays a few minutes, not hours; openings_big alone is 2000 lines.
MAX_POSITIONS = 400


def log(*a):
    print(*a, flush=True)


def build_selective():
    """Clean build of the selective engine. Returns the binary path."""
    log("building selective cref (clean + SEARCH=selective cli) ...")
    subprocess.run(["make", "-s", "clean"], cwd=REPO, check=True)
    subprocess.run(["make", "-s", "SEARCH=selective", "cli"], cwd=REPO, check=True)
    binpath = os.path.join(REPO, "build", "cref")
    if not os.path.isfile(binpath):
        log("FATAL: build did not produce build/cref")
        sys.exit(2)
    return binpath


def load_corpus():
    """Load + dedup valid FENs from the corpus files. Returns list[str]."""
    seen = set()
    fens = []
    for rel in CORPUS_FILES:
        path = os.path.join(REPO, rel)
        if not os.path.isfile(path):
            log("WARNING: corpus file missing, skipping: %s" % rel)
            continue
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                # python-chess validates; malformed FENs are skipped (not counted).
                try:
                    chess.Board(line)
                except (ValueError, Exception):
                    continue
                # dedup on the piece-placement+stm+castling+ep prefix (ignore clocks)
                key = " ".join(line.split()[:4])
                if key in seen:
                    continue
                seen.add(key)
                fens.append(line)
                if len(fens) >= MAX_POSITIONS:
                    return fens
    return fens


def parse_bestmove(stdout):
    """Extract the uci move from a `bestmove <uci> ...` line, or None."""
    for line in stdout.splitlines():
        line = line.strip()
        if line.startswith("bestmove"):
            parts = line.split()
            if len(parts) >= 2:
                return parts[1]
    return None


def main():
    ap = argparse.ArgumentParser(description="Selective-search invariant suite.")
    ap.add_argument("--cref", default=None,
                    help="path to a prebuilt selective cref (default: clean-build it)")
    ap.add_argument("--depth", type=int, default=6, help="search depth (default 6)")
    ap.add_argument("--timeout", type=float, default=60.0,
                    help="per-position timeout seconds (default 60)")
    args = ap.parse_args()

    cref = args.cref if args.cref else build_selective()
    cref = os.path.abspath(cref)
    if not os.path.isfile(cref):
        log("FATAL: cref binary not found: %s" % cref)
        sys.exit(2)

    fens = load_corpus()
    if not fens:
        log("FATAL: no valid FENs loaded from corpus")
        sys.exit(2)
    log("loaded %d valid positions; depth=%d timeout=%.0fs binary=%s"
        % (len(fens), args.depth, args.timeout, cref))

    total = 0
    returned = 0
    legal = 0
    timeouts = 0
    illegal_cases = []
    missing_cases = []
    timeout_cases = []

    for i, fen in enumerate(fens):
        total += 1
        try:
            r = subprocess.run(
                [cref, "bestmove", fen, str(args.depth)],
                cwd=REPO, capture_output=True, text=True,
                timeout=args.timeout,
            )
        except subprocess.TimeoutExpired:
            timeouts += 1
            timeout_cases.append(fen)
            log("[%d/%d] TIMEOUT (>%.0fs): %s" % (i + 1, len(fens), args.timeout, fen))
            continue

        uci = parse_bestmove(r.stdout)
        if uci is None:
            missing_cases.append((fen, r.returncode, r.stdout.strip(), r.stderr.strip()))
            log("[%d/%d] NO MOVE RETURNED (rc=%d): %s" % (i + 1, len(fens), r.returncode, fen))
            continue
        returned += 1

        board = chess.Board(fen)
        try:
            move = chess.Move.from_uci(uci)
        except ValueError:
            move = None
        if move is not None and move in board.legal_moves:
            legal += 1
        else:
            illegal_cases.append((fen, uci))
            log("[%d/%d] ILLEGAL MOVE %s: %s" % (i + 1, len(fens), uci, fen))

        if (i + 1) % 50 == 0:
            log("  ... %d/%d checked (legal=%d returned=%d timeouts=%d)"
                % (i + 1, len(fens), legal, returned, timeouts))

    log("")
    log("=== SUMMARY ===")
    log("%d/%d positions: legal=%d returned=%d timeouts=%d"
        % (total, total, legal, returned, timeouts))

    violations = 0
    if legal != total:
        violations += 1
        log("FAIL: %d position(s) did not yield a LEGAL move" % (total - legal))
        for fen, uci in illegal_cases:
            log("  illegal: %s -> %s" % (uci, fen))
        for fen, rc, out, err in missing_cases:
            log("  no-move (rc=%d): %s  [stderr: %s]" % (rc, fen, err[:120]))
    if timeouts:
        violations += 1
        log("FAIL: %d timeout(s)" % timeouts)
        for fen in timeout_cases:
            log("  timeout: %s" % fen)

    if violations:
        log("RESULT: FAIL (%d violation categor%s)"
            % (violations, "y" if violations == 1 else "ies"))
        sys.exit(1)

    log("RESULT: PASS -- every valid position returned a legal move within the timeout")
    sys.exit(0)


if __name__ == "__main__":
    main()
