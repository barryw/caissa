#!/usr/bin/env python3
"""Texel-tune the engine's material + PST weights against a labeled dataset.

The material+PST eval is LINEAR in its weights (eval = sum over pieces of
+-(piece_value + pst[type][square])), so each position becomes a sparse feature
vector and the whole fit is fast numpy logistic regression:

    target_i = sigmoid(sf_cp_i / K)
    pred_i   = sigmoid(eval_cp_i(w) / K)
    loss     = mean((pred - target)^2) + lambda * ||w - w0||^2

Pawn value is anchored (sets the scale); knight/bishop/rook/queen values and all
six PSTs are tunable. L2 toward the current hand-tuned values (w0) keeps PST
cells sane where data is thin. eval is in native real centipawns (the PST cells
are added directly to material; no x10). --write regenerates the PST_* arrays +
material constants in native/eval.c and keeps tools/texel_eval.py in sync (so it
stays the faithful native oracle).

GROUND TRUTH = absolute Elo vs Stockfish (tools/native_vs_stockfish.py), NOT
self-play: self-play A/B was measured to inflate eval gains to ~0 absolute
(+45 self-play -> +9 vs SF). An MSE improvement here is necessary, not
sufficient; confirm any written change with native_vs_stockfish (baseline vs
this), large sample. A correctness gate (verify_gate) asserts the linear model
reproduces eval_material_pst bit-exact before tuning.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import numpy as np  # noqa: E402
import chess  # noqa: E402

import texel_eval as te  # noqa: E402

REPO = Path(__file__).resolve().parents[1]
# Tunable piece types and their material params (pawn anchored, king fixed 0).
MAT_TYPES = [chess.KNIGHT, chess.BISHOP, chess.ROOK, chess.QUEEN]
PST_TYPES = [chess.PAWN, chess.KNIGHT, chess.BISHOP, chess.ROOK, chess.QUEEN, chess.KING]
# Param layout: [4 material] + [6*64 PST]. Index helpers:
N_MAT = len(MAT_TYPES)
N_PARAMS = N_MAT + len(PST_TYPES) * 64


def _mat_idx(pt: int) -> int:
    return MAT_TYPES.index(pt)


def _pst_base(pt: int) -> int:
    return N_MAT + PST_TYPES.index(pt) * 64


def initial_weights() -> np.ndarray:
    w = np.zeros(N_PARAMS, dtype=np.float64)
    for pt in MAT_TYPES:
        w[_mat_idx(pt)] = te.PIECE_VALUE_TBL[pt]
    for pt in PST_TYPES:
        b = _pst_base(pt)
        w[b:b + 64] = np.array(te.PST[pt], dtype=np.float64)
    return w


def build_features(positions: list[dict]) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Return (X, const, target_cp): eval_units = const + X @ w (engine units)."""
    n = len(positions)
    X = np.zeros((n, N_PARAMS), dtype=np.float64)
    const = np.zeros(n, dtype=np.float64)
    target_cp = np.zeros(n, dtype=np.float64)
    for i, rec in enumerate(positions):
        board = chess.Board(rec["fen"])
        target_cp[i] = rec["cp"]
        for sq, piece in board.piece_map().items():
            pt = piece.piece_type
            sign = 1.0 if piece.color == chess.WHITE else -1.0
            idx64 = te._pst_index_white(sq) if piece.color == chess.WHITE else te._pst_index_black(sq)
            X[i, _pst_base(pt) + idx64] += sign
            if pt in MAT_TYPES:
                X[i, _mat_idx(pt)] += sign
            elif pt == chess.PAWN:
                const[i] += sign * te.PIECE_VALUE_TBL[chess.PAWN]
            # king material = 0
    return X, const, target_cp


def sigmoid(x: np.ndarray) -> np.ndarray:
    return 1.0 / (1.0 + np.exp(-x))


def best_k(eval_cp: np.ndarray, target_prob: np.ndarray) -> float:
    best, bk = 1e18, 200.0
    for k in range(80, 601, 20):
        loss = np.mean((sigmoid(eval_cp / k) - target_prob) ** 2)
        if loss < best:
            best, bk = loss, float(k)
    return bk


def loss_of(w, X, const, target_prob, K, lam, w0):
    eval_cp = const + X @ w          # native units = real centipawns (no x10)
    pred = sigmoid(eval_cp / K)
    return float(np.mean((pred - target_prob) ** 2) + lam * np.mean((w - w0) ** 2))


def tune(positions, lam=1e-6, iters=6000, lr=3.0, K=300.0):
    w0 = initial_weights()
    X, const, target_cp = build_features(positions)
    n = len(positions)
    # Same sigmoid scale for label and prediction: minimizing MSE then drives
    # eval_cp -> sf_cp (sigmoid-weighted, downweighting saturated extremes).
    target_prob = sigmoid(target_cp / K)
    w = w0.copy()
    # Adam.
    m = np.zeros_like(w); v = np.zeros_like(w)
    b1, b2, eps = 0.9, 0.999, 1e-8
    fixed = np.zeros(N_PARAMS, dtype=bool)
    # Freeze PST cells that never occur (no gradient anyway, but be explicit):
    # pawn PST ranks 1 and 8 (indices 0-7, 56-63) are never used.
    pb = _pst_base(chess.PAWN)
    fixed[pb:pb + 8] = True
    fixed[pb + 56:pb + 64] = True
    for t in range(1, iters + 1):
        eval_cp = const + X @ w          # native units = real centipawns (no x10)
        pred = sigmoid(eval_cp / K)
        d = (pred - target_prob) * pred * (1 - pred)  # dLoss/d eval_cp * K  (per-sample, /n later)
        grad = (1.0 / K) * (X.T @ (2.0 * d / n)) + 2.0 * lam * (w - w0)
        grad[fixed] = 0.0
        m = b1 * m + (1 - b1) * grad
        v = b2 * v + (1 - b2) * grad * grad
        mh = m / (1 - b1 ** t); vh = v / (1 - b2 ** t)
        w = w - lr * mh / (np.sqrt(vh) + eps)
    return w0, w, X, const, target_prob, K


def round_weights(w: np.ndarray) -> np.ndarray:
    r = np.rint(w).astype(int)
    for pt in PST_TYPES:
        b = _pst_base(pt)
        # native PST cells are plain `int` (not signed bytes); keep generous
        # bound to avoid 16-bit eval-accumulator overflow surprises.
        r[b:b + 64] = np.clip(r[b:b + 64], -2000, 2000)
    for pt in MAT_TYPES:
        r[_mat_idx(pt)] = max(0, int(r[_mat_idx(pt)]))
    return r


def fmt_byte(v: int) -> str:
    return str(v) if v >= 0 else f"<({v})"


def verify_gate(positions: list[dict], w0: np.ndarray,
                X: np.ndarray, const: np.ndarray) -> None:
    """The linear model (const + X @ w0) MUST equal texel_eval.eval_material_pst
    (white-POV material+PST) for every position, or the features/scale are
    wrong. This is the load-bearing correctness gate (mirrors native_eval_check).
    """
    model = const + X @ w0
    bad = 0
    for i, rec in enumerate(positions):
        ref = te.eval_material_pst(chess.Board(rec["fen"]))
        if int(round(model[i])) != ref:
            bad += 1
            if bad <= 3:
                print(f"  MISMATCH @ {rec['fen']}: model={model[i]:.1f} ref={ref}")
    n = len(positions)
    if bad:
        raise SystemExit(f"GATE FAILED: {bad}/{n} positions mismatch model vs eval_material_pst")
    print(f"GATE: {n}/{n} positions bit-exact (linear model == eval_material_pst)")


# --- native write-back (regenerate native/eval.c PST arrays + material, and
#     keep tools/texel_eval.py in sync so it stays the faithful native oracle) -

_NATIVE_PST = {chess.PAWN: "PST_PAWN", chess.KNIGHT: "PST_KNIGHT",
               chess.BISHOP: "PST_BISHOP", chess.ROOK: "PST_ROOK",
               chess.QUEEN: "PST_QUEEN", chess.KING: "PST_KING_MID"}
_PY_PST = dict(_NATIVE_PST)   # same symbol names in texel_eval.py
_MAT_C = {chess.KNIGHT: "knight", chess.BISHOP: "bishop",
          chess.ROOK: "rook", chess.QUEEN: "queen"}
_MAT_PY = {chess.KNIGHT: "KNIGHT_VALUE", chess.BISHOP: "BISHOP_VALUE",
           chess.ROOK: "ROOK_VALUE", chess.QUEEN: "QUEEN_VALUE"}


def _pst_vals(weights: np.ndarray, pt: int) -> list[int]:
    b = _pst_base(pt)
    return [int(weights[b + i]) for i in range(64)]


def _rows_body(vals: list[int]) -> str:
    rows = []
    for r in range(8):
        rows.append("    " + ", ".join(str(v) for v in vals[r * 8:r * 8 + 8]) + ",")
    return "\n".join(rows)


def _replace_block(txt: str, head: str, tail: str, body: str) -> str:
    """Replace the inner body of a `head ... tail` block (head/tail are regex)."""
    pat = re.compile(rf"({head})(.*?)({tail})", re.S)
    m = pat.search(txt)
    if not m:
        raise SystemExit(f"write-back: could not match /{head}/ ... /{tail}/")
    return txt[:m.start()] + m.group(1) + "\n" + body + m.group(3) + txt[m.end():]


def write_back(weights: np.ndarray) -> None:
    # native/eval.c : static const int PST_NAME[64] = {\n ... \n};
    evalc = REPO / "native" / "eval.c"
    txt = evalc.read_text()
    for pt, name in _NATIVE_PST.items():
        head = rf"static const int {name}\[64\] = \{{"
        txt = _replace_block(txt, head, r"\n\};", _rows_body(_pst_vals(weights, pt)))
    for pt, nm in _MAT_C.items():       # g_w.<piece> = NNN;
        val = int(weights[_mat_idx(pt)])
        txt = re.sub(rf"(g_w\.{nm}\s*=\s*)\d+(;)", rf"\g<1>{val}\g<2>", txt, count=1)
    evalc.write_text(txt)

    # tools/texel_eval.py : PST_NAME = [\n ... \n]  and  <PIECE>_VALUE = NNN
    pyf = REPO / "tools" / "texel_eval.py"
    ptxt = pyf.read_text()
    for pt, name in _PY_PST.items():
        head = rf"{name} = \["
        ptxt = _replace_block(ptxt, head, r"\n\]", _rows_body(_pst_vals(weights, pt)))
    for pt, nm in _MAT_PY.items():
        val = int(weights[_mat_idx(pt)])
        ptxt = re.sub(rf"^{nm}\s*=\s*\d+", f"{nm} = {val}", ptxt, count=1, flags=re.M)
    pyf.write_text(ptxt)


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--data", type=Path, default=REPO / "build" / "texel_data.json")
    p.add_argument("--lam", type=float, default=2e-4)
    p.add_argument("--iters", type=int, default=4000)
    p.add_argument("--lr", type=float, default=2.0)
    p.add_argument("--write", action="store_true", help="regenerate pst.s + patch eval.s piece values")
    args = p.parse_args(argv)

    data = json.loads(args.data.read_text())
    positions = data["positions"]
    print(f"dataset: {len(positions)} positions (label_depth={data.get('label_depth')})")

    w0, w, X, const, target_prob, K = tune(positions, args.lam, args.iters, args.lr)
    # Load-bearing correctness gate: the linear model must reproduce the native
    # material+PST eval exactly before we trust any tuned output.
    verify_gate(positions, w0, X, const)
    l0 = loss_of(w0, X, const, target_prob, K, 0.0, w0)
    l1 = loss_of(w, X, const, target_prob, K, 0.0, w0)
    wr = round_weights(w).astype(np.float64)
    lr_ = loss_of(wr, X, const, target_prob, K, 0.0, w0)
    print(f"K={K:.0f}  MSE: baseline={l0:.5f}  tuned(float)={l1:.5f}  tuned(int)={lr_:.5f}")
    print(f"improvement: {100*(l0-lr_)/l0:.2f}% MSE reduction")
    print("piece values:", {chess.piece_name(pt): (int(w0[_mat_idx(pt)]), int(wr[_mat_idx(pt)])) for pt in MAT_TYPES})

    if args.write:
        write_back(round_weights(w))
        print("wrote native/eval.c PST + material; synced tools/texel_eval.py")
        print("NEXT: make -C native; native_eval_check (22157 bit-exact);")
        print("      native_vs_stockfish baseline-vs-this (ABSOLUTE gate -- NOT self-play).")
    else:
        print("(dry run; pass --write to apply to native/eval.c + texel_eval.py)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
