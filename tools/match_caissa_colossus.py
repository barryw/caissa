#!/usr/bin/env python3
"""Play Caissa vs Colossus 4.0 -- both inside (separate) headless VICE x64sc.

Caissa plays WHITE via the persistent bestmove server (tools/vice_caissa.py,
monitor port 6511); Colossus plays BLACK via the screen-scrape driver
(tools/vice_colossus.py, monitor port 6510). A python-chess board is the single
source of truth: each turn we get the side-to-move's move, check legality
(fail-loud), push it, and reconcile against Colossus's on-screen move list.

This is the measurement harness the whole campaign needs: Caissa-vs-Colossus,
headless, so we can score and tune against Colossus (the real bar). It emits a
PGN and per-ply instrumentation (Caissa: score/depth/nodes).

  tools/match_caissa_colossus.py --depth 4 --max-plies 80 --pgn build/game.pgn

Colossus side-switch + non-startpos setup are not automated (same limitation the
old harness had): Caissa is White, game starts from the initial position.
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

import chess  # python-chess
import chess.pgn

sys.path.insert(0, str(Path(__file__).resolve().parent))
from vice_caissa import CaissaServer, DEFAULT_PRG  # noqa: E402
from vice_colossus import (  # noqa: E402
    ViceColossus, ViceColossusError, screen_move_entries, legalize_from_to,
)

REPO = Path(__file__).resolve().parents[1]
DEFAULT_D64 = REPO / "build" / "coloss40_rebuilt.d64"


def reconcile_screen(board: chess.Board, screen: str, plies_done: int,
                     log) -> int:
    """Push every newly-visible ply from Colossus's move list onto the board.

    Drains plies in order from (plies_done+1) up: this absorbs both the echoed
    Caissa (white) move and Colossus's (black) reply. Returns the new ply count.
    Fail-loud on an illegal/unparseable on-screen move.
    """
    entries = dict(screen_move_entries(screen))
    while True:
        move4 = entries.get(plies_done + 1)
        if move4 is None:
            return plies_done
        move = legalize_from_to(board, move4, chess)
        if move is None:
            raise RuntimeError(
                f"Colossus screen move {move4!r} is illegal for {board.fen()}")
        board.push(move)
        plies_done += 1
        log(f"  ply {plies_done:02d}  colossus(black)  {move.uci()}")


def play(args: argparse.Namespace) -> int:
    def log(msg: str) -> None:
        print(msg, flush=True)

    board = chess.Board()
    game = chess.pgn.Game()
    game.headers["Event"] = "Caissa vs Colossus 4.0 (headless VICE)"
    game.headers["White"] = f"Caissa (d{args.depth})"
    game.headers["Black"] = "Colossus 4.0"
    node = game

    caissa = CaissaServer(prg=args.prg, port=args.caissa_port, x64sc=args.x64sc)
    colossus = ViceColossus(d64=args.d64, x64sc=args.x64sc,
                            warp_speed=args.warp_speed,
                            connect_timeout=args.boot_timeout)
    plies = 0
    t0 = time.monotonic()
    try:
        log("[boot] launching Caissa server ...")
        caissa.launch(boot_log=REPO / "build" / "vice_caissa_boot.log")
        caissa.wait_ready(timeout=args.boot_timeout)
        log(f"[boot] Caissa ready ({time.monotonic() - t0:.0f}s)")

        log("[boot] launching Colossus ...")
        colossus.launch(boot_log=REPO / "build" / "vice_colossus_boot.log")
        colossus.wait_for_boot(args.boot_timeout, args.poll)
        colossus.disable_prediction()
        colossus.set_warp()
        log(f"[boot] Colossus board ready ({time.monotonic() - t0:.0f}s)")

        screen = colossus.read_screen()
        while plies < args.max_plies and not board.is_game_over(claim_draw=True):
            plies = reconcile_screen(board, screen, plies, log)
            if board.is_game_over(claim_draw=True) or plies >= args.max_plies:
                break

            if board.turn == chess.WHITE:
                # Caissa's move.
                fen = board.fen()
                res = caissa.bestmove(fen, args.depth, timeout=args.caissa_timeout)
                move = chess.Move.from_uci(res["uci"])
                if move not in board.legal_moves:
                    raise RuntimeError(
                        f"Caissa returned illegal move {res['uci']} for {fen}")
                board.push(move)
                plies += 1
                node = node.add_variation(move)
                node.comment = (f"d{res['depth']} score {res['score']} "
                                f"nodes {res['nodes']}")
                log(f"  ply {plies:02d}  caissa(white)    {move.uci()}  "
                    f"score {res['score']} nodes {res['nodes']}")

                # Hand the move to Colossus; wait for it to echo, then reply.
                white_ply = plies
                with colossus.heartbeat(args.heartbeat):
                    for attempt in range(args.move_attempts):
                        colossus.inject_move(move.uci())
                        try:
                            colossus.wait_for_ply(white_ply, args.input_timeout,
                                                  poll_seconds=args.poll)
                            break
                        except ViceColossusError:
                            colossus.set_warp()
                    else:
                        raise RuntimeError(
                            f"Colossus never acked Caissa ply {white_ply}")
                screen = colossus.read_screen()
            else:
                # Wait for Colossus to produce its reply ply.
                log(f"[wait] Colossus thinking (ply {plies + 1:02d}) ...")
                screen = colossus.wait_for_ply(plies + 1, args.colossus_timeout,
                                               poll_seconds=args.poll)

        # Record the PGN result.
        board_result = board.result(claim_draw=True)
        game.headers["Result"] = board_result
        log(f"\n[done] {plies} plies, result {board_result} "
            f"({time.monotonic() - t0:.0f}s)")
        log(f"[done] reason: {game_over_reason(board)}")

        if args.pgn:
            Path(args.pgn).parent.mkdir(parents=True, exist_ok=True)
            with open(args.pgn, "w") as fh:
                print(game, file=fh)
            log(f"[pgn]  wrote {args.pgn}")
        else:
            log("\n" + str(game))
        return 0
    finally:
        caissa.close()
        colossus.kill()


def game_over_reason(board: chess.Board) -> str:
    if board.is_checkmate():
        return "checkmate"
    if board.is_stalemate():
        return "stalemate"
    if board.is_insufficient_material():
        return "insufficient material"
    if board.is_seventyfive_moves() or board.can_claim_fifty_moves():
        return "fifty-move rule"
    if board.is_fivefold_repetition() or board.can_claim_threefold_repetition():
        return "repetition"
    return "max plies / unfinished"


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--depth", type=int, default=4, help="Caissa search depth")
    p.add_argument("--max-plies", type=int, default=80)
    p.add_argument("--pgn", type=Path, default=REPO / "build" / "caissa_vs_colossus.pgn")
    p.add_argument("--prg", type=Path, default=DEFAULT_PRG)
    p.add_argument("--d64", type=Path, default=DEFAULT_D64)
    p.add_argument("--x64sc", default=str(Path.home() / "Git" / "vice-macos" / "vice" / "src" / "x64sc"))
    p.add_argument("--caissa-port", type=int, default=6511)
    p.add_argument("--warp-speed", type=int, default=10000)
    p.add_argument("--boot-timeout", type=float, default=240.0)
    p.add_argument("--caissa-timeout", type=float, default=180.0)
    p.add_argument("--colossus-timeout", type=float, default=600.0,
                   help="max wall time to wait for one Colossus reply")
    p.add_argument("--input-timeout", type=float, default=120.0,
                   help="max wait for Colossus to echo an injected move")
    p.add_argument("--move-attempts", type=int, default=3)
    p.add_argument("--heartbeat", type=float, default=20.0)
    p.add_argument("--poll", type=float, default=2.0)
    args = p.parse_args(argv)
    return play(args)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
