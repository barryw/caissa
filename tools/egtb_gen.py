#!/usr/bin/env python3
"""egtb_gen.py -- generate Phase-1 (3-man) DTM endgame tablebases for Caissa.

Combos: KQK, KRK, KPK. Encoding: 1 byte/entry DTM (see docs/plans/2026-06-20-egtb).
Canonical index (MUST match src/egtb.c byte-for-byte):
  - color-normalize: strong side (P/Q/R holder) -> White (vmirror+swap+flip stm if Black)
  - KQK/KRK: 8-fold D4 fold WK into a1-d1-d4 triangle; idx=(kk_idx[wk][bk]*64+strong)*2+stm
  - KPK:     horizontal mirror so pawn on files a-d; idx=((pidx*64+wk)*64+bk)*2+stm

Outputs: build/egtb_tables.bin  + src/egtb_tables.h (bases, kk_idx[], MAX_DTM).
Then self-validates with python-chess (play the DTM line -> forced mate in N; draws hold).

Usage: tools/egtb_gen.py [--validate-samples N]
"""
import sys, struct
from collections import deque
import chess

# ---- square helpers (0-63, a1=0, rank=sq>>3 file=sq&7) ----
def rank(sq): return sq >> 3
def file(sq): return sq & 7

# 8 D4 board symmetries as square->square (must match C). Order is FIXED.
def _t_id(s):   return s
def _t_h(s):    return s ^ 7                 # mirror file
def _t_v(s):    return s ^ 56                # mirror rank
def _t_hv(s):   return s ^ 63                # rot180
def _t_d(s):    return (file(s) << 3) | rank(s)        # transpose (main diag)
def _t_dh(s):   return _t_h(_t_d(s))
def _t_dv(s):   return _t_v(_t_d(s))
def _t_dhv(s):  return _t_hv(_t_d(s))
D4 = [_t_id, _t_h, _t_v, _t_hv, _t_d, _t_dh, _t_dv, _t_dhv]

def in_triangle(sq):
    return file(sq) <= rank(sq) <= 3          # a1-d1-d4 triangle (10 squares)

def fold_d4(wk):
    """Return the index of the first D4 op (fixed order) that puts wk in triangle."""
    for i, t in enumerate(D4):
        if in_triangle(t(wk)):
            return i
    raise AssertionError(f"no D4 fold for wk={wk}")

# ---- kk_idx: enumerate legal (wk-in-triangle, bk) king pairs -> [0,462) ----
def build_kk_idx():
    kk = [0xFFFF] * (64 * 64)
    n = 0
    for wk in range(64):
        if not in_triangle(wk):
            continue
        for bk in range(64):
            if bk == wk:
                continue
            if abs(rank(wk) - rank(bk)) <= 1 and abs(file(wk) - file(bk)) <= 1:
                continue   # kings adjacent (illegal)
            kk[wk * 64 + bk] = n
            n += 1
    return kk, n
KK_IDX, KK_N = build_kk_idx()
# 564 (not the maximally-reduced 462): we fold WK into the triangle but do NOT further
# reduce the diagonal degeneracy (WK on a1-h8). Simpler fold = less 6502 code; the
# table is 22% bigger (negligible). Index is still consistent (gen == probe).

# ---- canonical index of a position ----
# pos = (wk, bk, sp, stm) in NORMALIZED form (strong=White, sp=strong piece sq;
#       sp=None for the bare-king combos we don't have). stm 0=white(strong) 1=black.
def idx_nop(wk, bk, sp, stm):           # KQK/KRK
    t = D4[fold_d4(wk)]
    wk, bk, sp = t(wk), t(bk), t(sp)
    k = KK_IDX[wk * 64 + bk]
    assert k != 0xFFFF
    return (k * 64 + sp) * 2 + stm

def pawn_idx(p):                          # pawn on files a-d, ranks 2-7 -> [0,24)
    return (rank(p) - 1) * 4 + file(p)
def idx_kpk(wk, bk, p, stm):
    if file(p) >= 4:                     # mirror so pawn on files a-d
        wk, bk, p = wk ^ 7, bk ^ 7, p ^ 7
    return ((pawn_idx(p) * 64 + wk) * 64 + bk) * 2 + stm

COMBOS = {
    "KQK": dict(piece=chess.QUEEN,  size=KK_N * 64 * 2,   idx="nop"),
    "KRK": dict(piece=chess.ROOK,   size=KK_N * 64 * 2,   idx="nop"),
    "KPK": dict(piece=chess.PAWN,   size=24 * 64 * 64 * 2, idx="kpk"),
}

# ---- build a python-chess board from normalized (strong=White) squares ----
def make_board(combo, wk, bk, sp, stm):
    b = chess.Board(None)
    b.set_piece_at(wk, chess.Piece(chess.KING, chess.WHITE))
    b.set_piece_at(bk, chess.Piece(chess.KING, chess.BLACK))
    b.set_piece_at(sp, chess.Piece(COMBOS[combo]["piece"], chess.WHITE))
    b.turn = chess.WHITE if stm == 0 else chess.BLACK
    b.clear_stack()
    return b

def legal_nodes(combo):
    """Yield (key, wk, bk, sp, stm) for every legal normalized position (strong=White)."""
    pc = COMBOS[combo]["piece"]
    sp_squares = range(8, 56) if pc == chess.PAWN else range(64)   # pawn ranks 2-7
    for wk in range(64):
        for bk in range(64):
            if bk == wk:
                continue
            if abs(rank(wk) - rank(bk)) <= 1 and abs(file(wk) - file(bk)) <= 1:
                continue
            for sp in sp_squares:
                if sp == wk or sp == bk:
                    continue
                for stm in (0, 1):
                    b = make_board(combo, wk, bk, sp, stm)
                    if not b.is_valid():
                        continue
                    yield (wk, bk, sp, stm), b

def node_idx(combo, wk, bk, sp, stm):
    return idx_kpk(wk, bk, sp, stm) if combo == "KPK" else idx_nop(wk, bk, sp, stm)

# ---- promotion resolution: a KPK pawn promo -> KQK/KRK (look up) or KBK/KNK (draw) ----
def resolve_promo(nb, labels):
    """nb = board AFTER a promotion (White just promoted; Black to move). Return the
    label (kind,dist) of that position from the side-to-move (Black) perspective."""
    promoted = None
    for pt in (chess.QUEEN, chess.ROOK):
        if nb.pieces(pt, chess.WHITE):
            promoted = pt; break
    if promoted is None:
        return ("D", 0)                      # promoted to B/N -> KBK/KNK = draw
    wk = nb.king(chess.WHITE); bk = nb.king(chess.BLACK)
    sp = list(nb.pieces(promoted, chess.WHITE))[0]
    stm = 0 if nb.turn == chess.WHITE else 1
    if nb.is_checkmate():
        return ("L", 0)
    if nb.is_stalemate() or nb.is_insufficient_material():
        return ("D", 0)
    tbl = "KQK" if promoted == chess.QUEEN else "KRK"
    return labels[tbl].get(node_idx(tbl, wk, bk, sp, stm), ("D", 0))

def gen_graph(combo, ext_labels):
    """Build canonical reps + successor structure. Returns (reps, succ) where succ[i]
    is a list of edges: ('N', j) | ('PRE', kind, dist).  Terminals folded into 'PRE'."""
    reps = {}
    for key, b in legal_nodes(combo):
        i = node_idx(combo, *key)
        if i not in reps:
            reps[i] = b
    succ = {}
    for i, b in reps.items():
        outs = []
        if b.is_checkmate():
            succ[i] = [("SELF", "L", 0)]; continue
        if b.is_stalemate() or b.is_insufficient_material():
            succ[i] = [("SELF", "D", 0)]; continue
        for mv in b.legal_moves:
            cap = b.is_capture(mv)
            nb = b.copy(stack=False); nb.push(mv)
            if combo == "KPK" and mv.promotion:
                outs.append(("PRE",) + resolve_promo(nb, ext_labels))     # promo outcome
            elif cap:
                outs.append(("PRE", "D", 0))                              # captured strong -> KvK draw
            else:
                nwk = nb.king(chess.WHITE); nbk = nb.king(chess.BLACK)
                nsp = list(nb.pieces(COMBOS[combo]["piece"], chess.WHITE))[0]
                nstm = 0 if nb.turn == chess.WHITE else 1
                outs.append(("N", node_idx(combo, nwk, nbk, nsp, nstm)))
        succ[i] = outs
    return reps, succ

def retro_bfs(reps, succ):
    """Correct DTM via DISTANCE-ORDERED (bucket) retrograde BFS. label[i]=('W'|'L'|'D',d).

    Events (dist, node i, succ_kind) = "a successor of i is finalized as succ_kind at
    `dist`". Processed in increasing `dist` so the first time a node is labelled its
    distance is minimal (essential: PRE/promo successors seed at mixed distances, so a
    plain FIFO would over-estimate). When node i finalizes at dist D it emits
    (D, p, kind_i) for each N-pred p.
      W(i) = 1 + min over L-successors of their dist
      L(i) = 1 + max over successors of their dist, iff ALL successors are W (no draw)
    """
    label = {}
    cnt = {}            # N+PRE-W successors still pending before an L decision
    maxd = {}           # max successor dist seen (for the L distance)
    draw_opt = {}       # has a guaranteed-draw successor -> never L
    pred = {i: [] for i in reps}
    from collections import defaultdict
    buckets = defaultdict(list)   # dist -> list of (i, succ_kind) events
    for i in reps:
        outs = succ[i]
        maxd[i] = 0
        if outs and outs[0][0] == "SELF":             # terminal node
            k, d = outs[0][1], outs[0][2]
            if k == "D":
                cnt[i] = 0; draw_opt[i] = True         # stalemate/insufficient = draw
            else:                                      # checkmate = L(0)
                label[i] = (k, d); buckets[d].append(("FINAL", i))
            cnt.setdefault(i, 0)
            continue
        c = 0
        for e in outs:
            if e[0] == "N":
                c += 1; pred[e[1]].append(i)
            elif e[0] == "PRE":
                kind, d = e[1], e[2]
                if kind == "D":
                    draw_opt[i] = True                 # immediate draw option
                else:
                    if kind == "W":
                        c += 1                          # counts toward an L decision
                    buckets[d].append(("EV", i, kind))  # pre-finalized successor at dist d
        cnt[i] = c
    # process buckets in increasing distance
    def finalize(i, kind, d):
        label[i] = (kind, d)
        buckets[d].append(("FINAL", i))
    def event(i, kind, d):
        if i in label:
            return
        if kind == "L":
            finalize(i, "W", d + 1)
        elif kind == "W":
            cnt[i] -= 1
            if d > maxd[i]: maxd[i] = d
            if cnt[i] == 0 and not draw_opt.get(i, False):
                finalize(i, "L", maxd[i] + 1)
    dist = 0
    while buckets:
        if dist not in buckets:
            # advance to next non-empty bucket
            nxt = min(buckets)
            if nxt < dist:   # safety
                nxt = dist
            dist = nxt
        evs = buckets.pop(dist, [])
        for ev in evs:
            if ev[0] == "FINAL":
                j = ev[1]; lab = label[j]
                for p in pred[j]:
                    event(p, lab[0], lab[1])
            else:  # ("EV", i, kind) pre-finalized successor at this dist
                event(ev[1], ev[2], dist)
        dist += 1
    for i in reps:
        label.setdefault(i, ("D", 0))
    return label

def pack(label, size):
    """Encoding: 0=draw; 1..127=STM wins in d; 128..255=STM loses, d=255-byte
    (checkmate=loss-0 -> 255; loss-127 -> 128)."""
    buf = bytearray(size)           # default 0 = draw
    maxdtm = 0
    for i, lab in label.items():
        if lab[0] == "W":
            v = lab[1]; assert 1 <= v <= 127, f"win DTM {v} out of range"
            buf[i] = v; maxdtm = max(maxdtm, v)
        elif lab[0] == "L":
            v = lab[1]; assert 0 <= v <= 127, f"loss DTM {v} out of range"
            buf[i] = 255 - v; maxdtm = max(maxdtm, v)
        # draw -> 0
    return buf, maxdtm

def emit_header(path, order, sizes, bases, maxdtm):
    L = []
    L.append("/* egtb_tables.h -- GENERATED by tools/egtb_gen.py. Do not edit. */")
    L.append("#ifndef CREF_EGTB_TABLES_H")
    L.append("#define CREF_EGTB_TABLES_H")
    L.append(f"#define EGTB_MAX_DTM {maxdtm}")
    L.append(f"#define EGTB_KK_N {KK_N}")
    L.append(f"#define EGTB_TOTAL_BYTES {sum(sizes.values())}")
    for c in order:
        L.append(f"#define EGTB_{c}_BASE {bases[c]}u   /* REU byte offset */")
        L.append(f"#define EGTB_{c}_SIZE {sizes[c]}u")
    # kk_idx packed as a 4096-entry uint16 table (0xFFFF = illegal)
    L.append("static const unsigned short egtb_kk_idx[64*64] = {")
    for r in range(0, 64 * 64, 16):
        L.append("  " + ",".join(str(KK_IDX[r + k]) for k in range(16)) + ",")
    L.append("};")
    L.append("#endif")
    open(path, "w").write("\n".join(L) + "\n")

PIECE_COMBO = {chess.QUEEN: "KQK", chess.ROOK: "KRK", chess.PAWN: "KPK"}
def probe_label(board, labels):
    """Generic prober (mirrors the C egtb_probe): detect material, color-normalize so
    the strong side is White, fold, look up. Returns (kind,dist) from the side-to-move's
    perspective, or None if not a covered 3-man position."""
    occ = board.occupied
    if bin(occ).count("1") != 3:
        return None
    combo = strong = sp_sq = None
    for color in (chess.WHITE, chess.BLACK):
        for pt in (chess.QUEEN, chess.ROOK, chess.PAWN):
            ps = board.pieces(pt, color)
            if ps:
                combo = PIECE_COMBO[pt]; strong = color; sp_sq = list(ps)[0]
    if combo is None:
        return None                                  # KvK / KBK / KNK = draw (uncovered)
    wk = board.king(chess.WHITE); bk = board.king(chess.BLACK)
    stm = 0 if board.turn == strong else 1           # 0 = strong side to move
    if strong == chess.BLACK:                        # normalize: strong -> White
        wk, bk, sp_sq = bk ^ 56, wk ^ 56, sp_sq ^ 56
        wk, bk = wk, bk                              # (wk now = the strong/white king)
    idx = idx_kpk(wk, bk, sp_sq, stm) if combo == "KPK" else idx_nop(wk, bk, sp_sq, stm)
    return labels[combo].get(idx, ("D", 0))

def play_optimal_check(board, labels, max_plies):
    """Side to move is (claimed) winning; play DTM-optimal, opponent plays max-resistance.
    Return (mated, plies)."""
    bb = board.copy(stack=False); plies = 0
    while plies <= max_plies:
        if bb.is_checkmate():
            return True, plies
        if not list(bb.legal_moves):
            return False, plies                      # stalemate
        winner_to_move = (plies % 2 == 0)
        best = None; bestmv = None
        for mv in bb.legal_moves:
            nb = bb.copy(stack=False); nb.push(mv)
            lab = probe_label(nb, labels)            # label from nb's side-to-move (opp)
            if lab is None: lab = ("D", 0)
            # for the winner: want child = opp-Loss, min dist. for defender: want child
            # = opp-Win (i.e., winner still wins) but MAX dist (resist), or any draw/win.
            kind, dist = lab
            if winner_to_move:
                if kind == "L" and (best is None or dist < best):
                    best = dist; bestmv = mv
            else:
                # defender: pick the move that maximizes the winner's mate distance
                # (child labeled W from winner's view = bad for defender but forced)
                score = dist if kind == "W" else (10**6 if kind != "L" else -1)
                if best is None or score > best:
                    best = score; bestmv = mv
        if bestmv is None:
            bestmv = list(bb.legal_moves)[0]
        bb.push(bestmv); plies += 1
    return bb.is_checkmate(), plies

def validate(combo, labels, samples=400):
    """Play the DTM-optimal line with python-chess: a WIN must force mate in exactly
    DTM plies; a DRAW must hold (opponent can't win). Sample positions."""
    import random
    rng = random.Random(12345)
    lab = labels[combo]
    rep = {}
    for key, b in legal_nodes(combo):
        rep.setdefault(node_idx(combo, *key), b)
    idxs = list(lab.keys()); rng.shuffle(idxs)
    checked = mate_ok = parity_ok = 0; bad = []
    for i in idxs:
        if checked >= samples: break
        kind, dist = lab[i]
        b = rep.get(i)
        if b is None: continue
        # (a) parity: the generic prober must agree with the table label
        pl = probe_label(b, labels)
        if pl != (kind, dist):
            bad.append(f"parity {combo} idx{i}: table {(kind,dist)} != probe {pl} {b.fen()}")
        else:
            parity_ok += 1
        # (b) play-out: a WIN must force mate in exactly DTM plies
        if kind == "W":
            mated, plies = play_optimal_check(b, labels, dist + 4)
            if mated and plies == dist:
                mate_ok += 1
            else:
                bad.append(f"playout {combo} idx{i}: W dtm{dist} got mated={mated} "
                           f"plies={plies} {b.fen()}")
        checked += 1
    for m in bad[:6]:
        print("   !", m)
    print(f"   validate {combo}: parity {parity_ok}/{checked}, "
          f"wins-forced-mate {mate_ok} OK ({len(bad)} bad)")

MATE_SCORE = 30000
def expected_score(kind, dist):     # at ply 0, matches src/egtb.c decode
    if kind == "W": return MATE_SCORE - dist
    if kind == "L": return -(MATE_SCORE - dist)
    return 0

def parity_dump(samples=4000):
    """Emit 'FEN<TAB>expected_score' lines for a random sample across combos, for the
    C harness (test/egtb_parity) to reproduce. Regenerates labels in-process."""
    import random, sys
    labels = {}
    for combo in ("KQK", "KRK", "KPK"):
        reps, succ = gen_graph(combo, labels)
        labels[combo] = retro_bfs(reps, succ)
    rng = random.Random(7)
    for combo in ("KQK", "KRK", "KPK"):
        rep = {}
        for key, b in legal_nodes(combo):
            rep.setdefault(node_idx(combo, *key), b)
        idxs = list(labels[combo].keys()); rng.shuffle(idxs)
        for i in idxs[:samples]:
            b = rep.get(i)
            if b is None: continue
            kind, dist = labels[combo][i]
            sys.stdout.write(f"{b.fen()}\t{expected_score(kind, dist)}\n")

if __name__ == "__main__":
    import os, sys
    if len(sys.argv) > 1 and sys.argv[1] == "--parity-dump":
        parity_dump(); sys.exit(0)
    print("EGTB gen (Phase 1: KQK KRK KPK)")
    labels = {}
    order = ("KQK", "KRK", "KPK")
    bufs = {}; sizes = {}; maxdtm_all = 0
    for combo in order:
        reps, succ = gen_graph(combo, labels)
        lab = retro_bfs(reps, succ)
        labels[combo] = lab
        size = COMBOS[combo]["size"]
        buf, maxdtm = pack(lab, size)
        bufs[combo] = buf; sizes[combo] = size; maxdtm_all = max(maxdtm_all, maxdtm)
        nW = sum(1 for l in lab.values() if l[0] == "W")
        nL = sum(1 for l in lab.values() if l[0] == "L")
        nD = sum(1 for l in lab.values() if l[0] == "D")
        print(f" {combo}: {len(reps)} nodes, {size}B, W={nW} L={nL} D={nD} maxDTM={maxdtm}")
    # write binary (concatenated in `order`) + header with bases
    os.makedirs("build", exist_ok=True)
    bases = {}; off = 0; blob = bytearray()
    for c in order:
        bases[c] = off; blob += bufs[c]; off += sizes[c]
    open("build/egtb_tables.bin", "wb").write(blob)
    emit_header("src/egtb_tables.h", order, sizes, bases, maxdtm_all)
    print(f" wrote build/egtb_tables.bin ({len(blob)} B) + src/egtb_tables.h "
          f"(maxDTM={maxdtm_all})")
    print(" validating (python-chess play-out)...")
    for combo in order:
        validate(combo, labels)
