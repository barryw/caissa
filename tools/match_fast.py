#!/usr/bin/env python3
"""Caissa (caissa_cli) vs Colossus 4.0 (fastcolossus) -- a full game in SECONDS.

Both engines run on the fast functional 6502 core, so there is no realtime-VICE
bottleneck:
  * Caissa  = White, via tools/llvmmos_bench/caissa_cli (bestmove FEN DEPTH).
  * Colossus = Black, via tools/fastcolossus/fastcolossus in `server` mode -- a
    persistent process holding live Colossus board state; we feed White's move
    into its KERNAL keyboard buffer, run cycles, and scrape its reply off the
    board screen ($0400). The scrape/inject logic is reused verbatim from
    vice_colossus.py (the proven VICE recipe).

python-chess is the source of truth for legality + result. Usage:
    tools/match_fast.py [--depth 4] [--max-plies 200] [--pgn build/fast_game.pgn]
    tools/match_fast.py --selftest        # 1.e4 -> expect Colossus e7e5
"""
from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path

import chess
import chess.pgn

# Reuse the proven Colossus screen scrape + move parsing.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from vice_colossus import (  # noqa: E402
    decode_screen_bytes,
    screen_move_entries,
    legalize_from_to,
)

import re

REPO = Path(__file__).resolve().parents[1]
CAISSA_CLI = REPO / "tools" / "llvmmos_bench" / "caissa_cli"
FASTCOLOSSUS = REPO / "tools" / "fastcolossus" / "fastcolossus"


def colossus_stats(screen: str) -> dict:
    """Scrape Colossus's on-screen thinking stats for the last move."""
    out: dict[str, int] = {}
    m = re.search(r"Lookahead=\s*(\d+)", screen)
    if m:
        out["lookahead"] = int(m.group(1))
    m = re.search(r"Positions=\s*(\d+)", screen)
    if m:
        out["positions"] = int(m.group(1))
    m = re.search(r"Score:\s*Mtrl\s*(-?\d+)\s*Psnl\s*(-?\d+)", screen)
    if m:
        out["mtrl"] = int(m.group(1))
        out["psnl"] = int(m.group(2))
    return out

# One run-chunk of cycles between screen polls (~0.1s of wall time on the fast
# core) and the per-move cycle budget before we give up waiting for a reply.
CHUNK_CYCLES = 2_000_000
MOVE_BUDGET_CYCLES = 120_000_000


class FastColossus:
    """Persistent Colossus on the fast core, talking the server line protocol."""

    def __init__(self) -> None:
        self.proc = subprocess.Popen(
            [str(FASTCOLOSSUS), "server"],
            cwd=str(REPO),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
        )
        self._expect("READY")

    def _send(self, line: str) -> None:
        assert self.proc.stdin is not None
        self.proc.stdin.write(line + "\n")
        self.proc.stdin.flush()

    def _readline(self) -> str:
        assert self.proc.stdout is not None
        out = self.proc.stdout.readline()
        if not out:
            raise RuntimeError("fastcolossus server closed unexpectedly")
        return out.rstrip("\n")

    def _expect(self, tok: str) -> None:
        line = self._readline()
        if not line.startswith(tok):
            raise RuntimeError(f"expected {tok!r} from server, got {line!r}")

    def poke(self, addr: int, values: list[int]) -> None:
        self._send(f"P {addr:04x} " + " ".join(f"{v:02x}" for v in values))
        self._expect("OK")

    def disable_prediction(self) -> None:
        """$B49B=0 stops Colossus pondering the opponent reply (avoids desync)."""
        self.poke(0xB49B, [0x00])

    def enqueue_keys(self, raw_bytes: list[int]) -> None:
        self._send("K " + " ".join(f"{b:02x}" for b in raw_bytes))
        self._expect("OK")

    def run(self, cycles: int) -> None:
        self._send(f"R {cycles}")
        self._expect("OK")

    def mem(self, addr: int, length: int) -> list[int]:
        self._send(f"M {addr:04x} {length:x}")
        line = self._readline()
        toks = line.split()
        if not toks or toks[0] != "M":
            raise RuntimeError(f"bad M reply: {line!r}")
        return [int(t, 16) for t in toks[1:]]

    def read_screen(self) -> str:
        return decode_screen_bytes(self.mem(0x0400, 1000))

    def inject_move(self, uci: str) -> None:
        """Feed a move as <rank><FILE>RET per square, poking all 6 bytes into the
        KERNAL buffer at once with $C6=6 -- the proven vice_colossus recipe. (The
        one-key-at-a-time drain path registers move 1 but is silently dropped from
        move 2 on, so the move list freezes; poking the full buffer fixes it.)"""
        m = uci.strip().lower()
        f1, r1, f2, r2 = m[0], m[1], m[2], m[3]
        seq = [ord(r1), ord(f1.upper()), 0x0D, ord(r2), ord(f2.upper()), 0x0D]
        self.poke(0x0277, seq)
        self.poke(0x00C6, [len(seq)])

    def wait_for_ply(self, target_ply: int, budget_cycles: int = MOVE_BUDGET_CYCLES) -> str:
        """Run in chunks until the move list shows `target_ply` (1-based)."""
        spent = 0
        last = ""
        while spent < budget_cycles:
            self.run(CHUNK_CYCLES)
            spent += CHUNK_CYCLES
            last = self.read_screen()
            if target_ply in [ply for ply, _ in screen_move_entries(last)]:
                return last
        raise RuntimeError(
            f"Colossus did not produce ply {target_ply} within "
            f"{budget_cycles} cycles\n{last}"
        )

    def plies(self, screen: str) -> set[int]:
        return {ply for ply, _ in screen_move_entries(screen)}

    def submit_move(self, white_uci: str, white_ply: int, black_ply: int,
                    budget_cycles: int = MOVE_BUDGET_CYCLES) -> str:
        """Feed White's move, then return the screen once Colossus has replied.

        Once Colossus deepens (Lookahead>=3) it PONDERS after its move: its
        interrupt-poll drains the keyboard buffer and discards a coordinate
        keystroke, so a single inject is silently lost. We therefore RE-INJECT
        whenever the buffer has drained and White's move has not yet echoed on
        the move list; once it echoes we clear any leftover keys (so they cannot
        be misread as the next move) and just wait for Black's reply.
        """
        spent = 0
        # Phase A: get White's move accepted (survive ponder key-eating).
        while True:
            screen = self.read_screen()
            if white_ply in self.plies(screen):
                break
            if self.mem(0x00C6, 1)[0] == 0:          # buffer drained -> (re)inject
                self.inject_move(white_uci)
            self.run(CHUNK_CYCLES)
            spent += CHUNK_CYCLES
            if spent >= budget_cycles:
                raise RuntimeError(f"Colossus never accepted White {white_uci} "
                                   f"(ply {white_ply})\n{screen}")
        self.poke(0x00C6, [0])                        # discard any leftover keys
        # Phase B: wait for Colossus's reply.
        while True:
            screen = self.read_screen()
            if black_ply in self.plies(screen):
                return screen
            self.run(CHUNK_CYCLES)
            spent += CHUNK_CYCLES
            if spent >= budget_cycles:
                raise RuntimeError(f"Colossus did not reply to ply {black_ply} "
                                   f"within budget\n{screen}")

    def close(self) -> None:
        try:
            self._send("Q")
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()


def caissa_bestmove(fen: str, depth: int) -> tuple[str, dict]:
    out = subprocess.run(
        [str(CAISSA_CLI), "bestmove", fen, str(depth)],
        capture_output=True, text=True, timeout=300,
    ).stdout.strip()
    # "bestmove d2d4 score 0 depth 4 nodes 0"
    toks = out.split()
    info = {}
    mv = toks[1] if len(toks) > 1 and toks[0] == "bestmove" else None
    for k in ("score", "depth", "nodes", "qnodes", "tt_hits"):
        if k in toks:
            info[k] = toks[toks.index(k) + 1]
    if not mv:
        raise RuntimeError(f"caissa_cli gave no move: {out!r}")
    return mv, info


def selftest() -> int:
    col = FastColossus()
    try:
        col.inject_move("e2e4")
        screen = col.wait_for_ply(2)
        entries = dict(screen_move_entries(screen))
        reply = entries.get(2)
        print(f"1.e4 -> Colossus reply (ply 2) = {reply}")
        print(screen)
        ok = reply == "e7e5"
        print("SELFTEST", "PASS" if ok else f"FAIL (got {reply}, want e7e5)")
        return 0 if ok else 1
    finally:
        col.close()


# Diverse White openings so the deterministic engines don't replay one game.
OPENINGS = [
    ["e2e4"], ["d2d4"], ["c2c4"], ["g1f3"], ["g2g3"], ["b2b3"], ["f2f4"],
    ["b1c3"], ["e2e4", "g1f3"], ["d2d4", "c2c4"], ["c2c4", "b1c3"],
    ["e2e3"], ["d2d3"], ["b1a3"], ["g1h3"], ["a2a3"],
]


def play(depth: int, max_plies: int, opening: list[str], game_id: int,
         rows: list[dict], pgn_path: Path | None = None, quiet: bool = False) -> dict:
    """Play one game. Appends per-move telemetry rows. Returns a result dict."""
    board = chess.Board()
    game = chess.pgn.Game()
    game.headers["White"] = "Caissa"
    game.headers["Black"] = "Colossus 4.0"
    game.headers["Event"] = f"fast-core match g{game_id}"
    game.headers["Opening"] = " ".join(opening)
    node = game
    col = FastColossus()
    col.disable_prediction()
    t0 = time.monotonic()
    ADJ_CP, ADJ_STREAK = 800, 6      # |eval|>=8 pawns for 6 Caissa moves -> decided
    adj_streak, adj_sign = 0, 0
    adjudicated = None
    try:
        last_white_uci = None
        while not board.is_game_over(claim_draw=True) and board.ply() < max_plies:
            ply = board.ply()           # 0-based count of moves already made
            fen_before = board.fen()
            if board.turn == chess.WHITE:
                book = ply // 2 < len(opening)   # still within the forced opening
                t = time.monotonic()
                if book:
                    mv, info = opening[ply // 2], {}
                else:
                    mv, info = caissa_bestmove(fen_before, depth)
                wall_ms = int((time.monotonic() - t) * 1000)
                move = chess.Move.from_uci(mv)
                if move not in board.legal_moves:
                    if book:                     # book move illegal here -> let engine pick
                        mv, info = caissa_bestmove(fen_before, depth)
                        move = chess.Move.from_uci(mv)
                        book = False
                    if move not in board.legal_moves:
                        print(f"!! Caissa illegal {mv} at\n{fen_before}")
                        return {"result": "*", "error": "caissa-illegal"}
                san = board.san(move)
                num = board.fullmove_number
                board.push(move)
                node = node.add_variation(move)
                node.comment = (f"book" if book else
                                f"{info.get('score','?')}cp n{info.get('nodes','?')}")
                last_white_uci = mv
                rows.append(dict(
                    game=game_id, ply=ply + 1, fullmove=num, side="W",
                    source="book" if book else "caissa", move=mv, san=san,
                    score=("" if book else info.get("score", "")),
                    nodes=info.get("nodes", ""), qnodes=info.get("qnodes", ""),
                    tt_hits=info.get("tt_hits", ""),
                    lookahead="", positions="", mtrl="", psnl="",
                    wall_ms=wall_ms, fen=fen_before))
                if not quiet:
                    tag = "book" if book else f"{info.get('score','?'):>5}cp n{info.get('nodes','?')}"
                    print(f"  g{game_id} {num:3}. {san:7} (Caissa {tag})")
                # Eval adjudication: end clearly-decided games before the slow
                # endgame grind (Colossus deepens -> minutes/move).
                if not book and info.get("score", "") != "":
                    sc = int(info["score"])             # White-POV cp
                    sign = 1 if sc >= ADJ_CP else -1 if sc <= -ADJ_CP else 0
                    if sign and sign == adj_sign:
                        adj_streak += 1
                    else:
                        adj_streak, adj_sign = (1 if sign else 0), sign
                    if adj_streak >= ADJ_STREAK:
                        adjudicated = "1-0" if adj_sign > 0 else "0-1"
                        break
            else:
                white_ply = board.ply()
                black_ply = white_ply + 1
                t = time.monotonic()
                screen = col.submit_move(last_white_uci, white_ply, black_ply)
                wall_ms = int((time.monotonic() - t) * 1000)
                raw = dict(screen_move_entries(screen)).get(black_ply)
                if not raw:
                    print(f"!! no Colossus reply ply {black_ply}\n{screen}")
                    return {"result": "*", "error": "no-colossus-reply"}
                move = legalize_from_to(board, raw, chess)
                if move is None:
                    print(f"!! Colossus {raw} illegal at\n{fen_before}")
                    return {"result": "*", "error": "colossus-illegal"}
                cs = colossus_stats(screen)
                san = board.san(move)
                board.push(move)
                node = node.add_variation(move)
                rows.append(dict(
                    game=game_id, ply=black_ply, fullmove=board.fullmove_number - 1,
                    side="B", source="colossus", move=move.uci(), san=san,
                    score="", nodes="", qnodes="", tt_hits="",
                    lookahead=cs.get("lookahead", ""), positions=cs.get("positions", ""),
                    mtrl=cs.get("mtrl", ""), psnl=cs.get("psnl", ""),
                    wall_ms=wall_ms, fen=fen_before))
                if not quiet:
                    print(f"  g{game_id}      ...{san:7} (Colossus {raw} "
                          f"L{cs.get('lookahead','?')} P{cs.get('positions','?')})")
        outcome = board.outcome(claim_draw=True)
        if adjudicated and not outcome:
            result = adjudicated
            term_name = "ADJUDICATED"
        else:
            result = board.result(claim_draw=True)
            term_name = outcome.termination.name if outcome else "MAXPLIES"
        game.headers["Result"] = result
        game.headers["Termination"] = term_name
        secs = time.monotonic() - t0
        if pgn_path:
            pgn_path.parent.mkdir(parents=True, exist_ok=True)
            with open(pgn_path, "a") as f:
                f.write(str(game) + "\n\n")
        return {"result": result, "plies": board.ply(), "secs": secs,
                "opening": " ".join(opening), "termination": outcome,
                "term_name": term_name}
    finally:
        col.close()


CSV_COLS = ["game", "ply", "fullmove", "side", "source", "move", "san", "score",
            "nodes", "qnodes", "tt_hits", "lookahead", "positions", "mtrl",
            "psnl", "wall_ms", "fen"]


def analyze(rows: list[dict], results: list[dict]) -> None:
    """Print where Caissa is bottlenecking -- results, eval swings, search load."""
    print("\n" + "=" * 70)
    print("BATCH ANALYSIS")
    print("=" * 70)

    # --- results (from Caissa = White's POV) ---
    wld = {"win": 0, "loss": 0, "draw": 0, "other": 0}
    for r in results:
        res = r.get("result", "*")
        wld["win" if res == "1-0" else "loss" if res == "0-1"
            else "draw" if res == "1/2-1/2" else "other"] += 1
    n = len(results)
    print(f"\nGames: {n}   Caissa W/L/D = {wld['win']}/{wld['loss']}/{wld['draw']}"
          f"   (unfinished/error: {wld['other']})")
    for r in results:
        why = r.get("term_name", "ERR")
        print(f"  g{r.get('game','?'):<3} {r.get('result','*'):7} {r.get('plies','?'):>3}p "
              f"{r.get('secs',0):5.0f}s  [{r.get('opening','')}]  {why}"
              + (f"  ERR={r['error']}" if r.get("error") else ""))

    caissa = [x for x in rows if x["side"] == "W" and x["source"] == "caissa"
              and x["score"] != ""]
    if not caissa:
        print("\n(no Caissa engine moves with eval -- nothing to analyze)")
        return

    # --- Caissa eval trajectory: biggest single-move drops = blind spots ---
    by_game: dict[int, list[dict]] = {}
    for x in caissa:
        by_game.setdefault(x["game"], []).append(x)
    swings = []
    for g, mv in by_game.items():
        mv.sort(key=lambda z: int(z["ply"]))   # ply may be a CSV string
        for a, b in zip(mv, mv[1:]):
            drop = int(a["score"]) - int(b["score"])   # eval fell on Caissa's turn
            swings.append((drop, g, b["fullmove"], b["san"], int(a["score"]),
                           int(b["score"]), a["fen"]))
    swings.sort(reverse=True)
    print("\nLargest Caissa eval drops (candidate eval blind spots / blunders):")
    print("  drop  game  move          before -> after   position (FEN before the drop)")
    for drop, g, fm, san, bef, aft, fen in swings[:12]:
        if drop <= 0:
            break
        print(f"  {drop:5}   g{g:<3} {fm:>3}.{san:6} {bef:>6} -> {aft:<6}   {fen}")

    # --- search load: where node/qnode counts explode (tactical density) ---
    def col_ints(key):
        return [(int(x[key]), x) for x in caissa if x.get(key) not in ("", None)]
    nodes = col_ints("nodes"); qn = col_ints("qnodes"); tt = col_ints("tt_hits")
    if nodes:
        avg_n = sum(v for v, _ in nodes) / len(nodes)
        avg_q = sum(v for v, _ in qn) / len(qn) if qn else 0
        avg_tt = sum(v for v, _ in tt) / len(tt) if tt else 0
        qshare = avg_q / (avg_n + avg_q) * 100 if (avg_n + avg_q) else 0
        print(f"\nSearch load over {len(nodes)} Caissa moves (depth-fixed):")
        print(f"  avg nodes={avg_n:,.0f}  avg qnodes={avg_q:,.0f}  "
              f"qsearch share={qshare:.0f}%  avg tt_hits={avg_tt:,.0f}")
        qn.sort(reverse=True)
        print("  heaviest quiescence positions (tactical hotspots):")
        for v, x in qn[:5]:
            print(f"    qnodes={v:>7,} nodes={x['nodes']:>6} score={x['score']:>5}cp "
                  f"g{x['game']} {x['fullmove']}.{x['san']}  {x['fen']}")
    # final material-eval gap if Caissa swept: opponent too weak to tune against
    if wld["win"] == n and n:
        print("\n** Caissa swept the batch at this Colossus level. To get a tuning")
        print("   signal, raise Colossus's level (deeper Lookahead) -- otherwise the")
        print("   eval drops above are the only weakness data available. **")


def batch(depth: int, games: int, max_plies: int, csv_path: Path,
          pgn_path: Path, quiet: bool) -> int:
    import csv
    rows: list[dict] = []
    results: list[dict] = []
    pgn_path.parent.mkdir(parents=True, exist_ok=True)
    pgn_path.write_text("")            # truncate; play() appends
    openings = (OPENINGS * ((games // len(OPENINGS)) + 1))[:games]
    for i, opening in enumerate(openings):
        print(f"\n--- game {i} / opening {' '.join(opening)} ---")
        res = play(depth, max_plies, opening, i, rows, pgn_path, quiet)
        res["game"] = i
        results.append(res)
        print(f"  -> {res.get('result','*')} ({res.get('plies','?')} plies, "
              f"{res.get('secs',0):.0f}s)")
        # checkpoint the CSV after every game so a long batch is never lost
        with open(csv_path, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=CSV_COLS)
            w.writeheader()
            w.writerows(rows)
    print(f"\nCSV  -> {csv_path}  ({len(rows)} move rows)")
    print(f"PGN  -> {pgn_path}")
    analyze(rows, results)
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--depth", type=int, default=4)
    ap.add_argument("--games", type=int, default=1)
    ap.add_argument("--max-plies", type=int, default=160)
    ap.add_argument("--csv", type=Path, default=REPO / "build" / "match_telemetry.csv")
    ap.add_argument("--pgn", type=Path, default=REPO / "build" / "match_games.pgn")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--analyze", type=Path, help="re-run analysis on an existing telemetry CSV")
    args = ap.parse_args(argv)
    if args.selftest:
        return selftest()
    if args.analyze:
        import csv
        with open(args.analyze) as f:
            rows = list(csv.DictReader(f))
        analyze(rows, [])
        return 0
    return batch(args.depth, args.games, args.max_plies, args.csv, args.pgn, args.quiet)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
