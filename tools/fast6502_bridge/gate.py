#!/usr/bin/env python3
"""Correctness gate: drive BOTH the .NET sim6502 bridge and the fast6502
bridge over a corpus of positions and assert bit-for-bit identical replies for
bestmove (timeoutCycles=0, so cycle differences are irrelevant -> moves MUST
match), eval (lazy=0 and lazy=1), and zobrist.

Usage:
    python3 tools/fast6502_bridge/gate.py [--positions N] [--difficulty hard]
                                          [--speed] [--speed-positions N]

The gate spawns each bridge as a persistent subprocess and speaks the same
JSON-lines protocol the engine's Python runner uses, so it is a true drop-in
comparison.  Any move/eval/zobrist mismatch is a FAIL and is printed in full.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tools"))

from run_stockfish_strength import fen_to_c64, DIFFICULTY  # noqa: E402

PRG = REPO / "build" / "engine_harness.prg"
SYM = REPO / "build" / "engine_harness.sym"
FAST = REPO / "tools" / "fast6502_bridge" / "fast6502_bridge"
CSHARP_DLL = (
    REPO / "tools" / "Sim6502HeadlessBridge" / "bin" / "Release" / "net10.0"
    / "Sim6502HeadlessBridge.dll"
)


class Bridge:
    def __init__(self, cmd: list[str], label: str):
        self.label = label
        self.proc = subprocess.Popen(
            cmd, cwd=str(REPO), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, bufsize=1,
        )
        ready = json.loads(self.proc.stdout.readline())
        assert ready.get("ready"), f"{label} not ready: {ready}"
        self.emulator = ready.get("emulator")

    def send(self, req: dict) -> dict:
        self.proc.stdin.write(json.dumps(req, separators=(",", ":")) + "\n")
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        if line == "":
            err = self.proc.stderr.read()
            raise RuntimeError(f"{self.label} died: {err}")
        return json.loads(line)

    def close(self):
        try:
            self.proc.stdin.write('{"id":0,"command":"quit"}\n')
            self.proc.stdin.flush()
            self.proc.wait(timeout=3)
        except Exception:
            self.proc.kill()


def position_to_fields(fen: str) -> dict:
    c = fen_to_c64(fen)
    return {
        "board88": list(c.board88),
        "currentplayer": int(c.currentplayer),
        "whitekingsq": int(c.whitekingsq),
        "blackkingsq": int(c.blackkingsq),
        "castlerights": int(c.castlerights),
        "enpassantsq": int(c.enpassantsq),
        "halfmoveClock": int(c.halfmove_clock),
        "fullmoveNumber": int(c.fullmove_number),
    }


def load_fens(n: int) -> list[tuple[str, str]]:
    """Return up to n (name, fen) pairs from the corpus, padded from the texel
    dataset so we always have >=50 distinct, legal positions."""
    fens: list[tuple[str, str]] = []
    seen: set[str] = set()
    corpus = json.loads((REPO / "tools" / "stockfish_strength_corpus.json").read_text())
    for p in corpus["positions"]:
        if p["fen"] not in seen:
            fens.append((p["name"], p["fen"]))
            seen.add(p["fen"])
    texel = REPO / "build" / "texel_big.tsv"
    if texel.exists():
        with texel.open() as f:
            for i, line in enumerate(f):
                if len(fens) >= n:
                    break
                fen = line.split("\t", 1)[0].strip()
                if not fen or fen in seen:
                    continue
                # texel rows are positions with side-to-move; usable as-is.
                fens.append((f"texel{i}", fen))
                seen.add(fen)
    return fens[:n]


def gate(positions: int, difficulty: str) -> int:
    fens = load_fens(positions)
    print(f"Loaded {len(fens)} positions (difficulty={difficulty})")

    fast = Bridge([str(FAST), "--program", str(PRG), "--symbols", str(SYM)], "fast6502")
    sim = Bridge(
        ["dotnet", str(CSHARP_DLL), "--program", str(PRG), "--symbols", str(SYM)],
        "sim6502",
    )
    print(f"fast emulator={fast.emulator!r}  ref emulator={sim.emulator!r}")

    bm_ok = bm_fail = 0
    ev_ok = ev_fail = 0
    zb_ok = zb_fail = 0
    failures: list[str] = []

    try:
        for idx, (name, fen) in enumerate(fens, 1):
            fields = position_to_fields(fen)

            # ---- bestmove (no timeout) ----
            req = {"id": idx, "command": "bestmove", "difficulty": DIFFICULTY[difficulty],
                   "timeoutCycles": 0, **fields}
            rf = fast.send(req)
            rs = sim.send(req)
            if (rf["bestMoveFrom"], rf["bestMoveTo"]) == (rs["bestMoveFrom"], rs["bestMoveTo"]):
                bm_ok += 1
            else:
                bm_fail += 1
                failures.append(
                    f"BESTMOVE MISMATCH [{name}] {fen}\n"
                    f"  fast: from={rf['bestMoveFrom']} to={rf['bestMoveTo']} "
                    f"cycles={rf['cycles']} ok={rf['ok']}\n"
                    f"  sim : from={rs['bestMoveFrom']} to={rs['bestMoveTo']} "
                    f"cycles={rs['cycles']} ok={rs['ok']}"
                )

            # ---- zobrist ----
            zreq = {"id": idx, "command": "zobrist", "difficulty": 0,
                    "timeoutCycles": 0, **fields}
            zf = fast.send(zreq)
            zs = sim.send(zreq)
            if zf["key"] == zs["key"]:
                zb_ok += 1
            else:
                zb_fail += 1
                failures.append(f"ZOBRIST MISMATCH [{name}] fast={zf['key']} sim={zs['key']} :: {fen}")

            # ---- eval lazy=0 and lazy=1 ----
            for lazy in (0, 1):
                ereq = {"id": idx, "command": "eval", "lazy": lazy, "difficulty": 0,
                        "timeoutCycles": 0, **fields}
                ef = fast.send(ereq)
                es = sim.send(ereq)
                if ef["eval"] == es["eval"]:
                    ev_ok += 1
                else:
                    ev_fail += 1
                    failures.append(
                        f"EVAL MISMATCH [{name}] lazy={lazy} fast={ef['eval']} sim={es['eval']} :: {fen}"
                    )

            if idx % 10 == 0:
                print(f"  ... {idx}/{len(fens)} done")
    finally:
        fast.close()
        sim.close()

    print()
    print("=" * 60)
    print(f"bestmove : {bm_ok}/{bm_ok + bm_fail} identical")
    print(f"zobrist  : {zb_ok}/{zb_ok + zb_fail} identical")
    print(f"eval     : {ev_ok}/{ev_ok + ev_fail} identical (lazy 0+1)")
    print("=" * 60)
    if failures:
        print("\nFAILURES:")
        for fl in failures[:40]:
            print(fl)
        return 1
    print("\nGATE PASS: all positions identical for bestmove + eval + zobrist.")
    return 0


def speed(positions: int, difficulty: str) -> None:
    fens = load_fens(positions)
    fields_list = [position_to_fields(fen) for _, fen in fens]
    print(f"\nSpeed test: {len(fens)} positions @ difficulty={difficulty}, timeoutCycles=0")

    def run(bridge: Bridge) -> float:
        t0 = time.perf_counter()
        for idx, fields in enumerate(fields_list, 1):
            bridge.send({"id": idx, "command": "bestmove",
                         "difficulty": DIFFICULTY[difficulty], "timeoutCycles": 0, **fields})
        return time.perf_counter() - t0

    fast = Bridge([str(FAST), "--program", str(PRG), "--symbols", str(SYM)], "fast6502")
    tf = run(fast)
    fast.close()

    sim = Bridge(["dotnet", str(CSHARP_DLL), "--program", str(PRG), "--symbols", str(SYM)], "sim6502")
    ts = run(sim)
    sim.close()

    print(f"  fast6502 : {tf:8.3f}s  ({tf / len(fens) * 1000:.1f} ms/pos)")
    print(f"  sim6502  : {ts:8.3f}s  ({ts / len(fens) * 1000:.1f} ms/pos)")
    print(f"  SPEEDUP  : {ts / tf:.2f}x")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--positions", type=int, default=60)
    ap.add_argument("--difficulty", choices=sorted(DIFFICULTY), default="hard")
    ap.add_argument("--speed", action="store_true", help="also measure speedup")
    ap.add_argument("--speed-positions", type=int, default=20)
    ap.add_argument("--speed-difficulty", default=None)
    args = ap.parse_args()

    rc = gate(args.positions, args.difficulty)
    if args.speed:
        speed(args.speed_positions, args.speed_difficulty or args.difficulty)
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
