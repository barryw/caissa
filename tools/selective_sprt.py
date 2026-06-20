#!/usr/bin/env python3
"""selective_sprt.py -- selective vs full-width self-play at a FIXED node budget.

THE GATE for the Phase-2 selective-search bet (Task 6): does the selective
(Colossus-style forward-pruning) search beat the full-width search when both are
capped at the SAME nodes/move -- the regime a stock 1 MHz C64 actually plays in?

Engine A = selective, engine B = full-width. Both play `CAISSA_NODE_BUDGET=<B>
<engine> bestmove <fen> 64`, so the node budget (not depth) is the binding limit
and the iterative-deepening driver returns the best move from the last COMPLETED
iteration. The two engines are deterministic, so games are diversified by the
opening (each opening played twice, colours swapped, for colour balance).

Build (clean -- the Makefile reuses stale objects when only SEARCH changes):
  make -s clean && make -s SEARCH=selective cli && cp build/cref /tmp/cref_selective
  make -s clean && make -s            cli && cp build/cref /tmp/cref_fullwidth
This script does that for you unless --skip-build is given (then it reuses the
two /tmp paths).

Usage:
  python3 tools/selective_sprt.py --games 50 --nodes 30000 --jobs 8

Reports selective's W-L-D, score%, Elo +- err (Wilson), LOS, an SPRT LLR
verdict, and the effective search depth each engine reached at that budget
(selective should reach DEEPER -- that is the whole mechanism).
"""
import argparse
import math
import os
import subprocess
import sys
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import chess

ROOT = Path(__file__).resolve().parent.parent
SEL_BIN = Path("/tmp/cref_selective")
FW_BIN = Path("/tmp/cref_fullwidth")

_MAT = {chess.PAWN: 100, chess.KNIGHT: 320, chess.BISHOP: 330,
        chess.ROOK: 500, chess.QUEEN: 900}


def material_cp(b: chess.Board) -> int:
    t = 0
    for pt, v in _MAT.items():
        t += v * (len(b.pieces(pt, chess.WHITE)) - len(b.pieces(pt, chess.BLACK)))
    return t


def build_engines() -> None:
    """Clean-build selective + full-width to distinct /tmp paths, verify they differ."""
    def run(cmd):
        r = subprocess.run(cmd, cwd=ROOT, shell=True,
                           capture_output=True, text=True)
        if r.returncode != 0:
            sys.stderr.write(r.stdout + r.stderr)
            raise SystemExit(f"build failed: {cmd}")
    print("building selective ...", flush=True)
    run("make -s clean && make -s SEARCH=selective cli && cp build/cref /tmp/cref_selective")
    print("building full-width ...", flush=True)
    run("make -s clean && make -s cli && cp build/cref /tmp/cref_fullwidth")
    if SEL_BIN.read_bytes() == FW_BIN.read_bytes():
        raise SystemExit("ERROR: selective and full-width binaries are IDENTICAL "
                         "(stale objects?) -- aborting, the match would be meaningless.")
    print("OK: the two engines differ.", flush=True)


def engine_move(engine: Path, fen: str, budget: int):
    """Returns (move_or_None, depth_reached). budget via CAISSA_NODE_BUDGET, depth 64."""
    env = dict(os.environ, CAISSA_NODE_BUDGET=str(budget))
    out = subprocess.run([str(engine), "bestmove", fen, "64"],
                         capture_output=True, text=True, env=env).stdout
    if not out.startswith("bestmove"):
        return None, 0
    parts = out.split()
    try:
        mv = chess.Move.from_uci(parts[1])
    except (ValueError, IndexError):
        return None, 0
    depth = 0
    try:
        depth = int(parts[parts.index("depth") + 1])
    except (ValueError, IndexError):
        pass
    return mv, depth


def play_game(arg: dict) -> dict:
    """One game. Returns selective's score (1/0.5/0), term, plies, and per-engine
    depth stats (sum + count, so the caller can average depth reached)."""
    fen = arg["fen"]
    sel_white = arg["sel_white"]
    budget = arg["budget"]
    max_plies = arg["max_plies"]
    adj_cp = arg["adj_cp"]
    board = chess.Board(fen)
    sel_dsum = sel_dn = fw_dsum = fw_dn = 0
    illegal_by = None  # "selective" / "fullwidth" if a side produces a bad move

    while not board.is_game_over(claim_draw=True) and board.ply() < max_plies:
        sel_turn = (board.turn == chess.WHITE) == sel_white
        engine = SEL_BIN if sel_turn else FW_BIN
        mv, depth = engine_move(engine, board.fen(), budget)
        if mv is None or mv not in board.legal_moves:
            illegal_by = "selective" if sel_turn else "fullwidth"
            break
        if sel_turn:
            sel_dsum += depth; sel_dn += 1
        else:
            fw_dsum += depth; fw_dn += 1
        board.push(mv)

    if illegal_by is not None:
        # offending engine loses; should never happen (invariants passed) but guarded.
        sel_score = 0.0 if illegal_by == "selective" else 1.0
        term = f"illegal-{illegal_by}"
    elif board.is_game_over(claim_draw=True):
        res = board.result(claim_draw=True)
        term = board.outcome(claim_draw=True).termination.name.lower() \
            if board.outcome(claim_draw=True) else "gameover"
        sel_score = 0.5 if res == "1/2-1/2" else (1.0 if (res == "1-0") == sel_white else 0.0)
    else:
        # ply cap hit -> adjudicate by material balance.
        bal = material_cp(board)
        if bal >= adj_cp:
            res, term = "1-0", "adj-material"
        elif bal <= -adj_cp:
            res, term = "0-1", "adj-material"
        else:
            res, term = "1/2-1/2", "adj-draw"
        sel_score = 0.5 if res == "1/2-1/2" else (1.0 if (res == "1-0") == sel_white else 0.0)

    return {"score": sel_score, "term": term, "plies": board.ply(),
            "sel_dsum": sel_dsum, "sel_dn": sel_dn,
            "fw_dsum": fw_dsum, "fw_dn": fw_dn,
            "fen": fen, "sel_white": sel_white,
            "san": " ".join(m.uci() for m in board.move_stack[:12])}


# ---- statistics --------------------------------------------------------------
def wilson(s: float, n: int):
    if n == 0:
        return 0.0, 1.0
    z, p = 1.96, s / n
    denom = 1 + z * z / n
    center = (p + z * z / (2 * n)) / denom
    margin = z * math.sqrt(p * (1 - p) / n + z * z / (4.0 * n * n)) / denom
    return max(0.0, center - margin), min(1.0, center + margin)


def elo_diff(rate: float):
    if rate <= 0 or rate >= 1:
        return None
    return -400.0 * math.log10(1.0 / rate - 1.0)


def elo_err(scores):
    """+-error in Elo from the per-game score variance (normal approx)."""
    n = len(scores)
    if n < 2:
        return None
    mean = sum(scores) / n
    var = sum((s - mean) ** 2 for s in scores) / (n - 1)
    se = math.sqrt(var / n)
    lo, hi = mean - 1.96 * se, mean + 1.96 * se
    el = elo_diff(mean)
    elo_lo = elo_diff(min(0.999, max(0.001, lo)))
    elo_hi = elo_diff(min(0.999, max(0.001, hi)))
    if el is None or elo_lo is None or elo_hi is None:
        return el, None
    return el, (elo_hi - elo_lo) / 2.0


def los(wins: int, losses: int) -> float:
    """Likelihood of superiority: P(selective truly stronger). Normal approx on
    the win/loss difference (draws cancel)."""
    if wins + losses == 0:
        return 0.5
    return 0.5 * (1 + math.erf((wins - losses) / math.sqrt(2.0 * (wins + losses))))


def sprt_llr(scores, elo1: float):
    """Simple SPRT LLR, H0: elo=0 vs H1: elo=elo1 (normal approx, same as cref.c)."""
    n = len(scores)
    if n < 2:
        return 0.0
    mu0, mu1 = 0.5, 1.0 / (1.0 + 10 ** (-elo1 / 400.0))
    mean = sum(scores) / n
    var = sum((s - mean) ** 2 for s in scores) / n
    if var < 0.05:
        var = 0.05
    total = sum(scores)
    return (mu1 - mu0) / var * (total - n * (mu0 + mu1) / 2.0)


# ---- opening generation ------------------------------------------------------
def load_openings(path: Path, want: int, seed: int) -> list[str]:
    fens = [ln.strip() for ln in path.read_text().splitlines()
            if ln.strip() and not ln.startswith("#")] if path.exists() else []
    if len(fens) >= want:
        return fens[:want]
    # top up with random shallow openings (distinct, legal) from the start position.
    import random
    rng = random.Random(seed)
    seen = set(fens)
    while len(fens) < want:
        b = chess.Board()
        for _ in range(rng.randint(2, 6)):
            moves = list(b.legal_moves)
            if not moves:
                break
            b.push(rng.choice(moves))
        if b.is_game_over():
            continue
        f = b.fen()
        if f not in seen:
            seen.add(f)
            fens.append(f)
    return fens[:want]


def main(argv):
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--games", type=int, default=50, help="total games (rounded to even pairs)")
    p.add_argument("--nodes", type=int, default=30000, help="node budget per move (B)")
    p.add_argument("--jobs", type=int, default=8)
    p.add_argument("--max-plies", type=int, default=200)
    p.add_argument("--adj-cp", type=int, default=300, help="material adj threshold at ply cap")
    p.add_argument("--sprt-elo1", type=float, default=20.0, help="H1 Elo for the SPRT LLR")
    p.add_argument("--openings", type=Path, default=ROOT / "data" / "selfplay_openings.txt")
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--skip-build", action="store_true", help="reuse existing /tmp/cref_* binaries")
    args = p.parse_args(argv)

    if not args.skip_build:
        build_engines()
    elif not (SEL_BIN.exists() and FW_BIN.exists()):
        raise SystemExit("--skip-build but /tmp/cref_selective or /tmp/cref_fullwidth missing")

    pairs = max(1, args.games // 2)
    fens = load_openings(args.openings, pairs, args.seed)
    if pairs > len(fens):
        sys.stderr.write(f"WARNING: {pairs} pairs > {len(fens)} openings -> some games "
                         f"DUPLICATE (deterministic); reduce --games or add openings.\n")

    tasks = []
    for i in range(pairs):
        for sw in (True, False):           # each opening twice, colours swapped
            tasks.append({"fen": fens[i % len(fens)], "sel_white": sw,
                          "budget": args.nodes, "max_plies": args.max_plies,
                          "adj_cp": args.adj_cp})

    print(f"selective vs full-width: {len(tasks)} games @ {args.nodes} nodes/move, "
          f"jobs={args.jobs}", flush=True)

    results = []
    with ProcessPoolExecutor(max_workers=args.jobs) as ex:
        for i, r in enumerate(ex.map(play_game, tasks), 1):
            results.append(r)
            if i % 10 == 0:
                print(f"  {i}/{len(tasks)} done", flush=True)

    scores = [r["score"] for r in results]
    n = len(scores)
    wins = sum(1 for s in scores if s == 1.0)
    draws = sum(1 for s in scores if s == 0.5)
    losses = sum(1 for s in scores if s == 0.0)
    total = sum(scores)
    rate = total / n if n else 0.0
    lo, hi = wilson(total, n)
    el, eerr = elo_err(scores)
    L = los(wins, losses)
    llr = sprt_llr(scores, args.sprt_elo1)
    bound = math.log((1 - 0.05) / 0.05)

    sel_d = sum(r["sel_dsum"] for r in results) / max(1, sum(r["sel_dn"] for r in results))
    fw_d = sum(r["fw_dsum"] for r in results) / max(1, sum(r["fw_dn"] for r in results))

    print("\n=== RESULT (selective perspective) ===")
    print(f"selective: +{wins} ={draws} -{losses}  "
          f"score {total:.1f}/{n} = {100*rate:.1f}%")
    print(f"Wilson 95%: [{100*lo:.1f}%, {100*hi:.1f}%]")
    if el is not None:
        errstr = f" +- {eerr:.0f}" if eerr is not None else ""
        print(f"Elo diff ~ {el:+.0f}{errstr}")
    else:
        print("Elo diff ~ (degenerate: 0% or 100%)")
    print(f"LOS (P selective stronger): {100*L:.1f}%")
    print(f"SPRT: LLR={llr:+.2f} bound=+-{bound:.2f} -> "
          + ("H1 (selective better)" if llr >= bound
             else "H0 (not better)" if llr <= -bound else "inconclusive"))
    print(f"\nEffective depth reached @ {args.nodes} nodes:  "
          f"selective={sel_d:.2f}  full-width={fw_d:.2f}  (gap {sel_d-fw_d:+.2f} ply)")

    # sanity: legality / termination breakdown + a couple of example games.
    terms = {}
    for r in results:
        terms[r["term"]] = terms.get(r["term"], 0) + 1
    print("\nTermination breakdown:", ", ".join(f"{k}={v}" for k, v in sorted(terms.items())))
    bad = [r for r in results if r["term"].startswith("illegal")]
    if bad:
        print(f"WARNING: {len(bad)} illegal-move game(s)!")
    print("Example games (first 12 plies):")
    for r in results[:2]:
        print(f"  sel_white={r['sel_white']} score={r['score']} term={r['term']} "
              f"plies={r['plies']}: {r['san']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
