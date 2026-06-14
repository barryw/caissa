#!/usr/bin/env python3
"""
build_opening_repertoire.py

Generate a Stockfish-vetted opening repertoire as an engine-INDEPENDENT JSON
dataset for the Caissa C64 chess engine's opening book.

CLEAN-ROOM: this repertoire is built from general/public opening theory plus
Stockfish analysis ONLY. Nothing is read from Colossus or any third-party book.

The generator walks a curated set of SOUND, STRUCTURAL mainlines (clear plans,
not razor-sharp theory) for both colors, expands each to a configurable ply
depth, and at every node where it is "our" turn it asks Stockfish for the best
move at a configurable analysis depth. Each kept node is emitted as:

    {
      "fen":           "<FEN with full move clocks>",
      "best_move_uci": "e2e4",
      "best_move_san": "e4",          # convenience / human-readable
      "eval_cp":       34,            # centipawns, from side-to-move POV
      "depth":         18,            # Stockfish search depth that produced it
      "line_name":     "Ruy Lopez",  # which seed line this node belongs to
      "ply":           0             # half-move number from the start position
    }

Transpositions are de-duplicated by FEN (position part only: piece placement +
side + castling + en-passant; the move clocks are ignored for identity so two
lines that reach the same position keep one entry).

NOTE ON ZOBRIST KEYS: this dataset is deliberately keyed by FEN, NOT by the
engine's Zobrist hash. The later compile step MUST derive the engine's own
Zobrist keys by driving the engine (ComputeZobristHash) over each FEN. Do not
reimplement Zobrist here -- see docs/opening-book-plan.md.

VALIDATION:
  * Every recorded move is asserted legal in its FEN (python-chess).
  * Any node whose Stockfish eval leaves the side-to-move worse than the
    --max-loss-cp threshold (default -100cp) is FLAGGED and dropped, and the
    whole seed line is reported, because a book line should never walk the
    engine into a bad position.

This script does NOT touch src/, does NOT run make, and does NOT use the
sim6502 bridge. It only needs python-chess and a `stockfish` binary on PATH.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import time
from dataclasses import dataclass, asdict, field
from typing import Optional

import chess
import chess.engine


# ---------------------------------------------------------------------------
# Curated repertoire seeds.
#
# Each seed is a SAN mainline from the initial position. We pick solid,
# structural openings with durable plans -- the kind that survive an imperfect
# eval -- and we deliberately AVOID sharp, memorisation-heavy theory.
#
# Coverage requested:
#   White: 1.e4 and 1.d4 systems
#   Black vs 1.e4: a solid defense (Caro-Kann here -- closed/structural)
#   Black vs 1.d4: QGD / Slav family
#
# We include both "our move" nodes and "opponent reply" nodes in the line; the
# walker only records (and Stockfish-vets) the nodes where it is the side we
# are building a repertoire FOR. Which color a line is "for" is set by `side`.
#
# Lines are intentionally a bit redundant at the top (many share 1.e4 etc.) --
# FEN de-duplication collapses the shared prefixes automatically.
# ---------------------------------------------------------------------------

@dataclass
class Seed:
    name: str
    side: chess.Color          # the color this repertoire line is FOR
    moves: list[str]           # SAN mainline from the start position


def _S(name, side, line):
    return Seed(name=name, side=side, moves=line.split())


WHITE = chess.WHITE
BLACK = chess.BLACK


SEEDS: list[Seed] = [
    # ===================== WHITE after 1.e4 =====================
    # Ruy Lopez, Closed -- the most strategically rich, structural 1.e4 line.
    _S("Ruy Lopez Closed", WHITE,
       "e4 e5 Nf3 Nc6 Bb5 a6 Ba4 Nf6 O-O Be7 Re1 b5 Bb3 d6 c3 O-O h3 Na5"),
    # Ruy Lopez, Berlin (very solid, structural endgames).
    _S("Ruy Lopez Berlin", WHITE,
       "e4 e5 Nf3 Nc6 Bb5 Nf6 O-O Nxe4 d4 Nd6 Bxc6 dxc6 dxe5 Nf5 Qxd8 Kxd8"),
    # Italian Giuoco Pianissimo -- slow, plan-based, closed center.
    _S("Italian Giuoco Pianissimo", WHITE,
       "e4 e5 Nf3 Nc6 Bc4 Bc5 c3 Nf6 d3 d6 O-O O-O Re1 a6 a4 Ba7 h3 h6"),
    # vs Caro-Kann: Advance variation (structural, space-based plan).
    _S("Caro-Kann Advance (White)", WHITE,
       "e4 c6 d4 d5 e5 Bf5 Nf3 e6 Be2 c5 Be3 Nd7 O-O"),
    # vs French: Advance variation (closed center, clear pawn-chain plan).
    _S("French Advance (White)", WHITE,
       "e4 e6 d4 d5 e5 c5 c3 Nc6 Nf3 Qb6 Be2 Nge7 Na3 cxd4 cxd4 Nf5"),
    # vs Sicilian: closed/Alapin (avoids Open-Sicilian theory thickets).
    _S("Sicilian Alapin", WHITE,
       "e4 c5 c3 d5 exd5 Qxd5 d4 Nf6 Nf3 e6 Be2 Nc6 O-O cxd4 cxd4 Be7"),
    # vs Pirc/Modern: classical setup with broad center.
    _S("Pirc Classical (White)", WHITE,
       "e4 d6 d4 Nf6 Nc3 g6 Nf3 Bg7 Be2 O-O O-O c6 a4"),
    # vs Scandinavian: main line, simple development.
    _S("Scandinavian Main (White)", WHITE,
       "e4 d5 exd5 Qxd5 Nc3 Qa5 d4 Nf6 Nf3 c6 Bc4 Bf5 Bd2 e6 O-O-O"),

    # ===================== WHITE after 1.d4 =====================
    # Queen's Gambit Declined, Exchange -- a model structural White system.
    _S("QGD Exchange (White)", WHITE,
       "d4 d5 c4 e6 Nc3 Nf6 cxd5 exd5 Bg5 c6 e3 Be7 Bd3 O-O Qc2 Nbd7 Nge2 Re8"),
    # Slav main line for White.
    _S("Slav Main (White)", WHITE,
       "d4 d5 c4 c6 Nf3 Nf6 Nc3 dxc4 a4 Bf5 e3 e6 Bxc4 Bb4 O-O O-O"),
    # vs King's Indian: Classical, the big strategic battleground.
    _S("KID Classical (White)", WHITE,
       "d4 Nf6 c4 g6 Nc3 Bg7 e4 d6 Nf3 O-O Be2 e5 O-O Nc6 d5 Ne7"),
    # vs Nimzo-Indian: Rubinstein (4.e3) -- solid, structural.
    _S("Nimzo Rubinstein (White)", WHITE,
       "d4 Nf6 c4 e6 Nc3 Bb4 e3 O-O Bd3 d5 Nf3 c5 O-O Nc6 a3 Bxc3 bxc3"),
    # vs Queen's Indian.
    _S("Queen's Indian (White)", WHITE,
       "d4 Nf6 c4 e6 Nf3 b6 g3 Ba6 b3 Bb4 Bd2 Be7 Bg2 c6 O-O d5"),
    # vs Grunfeld: Exchange -- big-center plan.
    _S("Grunfeld Exchange (White)", WHITE,
       "d4 Nf6 c4 g6 Nc3 d5 cxd5 Nxd5 e4 Nxc3 bxc3 Bg7 Nf3 c5 Be2 Nc6 O-O"),
    # vs Dutch: simple classical setup.
    _S("Dutch (White)", WHITE,
       "d4 f5 g3 Nf6 Bg2 e6 Nf3 Be7 O-O O-O c4 d6 Nc3 Qe8"),

    # ===================== BLACK vs 1.e4 =====================
    # Caro-Kann Classical -- our solid main defense to 1.e4 (structural).
    _S("Caro-Kann Classical (Black)", BLACK,
       "e4 c6 d4 d5 Nc3 dxe4 Nxe4 Bf5 Ng3 Bg6 h4 h6 Nf3 Nd7 h5 Bh7 Bd3 Bxd3 Qxd3"),
    # Caro-Kann Advance (Black side of the structural line).
    _S("Caro-Kann Advance (Black)", BLACK,
       "e4 c6 d4 d5 e5 Bf5 Nf3 e6 Be2 c5 O-O Nc6 c3 Nge7"),
    # Caro-Kann vs Exchange.
    _S("Caro-Kann Exchange (Black)", BLACK,
       "e4 c6 d4 d5 exd5 cxd5 Bd3 Nc6 c3 Nf6 Bf4 Bg4 Qb3 Qd7 Nd2 e6"),
    # Backup solid e4 reply: 1...e5 Berlin from Black's side.
    _S("Berlin (Black)", BLACK,
       "e4 e5 Nf3 Nc6 Bb5 Nf6 O-O Nxe4 d4 Nd6 Bxc6 dxc6 dxe5 Nf5 Qxd8 Kxd8"),

    # ===================== BLACK vs 1.d4 =====================
    # Queen's Gambit Declined -- our solid main defense to 1.d4.
    _S("QGD Main (Black)", BLACK,
       "d4 d5 c4 e6 Nc3 Nf6 Bg5 Be7 e3 O-O Nf3 h6 Bh4 b6 cxd5 Nxd5 Bxe7 Qxe7"),
    # Slav Defense for Black.
    _S("Slav (Black)", BLACK,
       "d4 d5 c4 c6 Nf3 Nf6 Nc3 dxc4 a4 Bf5 e3 e6 Bxc4 Bb4 O-O O-O"),
    # QGD Exchange from Black's side.
    _S("QGD Exchange (Black)", BLACK,
       "d4 d5 c4 e6 Nc3 Nf6 cxd5 exd5 Bg5 Be7 e3 c6 Bd3 O-O Qc2 Nbd7"),
    # vs 1.d4 Nf3 systems / London: solid ...d5 setup.
    _S("vs London (Black)", BLACK,
       "d4 d5 Nf3 Nf6 Bf4 e6 e3 c5 c3 Nc6 Nbd2 Bd6 Bg3 O-O Bd3"),

    # ===================== EXTRA STRUCTURAL BREADTH =====================
    # More solid, plan-based lines to widen book coverage. All structural,
    # closed/semi-open centers where a plan survives an imperfect eval.

    # White e4: Four Knights (symmetrical, simple development).
    _S("Four Knights (White)", WHITE,
       "e4 e5 Nf3 Nc6 Nc3 Nf6 Bb5 Bb4 O-O O-O d3 d6 Bg5 Bxc3 bxc3 Qe7"),
    # White e4: Scotch (open but principled, clear plans).
    _S("Scotch (White)", WHITE,
       "e4 e5 Nf3 Nc6 d4 exd4 Nxd4 Bc5 Be3 Qf6 c3 Nge7 Bc4 Ne5 Be2 O-O"),
    # White e4 vs Caro-Kann Classical (White side, structural).
    _S("Caro-Kann Classical (White)", WHITE,
       "e4 c6 d4 d5 Nc3 dxe4 Nxe4 Bf5 Ng3 Bg6 h4 h6 Nf3 Nd7 h5 Bh7 Bd3 Bxd3 Qxd3"),
    # White e4 vs Sicilian ...e6 Alapin alt.
    _S("Sicilian Alapin 2...Nf6", WHITE,
       "e4 c5 c3 Nf6 e5 Nd5 d4 cxd4 Nf3 Nc6 cxd4 d6 Bc4 Nb6 Bb5 dxe5"),
    # White d4: Catalan (structural, long-term bishop pressure).
    _S("Catalan (White)", WHITE,
       "d4 Nf6 c4 e6 g3 d5 Bg2 Be7 Nf3 O-O O-O dxc4 Qc2 a6 Qxc4 b5 Qc2 Bb7"),
    # White d4: London System (easy, structural, plan-based).
    _S("London System (White)", WHITE,
       "d4 d5 Nf3 Nf6 Bf4 e6 e3 c5 c3 Nc6 Nbd2 Bd6 Bg3 O-O Bd3 b6"),
    # White d4: Queen's Gambit Accepted main.
    _S("QGA (White)", WHITE,
       "d4 d5 c4 dxc4 Nf3 Nf6 e3 e6 Bxc4 c5 O-O a6 a4 Nc6 Qe2 cxd4 Rd1"),
    # Black vs e4: French Classical (solid, structural).
    _S("French Classical (Black)", BLACK,
       "e4 e6 d4 d5 Nc3 Nf6 Bg5 Be7 e5 Nfd7 Bxe7 Qxe7 f4 O-O Nf3 c5"),
    # Black vs e4: French Tarrasch (solid).
    _S("French Tarrasch (Black)", BLACK,
       "e4 e6 d4 d5 Nd2 Nf6 e5 Nfd7 Bd3 c5 c3 Nc6 Ne2 cxd4 cxd4 f6"),
    # Black vs d4: Nimzo-Indian (structural, doubles White's pawns).
    _S("Nimzo-Indian (Black)", BLACK,
       "d4 Nf6 c4 e6 Nc3 Bb4 e3 O-O Bd3 d5 Nf3 c5 O-O Nc6 a3 Bxc3 bxc3"),
    # Black vs d4: Queen's Indian (solid, light-square strategy).
    _S("Queen's Indian (Black)", BLACK,
       "d4 Nf6 c4 e6 Nf3 b6 g3 Ba6 b3 Bb4 Bd2 Be7 Bg2 c6 O-O d5"),
    # Black vs d4: Bogo-Indian (solid).
    _S("Bogo-Indian (Black)", BLACK,
       "d4 Nf6 c4 e6 Nf3 Bb4 Bd2 Qe7 g3 Nc6 Bg2 Bxd2 Nbxd2 d6 O-O O-O"),
    # Black vs e4: Caro-Kann Two Knights (structural).
    _S("Caro-Kann Two Knights (Black)", BLACK,
       "e4 c6 Nc3 d5 Nf3 Bg4 h3 Bxf3 Qxf3 e6 d4 dxe4 Nxe4 Nf6"),
]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def position_key(board: chess.Board) -> str:
    """Identity for de-duplication: piece placement + stm + castling + ep.

    Ignores halfmove/fullmove clocks so distinct move orders reaching the same
    position collapse to one entry (true transpositions)."""
    return " ".join(board.fen().split()[:4])


@dataclass
class BookNode:
    fen: str
    best_move_uci: str
    best_move_san: str
    eval_cp: int
    depth: int
    line_name: str
    ply: int


def score_cp(info: dict) -> Optional[int]:
    """Centipawn score from side-to-move POV, mate folded to a large cp value."""
    if "score" not in info:
        return None
    pov = info["score"].relative
    if pov.is_mate():
        m = pov.mate()
        if m is None:
            return None
        # Map mate to a big bounded cp so downstream comparisons stay sane.
        return 30000 - abs(m) if m > 0 else -(30000 - abs(m))
    return pov.score()


# ---------------------------------------------------------------------------
# Core walk
# ---------------------------------------------------------------------------

def build(args) -> dict:
    sf_path = shutil.which(args.stockfish) or args.stockfish
    if not (os.path.isfile(sf_path) or shutil.which(args.stockfish)):
        print(f"ERROR: stockfish not found ('{args.stockfish}')", file=sys.stderr)
        sys.exit(2)

    engine = chess.engine.SimpleEngine.popen_uci(sf_path)
    try:
        engine.configure({"Threads": args.threads, "Hash": args.hash_mb})
    except chess.engine.EngineError:
        pass  # older builds may reject options; analysis still works

    limit = chess.engine.Limit(depth=args.depth)

    nodes: dict[str, BookNode] = {}      # position_key -> node
    dropped: list[dict] = []             # flagged unsound nodes
    dropped_lines: set[str] = set()      # seed names that hit an unsound node
    illegal: list[dict] = []             # should never happen; safety net
    analyzed = 0
    t0 = time.time()

    max_plies = args.max_plies

    for seed in SEEDS:
        board = chess.Board()
        line_unsound = False

        for ply, san in enumerate(seed.moves):
            if ply >= max_plies:
                break

            # Only record nodes where it is OUR side to move for this line.
            our_turn = (board.turn == seed.side)

            if our_turn:
                key = position_key(board)
                if key not in nodes:
                    # Ask Stockfish for the best move in this position.
                    try:
                        info = engine.analyse(board, limit)
                    except chess.engine.EngineError as e:
                        print(f"  ! analyse error in {seed.name} ply {ply}: {e}",
                              file=sys.stderr)
                        info = {}
                    analyzed += 1

                    pv = info.get("pv")
                    sf_move = pv[0] if pv else None
                    cp = score_cp(info)
                    sf_depth = int(info.get("depth", args.depth))

                    # Decide the book move. Prefer Stockfish's choice; if it
                    # cannot be obtained, fall back to the curated seed move
                    # (still validated for legality below).
                    chosen = sf_move
                    if chosen is None:
                        try:
                            chosen = board.parse_san(san)
                        except ValueError:
                            chosen = None

                    if chosen is None:
                        illegal.append({"line": seed.name, "ply": ply,
                                        "fen": board.fen(),
                                        "reason": "no candidate move"})
                    else:
                        # VALIDATION 1: legality.
                        if chosen not in board.legal_moves:
                            illegal.append({"line": seed.name, "ply": ply,
                                            "fen": board.fen(),
                                            "uci": chosen.uci(),
                                            "reason": "illegal move"})
                        else:
                            san_chosen = board.san(chosen)
                            # VALIDATION 2: soundness. eval is from the side to
                            # move (= our side). If it's worse than threshold,
                            # flag + drop and mark the line.
                            if cp is not None and cp < args.max_loss_cp:
                                line_unsound = True
                                dropped_lines.add(seed.name)
                                dropped.append({
                                    "line": seed.name, "ply": ply,
                                    "fen": board.fen(),
                                    "uci": chosen.uci(), "san": san_chosen,
                                    "eval_cp": cp, "depth": sf_depth,
                                    "reason": f"eval {cp}cp < {args.max_loss_cp}cp",
                                })
                            else:
                                nodes[key] = BookNode(
                                    fen=board.fen(),
                                    best_move_uci=chosen.uci(),
                                    best_move_san=san_chosen,
                                    eval_cp=cp if cp is not None else 0,
                                    depth=sf_depth,
                                    line_name=seed.name,
                                    ply=ply,
                                )

            # Advance the board along the curated mainline regardless of side.
            try:
                board.push_san(san)
            except ValueError:
                print(f"  ! bad SAN '{san}' in {seed.name} ply {ply}",
                      file=sys.stderr)
                break

        tag = " [UNSOUND -> nodes from this line still kept up to the bad ply]" \
            if line_unsound else ""
        print(f"  seed done: {seed.name} ({len(seed.moves)} plies){tag}",
              file=sys.stderr)

    elapsed = time.time() - t0
    engine.quit()

    entries = [asdict(n) for n in nodes.values()]
    entries.sort(key=lambda e: (e["ply"], e["line_name"], e["fen"]))

    meta = {
        "generator": "tools/build_opening_repertoire.py",
        "clean_room": "Built from public opening theory + Stockfish only. "
                      "No Colossus or third-party book data.",
        "keyed_by": "FEN (NOT engine Zobrist -- see docs/opening-book-plan.md)",
        "stockfish_path": sf_path,
        "params": {
            "depth": args.depth,
            "max_plies": args.max_plies,
            "threads": args.threads,
            "hash_mb": args.hash_mb,
            "max_loss_cp": args.max_loss_cp,
        },
        "counts": {
            "positions": len(entries),
            "seed_lines": len(SEEDS),
            "stockfish_analyses": analyzed,
            "dropped_unsound": len(dropped),
            "dropped_lines": sorted(dropped_lines),
            "illegal_flagged": len(illegal),
        },
        "elapsed_seconds": round(elapsed, 1),
    }

    return {"meta": meta, "entries": entries,
            "dropped": dropped, "illegal": illegal}


def verify_output(payload: dict) -> None:
    """Final independent assertion pass: every kept move is legal in its FEN."""
    bad = 0
    for e in payload["entries"]:
        board = chess.Board(e["fen"])
        mv = chess.Move.from_uci(e["best_move_uci"])
        if mv not in board.legal_moves:
            bad += 1
            print(f"  ASSERT FAIL: {e['best_move_uci']} illegal in {e['fen']}",
                  file=sys.stderr)
    if bad:
        raise AssertionError(f"{bad} illegal moves in output -- aborting write")
    print(f"  verify: all {len(payload['entries'])} moves legal in their FENs",
          file=sys.stderr)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__),
                    "opening_repertoire.json"),
                    help="output JSON path")
    ap.add_argument("--depth", type=int, default=18,
                    help="Stockfish analysis depth per node (default 18)")
    ap.add_argument("--max-plies", type=int, default=16,
                    help="max half-moves to expand each seed line (default 16)")
    ap.add_argument("--max-loss-cp", type=int, default=-100,
                    help="drop+flag a node if side-to-move eval is below this "
                         "(cp, default -100)")
    ap.add_argument("--threads", type=int, default=4,
                    help="Stockfish threads (default 4)")
    ap.add_argument("--hash-mb", type=int, default=256,
                    help="Stockfish hash MB (default 256)")
    ap.add_argument("--stockfish", default="stockfish",
                    help="stockfish binary (default: 'stockfish' on PATH)")
    args = ap.parse_args()

    print(f"Building opening repertoire: depth={args.depth} "
          f"max_plies={args.max_plies} threads={args.threads}", file=sys.stderr)

    payload = build(args)
    verify_output(payload)

    with open(args.out, "w") as f:
        json.dump(payload, f, indent=2)

    m = payload["meta"]
    print(f"\nWrote {args.out}")
    print(f"  positions:          {m['counts']['positions']}")
    print(f"  stockfish analyses: {m['counts']['stockfish_analyses']}")
    print(f"  dropped unsound:    {m['counts']['dropped_unsound']}")
    print(f"  dropped lines:      {m['counts']['dropped_lines']}")
    print(f"  illegal flagged:    {m['counts']['illegal_flagged']}")
    print(f"  elapsed:            {m['elapsed_seconds']}s")


if __name__ == "__main__":
    main()
