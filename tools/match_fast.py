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

REPO = Path(__file__).resolve().parents[1]
CAISSA_CLI = REPO / "tools" / "llvmmos_bench" / "caissa_cli"
FASTCOLOSSUS = REPO / "tools" / "fastcolossus" / "fastcolossus"

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
    for k in ("score", "depth", "nodes"):
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


def play(depth: int, max_plies: int, pgn_path: Path | None) -> int:
    board = chess.Board()
    game = chess.pgn.Game()
    game.headers["White"] = "Caissa"
    game.headers["Black"] = "Colossus 4.0"
    game.headers["Event"] = "fast-core match"
    node = game
    col = FastColossus()
    col.disable_prediction()
    t0 = time.monotonic()
    try:
        last_white_uci = None
        while not board.is_game_over(claim_draw=True) and board.ply() < max_plies:
            if board.turn == chess.WHITE:
                mv, info = caissa_bestmove(board.fen(), depth)
                move = chess.Move.from_uci(mv)
                if move not in board.legal_moves:
                    print(f"!! Caissa illegal move {mv} at\n{board.fen()}")
                    return 2
                san = board.san(move)
                num = board.fullmove_number
                board.push(move)
                node = node.add_variation(move)
                node.comment = f"d{info.get('depth','?')} n{info.get('nodes','?')}"
                last_white_uci = mv
                print(f"{num:3}. {san:7} (Caissa  d{info.get('depth','?')} "
                      f"n{info.get('nodes','?')})")
            else:
                white_ply = board.ply()         # White's move already pushed
                black_ply = white_ply + 1
                screen = col.submit_move(last_white_uci, white_ply, black_ply)
                raw = dict(screen_move_entries(screen)).get(black_ply)
                if not raw:
                    print(f"!! no Colossus reply for ply {black_ply}\n{screen}")
                    return 2
                move = legalize_from_to(board, raw, chess)
                if move is None:
                    print(f"!! Colossus move {raw} illegal at\n{board.fen()}\n{screen}")
                    return 2
                san = board.san(move)
                board.push(move)
                node = node.add_variation(move)
                print(f"     ...{san:7} (Colossus {raw})")
        result = board.result(claim_draw=True)
        game.headers["Result"] = result
        secs = time.monotonic() - t0
        print(f"\nResult: {result}  ({board.ply()} plies, {secs:.1f}s)")
        print(game.mainline_moves())
        if pgn_path:
            pgn_path.parent.mkdir(parents=True, exist_ok=True)
            pgn_path.write_text(str(game) + "\n")
            print(f"PGN -> {pgn_path}")
        return 0
    finally:
        col.close()


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--depth", type=int, default=4)
    ap.add_argument("--max-plies", type=int, default=200)
    ap.add_argument("--pgn", type=Path, default=REPO / "build" / "fast_game.pgn")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv)
    if args.selftest:
        return selftest()
    return play(args.depth, args.max_plies, args.pgn)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
