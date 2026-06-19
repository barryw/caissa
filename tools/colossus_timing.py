#!/usr/bin/env python3
"""Measure Colossus 4.0's cyc/move (search cost) + Lookahead + Positions per reply,
on the cycle-exact fast core. Feeds a fixed White line and times each Black reply."""
import sys, time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import match_fast as mf

CHUNK = mf.CHUNK_CYCLES
BUDGET = 400_000_000  # cap per move

# A short, forcing-ish White line so Colossus actually searches (not pure book).
WHITE = ["e2e4", "d2d4", "b1c3", "g1f3", "f1c4", "c1g5"]


def plies(col, screen):
    return {p for p, _ in mf.screen_move_entries(screen)}


def main():
    col = mf.FastColossus()
    try:
        col.disable_prediction()
    except Exception:
        pass
    rows = []
    wply, bply = 1, 2
    for wmv in WHITE:
        # Phase A: get White's move accepted (survive ponder key-eating).
        spentA = 0
        while True:
            scr = col.read_screen()
            if wply in plies(col, scr):
                break
            if col.mem(0x00C6, 1)[0] == 0:
                col.inject_move(wmv)
            col.run(CHUNK); spentA += CHUNK
            if spentA >= BUDGET:
                print(f"  (White {wmv} ply {wply} never accepted; stop)"); col.proc.kill(); return
        col.poke(0x00C6, [0])
        # Phase B: time Colossus's reply search.
        spentB = 0
        scr = col.read_screen()
        while bply not in plies(col, scr):
            col.run(CHUNK); spentB += CHUNK
            scr = col.read_screen()
            if spentB >= BUDGET:
                print(f"  (Colossus no reply to ply {bply} within budget; stop)"); col.proc.kill(); return
        st = mf.colossus_stats(scr)
        reply = dict(mf.screen_move_entries(scr)).get(bply, "?")
        rows.append((wmv, reply, spentB, st.get("lookahead"), st.get("positions")))
        print(f"  W {wmv} -> Colossus {reply}: ~{spentB/1e6:.0f}M cyc  "
              f"Lookahead={st.get('lookahead')}  Positions={st.get('positions')}")
        wply += 2; bply += 2
    col.proc.kill()
    moves = [r for r in rows if r[2] > CHUNK*2]   # drop instant (book) replies
    if moves:
        avg = sum(r[2] for r in moves)/len(moves)
        print(f"\nColossus searched-move avg: ~{avg/1e6:.0f}M cyc/move "
              f"(@1MHz {avg/1e6:.0f}s, @40MHz {avg/40e6:.2f}s) over {len(moves)} moves")


if __name__ == "__main__":
    main()
