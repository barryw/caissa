#!/usr/bin/env python3
"""Python port of the engine's static eval, for Texel weight tuning.

Tuning weights needs the eval evaluated millions of times with varying weights;
the 6502 eval via sim6502 is far too slow for that, so we mirror it here in
Python (fast, mutable weights) and verify the port against the engine's own eval
through the bridge `eval` command. The self-play A/B harness is the final
ground-truth gate, so the port only has to be faithful enough to point at better
weights -- but we drive it toward exact agreement term by term.

This file is built up incrementally and verified at each stage:
  stage 1 (DONE):  material + PST            -> matches engine lazy eval (lazy=1)
  stage 2 (DONE):  + every full-eval term    -> matches engine full eval (lazy=0)

`eval_full(board)` reproduces the engine's complete non-lazy static eval as a
function of the weight constants below. It is byte-faithful to the 6502 routines
in src/ai/eval.s with the current Part B (x10 centipawn) constants, INCLUDING
the king-safety signed-byte wraparound (load-bearing on ~0.5% of positions).

All scores are WHITE-POV in centipawns, matching the engine's EvalScore (a 16-bit
signed value; we mask to 16-bit two's complement at the end to mirror overflow).

How to use:
    from texel_eval import eval_full, build_board88
    cp = eval_full(chess.Board(fen))      # full static eval, white-POV centipawns
    cp = eval_material_pst(chess.Board(fen))  # lazy stage only (material + PST)

Run `python3 tools/texel_eval.py` to verify both stages against the engine bridge.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import chess  # noqa: E402

# ---------------------------------------------------------------------------
# Weight constants (from src/ai/eval.s; the tunable parameters)
# Part B centipawn rescale: every term constant is x10 of its pre-rescale value
# (pawn = 100 = literal centipawns), EXCEPT the king-safety byte constants which
# stay at the pre-rescale (x1) magnitude and are multiplied by 10 after a signed
# *byte* accumulation (see EvaluateSingleKingSafety / KingSafetyByteX10).
# ---------------------------------------------------------------------------
PAWN_VALUE = 100
KNIGHT_VALUE = 366
BISHOP_VALUE = 302
ROOK_VALUE = 466
QUEEN_VALUE = 874
KING_VALUE = 0

# Tactical pressure
PAWN_ATTACK_MINOR_PENALTY = 600
PAWN_ATTACK_ROOK_PENALTY = 600
PAWN_ATTACK_QUEEN_PENALTY = 850
QUEEN_ATTACK_MINOR_PENALTY = 750
MINOR_ATTACK_ROOK_PENALTY = 280
MINOR_ATTACK_QUEEN_PENALTY = 350
KNIGHT_OUTPOST_BONUS = 250
PINNED_PAWN_PENALTY = 120
PINNED_MINOR_PENALTY = 250
PINNED_ROOK_PENALTY = 350
PINNED_QUEEN_PENALTY = 450
PINNED_ATTACKED_PENALTY = 200

# Pawn structure
DOUBLED_PAWN_PENALTY = 150
ISOLATED_PAWN_PENALTY = 200
ADVANCED_PAWN_BONUS = 80
DEEP_ADVANCED_PAWN_BONUS = 160
ROOK_BEHIND_PASSER_BONUS = 200
CONNECTED_PASSER_BONUS = 120
PROTECTED_PASSER_BONUS = 80
BLOCKADED_PASSER_PENALTY = 100
BISHOP_PAIR_BONUS = 200
ROOK_OPEN_FILE_BONUS = 250
ROOK_SEMI_OPEN_FILE_BONUS = 120
HEAVY_SEVENTH_RANK_BONUS = 180
ENDGAME_NONPAWN_LIMIT = 1
ENDGAME_KING_ACTIVITY_BONUS = 300
ENDGAME_ROOK_OPEN_FILE_BONUS = 600
ENDGAME_ROOK_KING_CUTOFF_BONUS = 250

# Passed pawn bonus by rank (row 0 = rank 8 .. row 7 = rank 1)
PASSED_PAWN_BONUS = [400, 300, 250, 200, 150, 100, 0, 0]

# King safety (PRE-rescale x1 magnitudes; product later x10)
CASTLED_BONUS = 30
PAWN_SHIELD_BONUS = 10
OPEN_FILE_PENALTY = 25
SEMI_OPEN_FILE_PENALTY = 12
KING_CENTER_PENALTY = 30
KING_MARCH_BASE = 8
KING_MARCH_STEP = 8
KING_ZONE_ATTACK_PENALTY = 5

# Piece-type penalty lookup tables (index 1..6 = pawn..king)
PIECE_VALUE_TBL = [0, PAWN_VALUE, KNIGHT_VALUE, BISHOP_VALUE, ROOK_VALUE, QUEEN_VALUE, KING_VALUE]
PAWN_ATTACK_PENALTY = [0, 0, PAWN_ATTACK_MINOR_PENALTY, PAWN_ATTACK_MINOR_PENALTY,
                       PAWN_ATTACK_ROOK_PENALTY, PAWN_ATTACK_QUEEN_PENALTY, 0]
QUEEN_ATTACK_PENALTY = [0, 0, QUEEN_ATTACK_MINOR_PENALTY, QUEEN_ATTACK_MINOR_PENALTY, 0, 0, 0]
MINOR_ATTACK_PENALTY = [0, 0, 0, 0, MINOR_ATTACK_ROOK_PENALTY, MINOR_ATTACK_QUEEN_PENALTY, 0]
PINNED_PIECE_PENALTY = [0, PINNED_PAWN_PENALTY, PINNED_MINOR_PENALTY, PINNED_MINOR_PENALTY,
                        PINNED_ROOK_PENALTY, PINNED_QUEEN_PENALTY, 0]

# ---------------------------------------------------------------------------
# Piece-square tables (from src/ai/pst.s), index 0 = a8, 63 = h1.
# These are the x10 (Part B) tables. Engine stores signed 16-bit; we keep ints.
# ---------------------------------------------------------------------------
PST_PAWN = [
    0, 0, 0, 0, 0, 0, 0, 0,
    237, 121, 122, 117, 141, 98, 143, 59,
    28, 37, 30, 74, 31, 45, 34, 2,
    3, 2, -13, -15, 15, -5, -7, 27,
    -13, -4, -16, 2, -14, -6, 13, -7,
    -24, -14, -10, -48, -26, 7, 23, -19,
    -11, -8, -10, -73, -23, 20, 29, -25,
    0, 0, 0, 0, 0, 0, 0, 0,
]
PST_KNIGHT = [
    -294, -127, -101, -112, -190, -74, 17, -205,
    -102, -105, -117, -39, -77, -48, -86, -49,
    -144, -76, -48, -51, -35, -70, -41, -125,
    -83, -86, -77, -51, -56, -43, -71, -55,
    -106, -82, -56, -59, -92, -72, -68, -95,
    -106, -104, -83, -55, -45, -78, -73, -137,
    -98, -44, -84, -100, -70, -85, -59, -85,
    -152, -132, -102, -74, -107, -128, -121, 133,
]
PST_BISHOP = [
    -39, -61, -31, -8, -23, -46, -110, -52,
    -53, -29, -31, 16, -36, 25, -89, -49,
    0, -47, -29, 14, 15, -43, -56, 22,
    -39, -5, 0, 27, -2, 3, 7, 3,
    32, 4, 25, 4, 26, 13, 15, -2,
    -5, 46, -3, 32, -1, 25, 10, 1,
    -5, -15, 32, -14, 9, -8, 24, 16,
    40, 18, -39, -11, -25, -11, 42, -33,
]
PST_ROOK = [
    11, 7, 14, -14, 38, 39, -4, 5,
    16, 9, 43, 23, 41, 38, -4, 66,
    33, 12, 20, 52, 10, 15, 26, -22,
    9, 1, -13, 11, 5, -4, 18, 5,
    -2, -2, -9, -4, -9, -8, 1, 12,
    9, 5, -3, 1, -11, 4, 14, 28,
    -28, -25, -4, 11, -18, -2, -16, -29,
    -15, -18, -2, 10, 11, -17, -26, -41,
]
PST_QUEEN = [
    -132, -134, -151, -26, -18, -22, -48, 20,
    -78, -50, 1, -23, -28, 119, -46, 65,
    -81, -20, -39, -23, 27, 120, -53, 63,
    -67, -73, -28, -36, 8, -13, 18, 11,
    -72, -21, -56, -47, -24, -15, -22, 10,
    -18, -47, -35, -41, -11, -12, -37, -37,
    -82, -33, -26, -30, -34, -20, -27, 1,
    -47, -51, -45, -41, -12, -101, -24, -51,
]
PST_KING_MID = [
    -482, -387, -603, -625, -276, -309, -222, 281,
    -345, -286, -261, -298, -299, -358, -301, -173,
    -310, -253, -339, -278, -351, -230, -221, -275,
    -281, -294, -277, -265, -314, -305, -289, -334,
    -380, -294, -299, -316, -325, -349, -330, -338,
    -367, -337, -342, -318, -317, -340, -338, -371,
    -346, -343, -339, -343, -345, -342, -336, -339,
    -346, -310, -339, -387, -350, -358, -339, -330,
]
PST = {
    chess.PAWN: PST_PAWN, chess.KNIGHT: PST_KNIGHT, chess.BISHOP: PST_BISHOP,
    chess.ROOK: PST_ROOK, chess.QUEEN: PST_QUEEN, chess.KING: PST_KING_MID,
}
# Indexed by piece type 1..6 for the 0x88 engine-faithful path.
PST_BY_TYPE = [None, PST_PAWN, PST_KNIGHT, PST_BISHOP, PST_ROOK, PST_QUEEN, PST_KING_MID]

# ---------------------------------------------------------------------------
# Endgame piece-square tables. Phase-tapered against the MG tables above (see
# eval_full / eval_material_pst). Initialized as EXACT copies of the MG tables,
# so the eval stays bit-identical to the pre-taper baseline until later tuning
# diverges these EG values.
# ---------------------------------------------------------------------------
PST_EG_PAWN = [
    0, 0, 0, 0, 0, 0, 0, 0,
    237, 121, 122, 117, 141, 98, 143, 59,
    28, 37, 30, 74, 31, 45, 34, 2,
    3, 2, -13, -15, 15, -5, -7, 27,
    -13, -4, -16, 2, -14, -6, 13, -7,
    -24, -14, -10, -48, -26, 7, 23, -19,
    -11, -8, -10, -73, -23, 20, 29, -25,
    0, 0, 0, 0, 0, 0, 0, 0,
]
PST_EG_KNIGHT = [
    -294, -127, -101, -112, -190, -74, 17, -205,
    -102, -105, -117, -39, -77, -48, -86, -49,
    -144, -76, -48, -51, -35, -70, -41, -125,
    -83, -86, -77, -51, -56, -43, -71, -55,
    -106, -82, -56, -59, -92, -72, -68, -95,
    -106, -104, -83, -55, -45, -78, -73, -137,
    -98, -44, -84, -100, -70, -85, -59, -85,
    -152, -132, -102, -74, -107, -128, -121, 133,
]
PST_EG_BISHOP = [
    -39, -61, -31, -8, -23, -46, -110, -52,
    -53, -29, -31, 16, -36, 25, -89, -49,
    0, -47, -29, 14, 15, -43, -56, 22,
    -39, -5, 0, 27, -2, 3, 7, 3,
    32, 4, 25, 4, 26, 13, 15, -2,
    -5, 46, -3, 32, -1, 25, 10, 1,
    -5, -15, 32, -14, 9, -8, 24, 16,
    40, 18, -39, -11, -25, -11, 42, -33,
]
PST_EG_ROOK = [
    11, 7, 14, -14, 38, 39, -4, 5,
    16, 9, 43, 23, 41, 38, -4, 66,
    33, 12, 20, 52, 10, 15, 26, -22,
    9, 1, -13, 11, 5, -4, 18, 5,
    -2, -2, -9, -4, -9, -8, 1, 12,
    9, 5, -3, 1, -11, 4, 14, 28,
    -28, -25, -4, 11, -18, -2, -16, -29,
    -15, -18, -2, 10, 11, -17, -26, -41,
]
PST_EG_QUEEN = [
    -132, -134, -151, -26, -18, -22, -48, 20,
    -78, -50, 1, -23, -28, 119, -46, 65,
    -81, -20, -39, -23, 27, 120, -53, 63,
    -67, -73, -28, -36, 8, -13, 18, 11,
    -72, -21, -56, -47, -24, -15, -22, 10,
    -18, -47, -35, -41, -11, -12, -37, -37,
    -82, -33, -26, -30, -34, -20, -27, 1,
    -47, -51, -45, -41, -12, -101, -24, -51,
]
PST_EG_KING = [
    -482, -387, -603, -625, -276, -309, -222, 281,
    -345, -286, -261, -298, -299, -358, -301, -173,
    -310, -253, -339, -278, -351, -230, -221, -275,
    -281, -294, -277, -265, -314, -305, -289, -334,
    -380, -294, -299, -316, -325, -349, -330, -338,
    -367, -337, -342, -318, -317, -340, -338, -371,
    -346, -343, -339, -343, -345, -342, -336, -339,
    -346, -310, -339, -387, -350, -358, -339, -330,
]
PST_EG = {
    chess.PAWN: PST_EG_PAWN, chess.KNIGHT: PST_EG_KNIGHT, chess.BISHOP: PST_EG_BISHOP,
    chess.ROOK: PST_EG_ROOK, chess.QUEEN: PST_EG_QUEEN, chess.KING: PST_EG_KING,
}
# Indexed by piece type 1..6 for the 0x88 engine-faithful path.
PST_EG_BY_TYPE = [None, PST_EG_PAWN, PST_EG_KNIGHT, PST_EG_BISHOP, PST_EG_ROOK,
                  PST_EG_QUEEN, PST_EG_KING]

# Game-phase weight by piece type (1..6): N/B=1, R=2, Q=4, pawn/king=0.
PHASE_WEIGHT = [0, 0, 1, 1, 2, 4, 0]

# ---------------------------------------------------------------------------
# 0x88 engine constants
# ---------------------------------------------------------------------------
WHITE_COLOR = 0x80
EMPTY = 0
# Piece byte encoding mirrors the engine: low 3 bits = type, bit7 = white color.
# We use a synthetic base (1..6 == type) so (byte & 7) == type and (byte & 0x80)
# == color, which is all the eval routines ever test.
PAWN_T, KNIGHT_T, BISHOP_T, ROOK_T, QUEEN_T, KING_T = 1, 2, 3, 4, 5, 6
WHITE_PAWN = PAWN_T | WHITE_COLOR
BLACK_PAWN = PAWN_T
WHITE_KNIGHT = KNIGHT_T | WHITE_COLOR
BLACK_KNIGHT = KNIGHT_T
WHITE_BISHOP = BISHOP_T | WHITE_COLOR
BLACK_BISHOP = BISHOP_T
WHITE_ROOK = ROOK_T | WHITE_COLOR
BLACK_ROOK = ROOK_T
WHITE_QUEEN = QUEEN_T | WHITE_COLOR
BLACK_QUEEN = QUEEN_T

OFFBOARD_MASK = 0x88
BOARD_SIZE = 0x80

KNIGHT_OFFSETS = [0xDF, 0xE1, 0xEE, 0xF2, 0x0E, 0x12, 0x1F, 0x21]
ORTHOGONAL_OFFSETS = [0xF0, 0x10, 0xFF, 0x01]
DIAGONAL_OFFSETS = [0xEF, 0xF1, 0x0F, 0x11]
ALL_DIRECTION_OFFSETS = [0xEF, 0xF0, 0xF1, 0xFF, 0x01, 0x0F, 0x10, 0x11]
# Pin slider types per direction index (PinSliderTypes in eval.s).
PIN_SLIDER_TYPES = [BISHOP_T, ROOK_T, BISHOP_T, ROOK_T, ROOK_T, BISHOP_T, ROOK_T, BISHOP_T]

CHESS_TYPE_TO_T = {
    chess.PAWN: PAWN_T, chess.KNIGHT: KNIGHT_T, chess.BISHOP: BISHOP_T,
    chess.ROOK: ROOK_T, chess.QUEEN: QUEEN_T, chess.KING: KING_T,
}


def _add8(a: int, b: int) -> int:
    """6502 8-bit add (wraps mod 256). Mirrors clc/adc on the ray square byte."""
    return (a + b) & 0xFF


def square_to_0x88(square: int) -> int:
    return (7 - chess.square_rank(square)) * 16 + chess.square_file(square)


def build_board88(board: chess.Board):
    """Build the 0x88 board array + king squares the engine sees.

    Returns (board88 list[128], whitekingsq, blackkingsq).
    """
    board88 = [EMPTY] * 128
    wk = bk = None
    for square, piece in board.piece_map().items():
        t = CHESS_TYPE_TO_T[piece.piece_type]
        val = t | (WHITE_COLOR if piece.color == chess.WHITE else 0)
        idx = square_to_0x88(square)
        board88[idx] = val
        if piece.piece_type == chess.KING:
            if piece.color == chess.WHITE:
                wk = idx
            else:
                bk = idx
    return board88, wk, bk


# ---------------------------------------------------------------------------
# Legacy material+PST entry point (kept; lazy=1 verification).
# ---------------------------------------------------------------------------
def _pst_index_white(sq: int) -> int:
    return (7 - chess.square_rank(sq)) * 8 + chess.square_file(sq)


def _pst_index_black(sq: int) -> int:
    return chess.square_rank(sq) * 8 + chess.square_file(sq)


def eval_material_pst(board: chess.Board) -> int:
    """Material + PST only, WHITE-POV centipawns. Mirrors the lazy stage."""
    score = 0
    egdiff = 0   # signed EG-minus-MG accumulator, tapered in below
    phase = 0    # game phase: N/B=1, R=2, Q=4 both colors, clamp 24
    pv = {chess.PAWN: PAWN_VALUE, chess.KNIGHT: KNIGHT_VALUE, chess.BISHOP: BISHOP_VALUE,
          chess.ROOK: ROOK_VALUE, chess.QUEEN: QUEEN_VALUE, chess.KING: KING_VALUE}
    for sq, piece in board.piece_map().items():
        val = pv[piece.piece_type]
        phase += PHASE_WEIGHT[CHESS_TYPE_TO_T[piece.piece_type]]
        if piece.color == chess.WHITE:
            idx = _pst_index_white(sq)
            score += val + PST[piece.piece_type][idx]
            egdiff += PST_EG[piece.piece_type][idx] - PST[piece.piece_type][idx]
        else:
            idx = _pst_index_black(sq)
            score -= val + PST[piece.piece_type][idx]
            egdiff -= PST_EG[piece.piece_type][idx] - PST[piece.piece_type][idx]
    if phase > 24:
        phase = 24
    num = egdiff * (24 - phase)
    blend = num // 24 if num >= 0 else -((-num) // 24)   # trunc toward zero (C-style)
    score += blend
    return score


# ---------------------------------------------------------------------------
# Full eval, ported routine-for-routine from src/ai/eval.s.
# The Evaluator holds the 0x88 board + EvalScore accumulator (we keep it as a
# plain Python int; the engine's 16-bit two's-complement EvalScore is recovered
# by masking only at the very end, which is exact because every intermediate add
# the engine does is the same modular arithmetic on a wider range we never
# actually overflow past 16 bits except where it matters -- and where it matters
# (king safety) we reproduce the byte wrap explicitly before adding).
# ---------------------------------------------------------------------------
class _Eval:
    __slots__ = ("b", "wk", "bk", "score", "nonpawn", "pawns", "queens",
                 "wbishops", "bbishops", "endgame", "phase", "egdiff", "wpf", "bpf")

    def __init__(self, board88, wk, bk):
        self.b = board88
        self.wk = wk
        self.bk = bk
        self.score = 0
        self.nonpawn = 0
        self.pawns = 0
        self.queens = 0
        self.wbishops = 0
        self.bbishops = 0
        self.endgame = 0
        self.phase = 0      # game phase: N/B=1, R=2, Q=4, clamp 24
        self.egdiff = 0     # signed EG-minus-MG PST accumulator (tapered in)
        self.wpf = [0] * 8  # white pawns per file
        self.bpf = [0] * 8  # black pawns per file

    # -- board iteration helper (engine walks 0x88 skipping offboard) ----------
    @staticmethod
    def _squares():
        x = 0
        while x < BOARD_SIZE:
            yield x
            x += 1
            if x & 0x08:
                x += 8

    # -- low level pawn probes -------------------------------------------------
    def _check_white_pawn_at(self, idx: int) -> bool:
        if idx & OFFBOARD_MASK:
            return False
        return self.b[idx] == WHITE_PAWN

    def _check_black_pawn_at(self, idx: int) -> bool:
        if idx & OFFBOARD_MASK:
            return False
        return self.b[idx] == BLACK_PAWN

    # -- IsPiecePawnAttacked ---------------------------------------------------
    def _is_pawn_attacked(self, sq, color, ptype) -> bool:
        # Only knight..queen (types 2..5) are checked; else not attacked.
        if ptype < KNIGHT_T or ptype >= KING_T:
            return False
        if color:  # white piece ($f1 != 0) -> black pawns attack from -15,-17
            if self._check_black_pawn_at(_add8(sq, -0x0F)):
                return True
            if self._check_black_pawn_at(_add8(sq, -0x11)):
                return True
            return False
        else:  # black piece -> white pawns attack from +15,+17
            if self._check_white_pawn_at(_add8(sq, 0x0F)):
                return True
            if self._check_white_pawn_at(_add8(sq, 0x11)):
                return True
            return False

    def _is_knight_attacked(self, sq, color) -> bool:
        enemy = BLACK_KNIGHT if color else WHITE_KNIGHT
        for off in KNIGHT_OFFSETS:
            dest = _add8(sq, off)
            if dest & OFFBOARD_MASK:
                continue
            if self.b[dest] == enemy:
                return True
        return False

    def _is_bishop_attacked(self, sq, color) -> bool:
        enemy = BLACK_BISHOP if color else WHITE_BISHOP
        for off in DIAGONAL_OFFSETS:
            ray = sq
            while True:
                ray = _add8(ray, off)
                if ray & OFFBOARD_MASK:
                    break
                piece = self.b[ray]
                if piece == EMPTY:
                    continue
                if piece == enemy:
                    return True
                break
        return False

    def _is_queen_attacked(self, sq, color, ptype) -> bool:
        # Only minor pieces (knight,bishop = types 2,3). Enemy queen must sit on
        # its home square (d1 = $73 for white-to-attack-black-piece, d8 = $03).
        if ptype < KNIGHT_T or ptype >= ROOK_T:
            return False
        if color:  # white piece: enemy black queen must be on d8 ($03)
            if self.b[0x03] != BLACK_QUEEN:
                return False
            enemy = BLACK_QUEEN
        else:  # black piece: enemy white queen on d1 ($73)
            if self.b[0x73] != WHITE_QUEEN:
                return False
            enemy = WHITE_QUEEN
        for off in ALL_DIRECTION_OFFSETS:
            ray = sq
            while True:
                ray = _add8(ray, off)
                if ray & OFFBOARD_MASK:
                    break
                piece = self.b[ray]
                if piece == EMPTY:
                    continue
                if piece == enemy:
                    return True
                break
        return False

    # -- eval accumulators -----------------------------------------------------
    def add(self, v: int):
        self.score += v

    def sub(self, v: int):
        self.score -= v

    # =========================================================================
    # Per-piece full-eval terms (called in the main board pass, lazy=0 only)
    # =========================================================================
    def _pawn_pressure(self, sq, color, ptype):
        if not self._is_pawn_attacked(sq, color, ptype):
            return
        pen = PAWN_ATTACK_PENALTY[ptype]
        if color:
            self.sub(pen)
        else:
            self.add(pen)

    def _queen_pressure(self, sq, color, ptype):
        if not self._is_queen_attacked(sq, color, ptype):
            return
        pen = QUEEN_ATTACK_PENALTY[ptype]
        if color:
            self.sub(pen)
        else:
            self.add(pen)

    def _minor_pressure(self, sq, color, ptype):
        if ptype < ROOK_T or ptype >= KING_T:  # only rook(4), queen(5)
            return
        attacked = self._is_knight_attacked(sq, color)
        if not attacked:
            attacked = self._is_bishop_attacked(sq, color)
        if not attacked:
            return
        pen = MINOR_ATTACK_PENALTY[ptype]
        if pen == 0:
            return
        if color:
            self.sub(pen)
        else:
            self.add(pen)

    def _knight_outpost(self, sq, color, ptype):
        if ptype != KNIGHT_T:
            return
        file = sq & 0x07
        if file < 2 or file >= 6:
            return
        if self._is_pawn_attacked(sq, color, ptype):
            return
        row16 = sq & 0x70
        if color:  # white outposts on rows 2..4 ($20.. <$50), protected from behind (+15/+17)
            if row16 < 0x20 or row16 >= 0x50:
                return
            if self._check_white_pawn_at(_add8(sq, 0x0F)) or self._check_white_pawn_at(_add8(sq, 0x11)):
                self.add(KNIGHT_OUTPOST_BONUS)
        else:  # black outposts on rows 3..5 ($30.. <$60), protected from behind (-15/-17)
            if row16 < 0x30 or row16 >= 0x60:
                return
            if self._check_black_pawn_at(_add8(sq, -0x0F)) or self._check_black_pawn_at(_add8(sq, -0x11)):
                self.sub(KNIGHT_OUTPOST_BONUS)

    def _count_knight_mobility(self, sq, color) -> int:
        count = 0
        for off in KNIGHT_OFFSETS:
            dest = _add8(sq, off)
            if dest & OFFBOARD_MASK:
                continue
            piece = self.b[dest]
            if piece == EMPTY:
                count += 1
            elif (piece & WHITE_COLOR) != color:
                count += 1
        return count

    def _count_sliding_mobility(self, sq, color, offsets) -> int:
        count = 0
        for off in offsets:
            ray = sq
            while True:
                ray = _add8(ray, off)
                if ray & OFFBOARD_MASK:
                    break
                piece = self.b[ray]
                if piece == EMPTY:
                    count += 1
                    continue
                if (piece & WHITE_COLOR) != color:
                    count += 1
                break
        return count

    def _mobility(self, sq, color, ptype):
        if ptype == KNIGHT_T:
            raw = self._count_knight_mobility(sq, color)
        elif ptype == BISHOP_T:
            raw = self._count_sliding_mobility(sq, color, DIAGONAL_OFFSETS)
        elif ptype == ROOK_T:
            raw = self._count_sliding_mobility(sq, color, ORTHOGONAL_OFFSETS)
        elif ptype == QUEEN_T:
            raw = self._count_sliding_mobility(sq, color, ALL_DIRECTION_OFFSETS)
        else:
            return
        # ApplyMobilityScore: lsr (halve, integer), then *10 (only if nonzero).
        half = raw >> 1
        if half == 0:
            return
        contrib = half * 10
        if color:
            self.add(contrib)
        else:
            self.sub(contrib)

    def _seventh_rank(self, sq, color, ptype):
        if ptype != ROOK_T and ptype != QUEEN_T:
            return
        row16 = sq & 0x70
        if color:
            if row16 == 0x10:  # white heavy on rank 7
                self.add(HEAVY_SEVENTH_RANK_BONUS)
        else:
            if row16 == 0x60:  # black heavy on rank 2
                self.sub(HEAVY_SEVENTH_RANK_BONUS)

    def _advanced_pawn(self, sq, color, ptype):
        if ptype != PAWN_T:
            return
        row16 = sq & 0x70
        if color:  # white: row3 ($30) advanced; rows1-2 ($10,$20) deep; row0 / >=$30 none
            if row16 == 0x30:
                self.add(ADVANCED_PAWN_BONUS)
            elif row16 > 0x30:
                return
            elif row16 == 0x00:
                return
            else:
                self.add(DEEP_ADVANCED_PAWN_BONUS)
        else:  # black: row4 ($40) advanced; rows5-6 ($50,$60) deep; row7 / <$40 none
            if row16 == 0x40:
                self.sub(ADVANCED_PAWN_BONUS)
            elif row16 < 0x50:
                return
            elif row16 == 0x70:
                return
            else:
                self.sub(DEEP_ADVANCED_PAWN_BONUS)

    # =========================================================================
    # Main pass: material + PST + phase counters (+ per-piece full terms)
    # =========================================================================
    def run(self) -> int:
        b = self.b
        for x in self._squares():
            piece = b[x]
            if piece == EMPTY:
                continue
            color = piece & WHITE_COLOR  # 0x80 white, 0 black
            ptype = piece & 0x07

            # phase counters + per-pawn advanced bonus
            if ptype == PAWN_T:
                self.pawns += 1
                self._advanced_pawn(x, color, ptype)
            elif ptype != KING_T:
                self.nonpawn += 1
                if ptype == BISHOP_T:
                    if color:
                        self.wbishops += 1
                    else:
                        self.bbishops += 1
                if ptype == QUEEN_T:
                    self.queens += 1
                # game-phase accumulation (both colors): N/B=1, R=2, Q=4
                if ptype == ROOK_T:
                    self.phase += 2
                elif ptype == QUEEN_T:
                    self.phase += 4
                else:
                    self.phase += 1  # knight or bishop

            # per-piece full-eval terms (lazy=0). Order matches eval.s.
            self._pawn_pressure(x, color, ptype)
            self._queen_pressure(x, color, ptype)
            self._minor_pressure(x, color, ptype)
            self._knight_outpost(x, color, ptype)
            self._mobility(x, color, ptype)
            self._seventh_rank(x, color, ptype)

            # material + PST (MG added now; EG-minus-MG accumulated for the
            # phase-tapered blend applied once after the loop).
            val = PIECE_VALUE_TBL[ptype]
            pst = PST_BY_TYPE[ptype]
            pst_eg = PST_EG_BY_TYPE[ptype]
            if color:
                self.add(val)
                idx = ((x & 0x70) >> 1) | (x & 0x07)  # Sq88To64
                self.add(pst[idx])
                self.egdiff += pst_eg[idx] - pst[idx]
            else:
                self.sub(val)
                idx = (((x & 0x70) >> 1) | (x & 0x07)) ^ 0x38  # Sq88To64Mirror
                self.sub(pst[idx])
                self.egdiff -= pst_eg[idx] - pst[idx]

        # tapered PST: blend accumulated EG-minus-MG toward the endgame by phase.
        # Use C-style truncate-toward-zero division (Python // floors).
        p = self.phase
        if p > 24:
            p = 24
        num = self.egdiff * (24 - p)
        self.score += num // 24 if num >= 0 else -((-num) // 24)

        # endgame flag
        if self.nonpawn < ENDGAME_NONPAWN_LIMIT + 1:
            self.endgame = 1
        elif self.nonpawn == ENDGAME_NONPAWN_LIMIT + 1 and self.queens == 0:
            # NOTE: assembly compares nonpawn to LIMIT+1; bcc -> <, bne(after)->!=
            # The exact branch logic: if nonpawn < LIMIT+1 -> endgame; elif
            # nonpawn != LIMIT+1 -> not endgame; else (==) require queens==0.
            self.endgame = 1
        # (the elif above only fires when nonpawn == LIMIT+1; matches asm)

        # --- full tail (lazy=0) ---
        self._bishop_pair()
        if self.pawns != 0:
            self._pawn_structure()
        if self.endgame:
            self._endgame()
        else:
            self._king_pins()
            self._king_safety()

        # EvalScore is a 16-bit signed value; reproduce two's-complement.
        s = self.score & 0xFFFF
        if s >= 0x8000:
            s -= 0x10000
        return s

    # =========================================================================
    # Tail terms
    # =========================================================================
    def _bishop_pair(self):
        if self.wbishops >= 2:
            self.add(BISHOP_PAIR_BONUS)
        if self.bbishops >= 2:
            self.sub(BISHOP_PAIR_BONUS)

    # -- pawn structure --------------------------------------------------------
    def _pawn_structure(self):
        b = self.b
        wpf = self.wpf
        bpf = self.bpf
        for i in range(8):
            wpf[i] = 0
            bpf[i] = 0
        for x in self._squares():
            if (b[x] & 0x07) != PAWN_T:
                continue
            file = x & 0x07
            if b[x] & WHITE_COLOR:
                wpf[file] += 1
            else:
                bpf[file] += 1

        # doubled (file index walks 7..0, order irrelevant for the sum)
        for f in range(8):
            if wpf[f] >= 2:
                self.sub(DOUBLED_PAWN_PENALTY)
            if bpf[f] >= 2:
                self.add(DOUBLED_PAWN_PENALTY)

        # isolated
        for f in range(8):
            if wpf[f] != 0:
                left = wpf[f - 1] if f > 0 else 0
                right = wpf[f + 1] if f < 7 else 0
                if left == 0 and right == 0:
                    self.sub(ISOLATED_PAWN_PENALTY)
            if bpf[f] != 0:
                left = bpf[f - 1] if f > 0 else 0
                right = bpf[f + 1] if f < 7 else 0
                if left == 0 and right == 0:
                    self.add(ISOLATED_PAWN_PENALTY)

        # passed pawns + connected/protected/blockaded/rook-behind
        for x in self._squares():
            if (b[x] & 0x07) != PAWN_T:
                continue
            file = x & 0x07
            row = x >> 4
            if b[x] & WHITE_COLOR:
                if not self._white_passed(file, row):
                    continue
                self.add(PASSED_PAWN_BONUS[row])
                if self._white_connected(x, file):
                    self.add(CONNECTED_PASSER_BONUS)
                if self._white_protected(x):
                    self.add(PROTECTED_PASSER_BONUS)
                if self._white_blockaded(x):
                    self.sub(BLOCKADED_PASSER_PENALTY)
                if self.endgame and self._white_rook_behind(file, row):
                    self.add(ROOK_BEHIND_PASSER_BONUS)
            else:
                if not self._black_passed(file, row):
                    continue
                self.sub(PASSED_PAWN_BONUS[7 - row])
                if self._black_connected(x, file):
                    self.sub(CONNECTED_PASSER_BONUS)
                if self._black_protected(x):
                    self.sub(PROTECTED_PASSER_BONUS)
                if self._black_blockaded(x):
                    self.add(BLOCKADED_PASSER_PENALTY)
                if self.endgame and self._black_rook_behind(file, row):
                    self.sub(ROOK_BEHIND_PASSER_BONUS)

        if not self.endgame:
            self._rook_file_activity()

    def _white_passed(self, file, row) -> bool:
        b = self.b
        r = row
        while True:
            r -= 1
            if r < 0:
                return True
            y = (r << 4) | file
            # same file
            if (b[y] & 0x07) == PAWN_T and not (b[y] & WHITE_COLOR):
                return False
            # left
            if file != 0:
                yl = y - 1
                if (b[yl] & 0x07) == PAWN_T and not (b[yl] & WHITE_COLOR):
                    return False
            # right
            if file != 7:
                yr = y + 1
                if (b[yr] & 0x07) == PAWN_T and not (b[yr] & WHITE_COLOR):
                    return False

    def _black_passed(self, file, row) -> bool:
        b = self.b
        r = row
        while True:
            r += 1
            if r == 8:
                return True
            y = (r << 4) | file
            if (b[y] & 0x07) == PAWN_T and (b[y] & WHITE_COLOR):
                return False
            if file != 0:
                yl = y - 1
                if (b[yl] & 0x07) == PAWN_T and (b[yl] & WHITE_COLOR):
                    return False
            if file != 7:
                yr = y + 1
                if (b[yr] & 0x07) == PAWN_T and (b[yr] & WHITE_COLOR):
                    return False

    def _white_connected(self, sq, file) -> bool:
        b = self.b
        if file != 0 and b[sq - 1] == WHITE_PAWN:
            return True
        if file != 7 and b[sq + 1] == WHITE_PAWN:
            return True
        return False

    def _black_connected(self, sq, file) -> bool:
        b = self.b
        if file != 0 and b[sq - 1] == BLACK_PAWN:
            return True
        if file != 7 and b[sq + 1] == BLACK_PAWN:
            return True
        return False

    def _white_protected(self, sq) -> bool:
        b = self.b
        a = _add8(sq, 0x0F)
        if not (a & OFFBOARD_MASK) and b[a] == WHITE_PAWN:
            return True
        a = _add8(sq, 0x11)
        if not (a & OFFBOARD_MASK) and b[a] == WHITE_PAWN:
            return True
        return False

    def _black_protected(self, sq) -> bool:
        b = self.b
        a = _add8(sq, -0x0F)
        if not (a & OFFBOARD_MASK) and b[a] == BLACK_PAWN:
            return True
        a = _add8(sq, -0x11)
        if not (a & OFFBOARD_MASK) and b[a] == BLACK_PAWN:
            return True
        return False

    def _white_blockaded(self, sq) -> bool:
        b = self.b
        a = _add8(sq, -0x10)
        if a & OFFBOARD_MASK:
            return False
        return b[a] != EMPTY

    def _black_blockaded(self, sq) -> bool:
        b = self.b
        a = _add8(sq, 0x10)
        if a & OFFBOARD_MASK:
            return False
        return b[a] != EMPTY

    def _white_rook_behind(self, file, row) -> bool:
        b = self.b
        r = row
        while True:
            r += 1
            if r == 8:
                return False
            y = (r << 4) | file
            if b[y] == WHITE_ROOK:
                return True

    def _black_rook_behind(self, file, row) -> bool:
        b = self.b
        r = row
        while True:
            r -= 1
            if r < 0:
                return False
            y = (r << 4) | file
            if b[y] == BLACK_ROOK:
                return True

    def _rook_file_activity(self):
        b = self.b
        for x in self._squares():
            p = b[x]
            if p == WHITE_ROOK:
                f = x & 0x07
                if self.wpf[f] != 0:
                    continue
                if self.bpf[f] != 0:
                    self.add(ROOK_SEMI_OPEN_FILE_BONUS)
                else:
                    self.add(ROOK_OPEN_FILE_BONUS)
            elif p == BLACK_ROOK:
                f = x & 0x07
                if self.bpf[f] != 0:
                    continue
                if self.wpf[f] != 0:
                    self.sub(ROOK_SEMI_OPEN_FILE_BONUS)
                else:
                    self.sub(ROOK_OPEN_FILE_BONUS)

    # -- king pins -------------------------------------------------------------
    def _king_pins(self):
        self._pins_from_king(self.wk, WHITE_COLOR)
        self._pins_from_king(self.bk, 0)

    def _pins_from_king(self, king_sq, king_color):
        # The ray loop re-derives the king square as the origin each direction
        # (eval.s EvaluatePinsFromKing), so every direction scans from the king
        # and multiple pins are all found. (Earlier the engine read $f0, which
        # ApplyPinnedAttackPressure clobbered with the pinned-piece square and
        # never restored, dropping pins on later directions -- fixed.)
        b = self.b
        for d, delta in enumerate(ALL_DIRECTION_OFFSETS):
            ray = king_sq
            candidate_type = 0
            candidate_sq = 0
            while True:
                ray = _add8(ray, delta)
                if ray & OFFBOARD_MASK:
                    break
                piece = b[ray]
                if piece == EMPTY:
                    continue
                if candidate_type == 0:
                    # first occupied must be friendly non-king
                    if (piece & WHITE_COLOR) != king_color:
                        break
                    candidate_sq = ray
                    t = piece & 0x07
                    if t == KING_T:
                        break
                    candidate_type = t
                    continue
                else:
                    # next occupied must be enemy aligned slider
                    if (piece & WHITE_COLOR) == king_color:
                        break
                    t = piece & 0x07
                    if t != QUEEN_T:
                        if PIN_SLIDER_TYPES[d] != t:
                            break
                    # apply
                    pen = PINNED_PIECE_PENALTY[candidate_type]
                    if pen == 0:
                        break
                    if king_color:  # pinned side white -> subtract (bad for white)
                        self.sub(pen)
                    else:  # pinned side black -> add (good for white)
                        self.add(pen)
                    # ApplyPinnedAttackPressure runs for an applied pin (it
                    # clobbers $f0, but the loop re-derives the king origin so the
                    # next direction is unaffected).
                    self._pinned_attack_pressure(king_color, candidate_type, candidate_sq)
                    break

    def _pinned_attack_pressure(self, pinned_color, ptype, sq):
        if self._is_pawn_attacked(sq, pinned_color, ptype) or self._is_knight_attacked(sq, pinned_color):
            if pinned_color:  # white pinned piece also attacked -> subtract
                self.sub(PINNED_ATTACKED_PENALTY)
            else:
                self.add(PINNED_ATTACKED_PENALTY)

    # -- endgame ---------------------------------------------------------------
    def _endgame(self):
        self.add(self._endgame_king_activity(self.wk))
        self.sub(self._endgame_king_activity(self.bk))
        if self.pawns != 0 and self.nonpawn != 0:
            self._endgame_rook_activity()

    def _endgame_king_activity(self, king_sq) -> int:
        acc = 0
        file = king_sq & 0x07
        if 2 <= file < 6:
            acc += ENDGAME_KING_ACTIVITY_BONUS
        row = king_sq >> 4
        if 2 <= row < 6:
            acc += ENDGAME_KING_ACTIVITY_BONUS
        return acc

    def _endgame_rook_activity(self):
        b = self.b
        for x in self._squares():
            p = b[x]
            if p == WHITE_ROOK:
                f = x & 0x07
                if self.wpf[f] != 0:
                    continue
                self.add(ENDGAME_ROOK_OPEN_FILE_BONUS)
                # king cutoff: |blackking_file - rook_file| < 2
                dist = (self.bk & 0x07) - f
                if dist < 0:
                    dist = -dist
                if dist < 2:
                    self.add(ENDGAME_ROOK_KING_CUTOFF_BONUS)
            elif p == BLACK_ROOK:
                f = x & 0x07
                if self.bpf[f] != 0:
                    continue
                self.sub(ENDGAME_ROOK_OPEN_FILE_BONUS)
                dist = (self.wk & 0x07) - f
                if dist < 0:
                    dist = -dist
                if dist < 2:
                    self.sub(ENDGAME_ROOK_KING_CUTOFF_BONUS)

    # -- king safety -----------------------------------------------------------
    def _king_safety(self):
        wb = self._single_king_safety(self.wk)
        self.score += _byte_x10(wb)
        bb = self._single_king_safety(self.bk)
        self.score -= _byte_x10(bb)

    def _single_king_safety(self, king_sq) -> int:
        """Returns the engine's SIGNED-BYTE safety score (wraps mod 256, two's
        complement), exactly as EvaluateSingleKingSafety does (an 8-bit accumulator)."""
        b = self.b
        file = king_sq & 0x07
        row = king_sq >> 4
        s = 0  # signed-byte accumulator
        is_white = (king_sq == self.wk)

        if is_white:
            castled = (row == 7 and (file == 6 or file == 2))
            if castled:
                s = _add8s(s, CASTLED_BONUS)
                if file == 6:  # kingside shield f2,g2,h2 = $65,$66,$67
                    for idx in (0x65, 0x66, 0x67):
                        if (b[idx] & 0x07) == PAWN_T and (b[idx] & WHITE_COLOR):
                            s = _add8s(s, PAWN_SHIELD_BONUS)
                else:  # queenside shield a2,b2,c2 = $60,$61,$62
                    for idx in (0x60, 0x61, 0x62):
                        if (b[idx] & 0x07) == PAWN_T and (b[idx] & WHITE_COLOR):
                            s = _add8s(s, PAWN_SHIELD_BONUS)
            else:
                if file == 3 or file == 4:
                    s = _sub8s(s, KING_CENTER_PENALTY)
            # king march: ranks past rank 2. Row < 6 triggers (rows 0..5).
            if row < 6:
                advanced = 6 - row
                pen = ((advanced << 3) + KING_MARCH_BASE) & 0xFF
                s = _sub8s(s, pen)
            s = self._white_file_exposure(s, file)
            s = self._king_zone_pressure(s, king_sq, attacker_color=0)  # BLACKS_TURN=0 -> black attackers
        else:
            castled = (row == 0 and (file == 6 or file == 2))
            if castled:
                s = _add8s(s, CASTLED_BONUS)
                if file == 6:  # kingside f7,g7,h7 = $15,$16,$17
                    for idx in (0x15, 0x16, 0x17):
                        if (b[idx] & 0x07) == PAWN_T and not (b[idx] & WHITE_COLOR):
                            s = _add8s(s, PAWN_SHIELD_BONUS)
                else:  # queenside a7,b7,c7 = $10,$11,$12
                    for idx in (0x10, 0x11, 0x12):
                        if (b[idx] & 0x07) == PAWN_T and not (b[idx] & WHITE_COLOR):
                            s = _add8s(s, PAWN_SHIELD_BONUS)
            else:
                if file == 3 or file == 4:
                    s = _sub8s(s, KING_CENTER_PENALTY)
            # black march: row >= 2 triggers; advanced = row - 1
            if row >= 2:
                advanced = row - 1
                pen = ((advanced << 3) + KING_MARCH_BASE) & 0xFF
                s = _sub8s(s, pen)
            s = self._black_file_exposure(s, file)
            s = self._king_zone_pressure(s, king_sq, attacker_color=WHITE_COLOR)  # white attackers
        return s

    def _white_file_exposure(self, s, file):
        if self.pawns == 0:
            return s
        if file != 0:
            s = self._penalize_white_file(s, file - 1)
        s = self._penalize_white_file(s, file)
        if file != 7:
            s = self._penalize_white_file(s, file + 1)
        return s

    def _black_file_exposure(self, s, file):
        if self.pawns == 0:
            return s
        if file != 0:
            s = self._penalize_black_file(s, file - 1)
        s = self._penalize_black_file(s, file)
        if file != 7:
            s = self._penalize_black_file(s, file + 1)
        return s

    def _penalize_white_file(self, s, f):
        if self.wpf[f] != 0:
            return s
        if self.bpf[f] != 0:
            return _sub8s(s, SEMI_OPEN_FILE_PENALTY)
        return _sub8s(s, OPEN_FILE_PENALTY)

    def _penalize_black_file(self, s, f):
        if self.bpf[f] != 0:
            return s
        if self.wpf[f] != 0:
            return _sub8s(s, SEMI_OPEN_FILE_PENALTY)
        return _sub8s(s, OPEN_FILE_PENALTY)

    def _king_zone_pressure(self, s, king_sq, attacker_color):
        b = self.b
        # slider rays (8 dirs); index used to gate rook-only / bishop-only dirs
        for d, delta in enumerate(ALL_DIRECTION_OFFSETS):
            ray = king_sq
            while True:
                ray = _add8(ray, delta)
                if ray & OFFBOARD_MASK:
                    break
                piece = b[ray]
                if piece == EMPTY:
                    continue
                if (piece & WHITE_COLOR) != attacker_color:
                    break
                t = piece & 0x07
                if t == QUEEN_T:
                    s = _sub8s(s, KING_ZONE_ATTACK_PENALTY)
                    break
                # orthogonal directions: indices 1,3,4,6
                if d in (1, 3, 4, 6):
                    if t == ROOK_T:
                        s = _sub8s(s, KING_ZONE_ATTACK_PENALTY)
                    break
                else:
                    if t == BISHOP_T:
                        s = _sub8s(s, KING_ZONE_ATTACK_PENALTY)
                    break
        # knight attackers
        for off in KNIGHT_OFFSETS:
            dest = _add8(king_sq, off)
            if dest & OFFBOARD_MASK:
                continue
            piece = b[dest]
            if piece == EMPTY:
                continue
            if (piece & WHITE_COLOR) != attacker_color:
                continue
            if (piece & 0x07) == KNIGHT_T:
                s = _sub8s(s, KING_ZONE_ATTACK_PENALTY)
        return s


def _add8s(s: int, v: int) -> int:
    """8-bit signed add: wrap into two's-complement byte (mirrors the 6502 accumulator)."""
    r = (s + v) & 0xFF
    return r - 256 if r >= 128 else r


def _sub8s(s: int, v: int) -> int:
    r = (s - v) & 0xFF
    return r - 256 if r >= 128 else r


def _byte_x10(signed_byte: int) -> int:
    """KingSafetyByteX10: signed byte * 10 (exact, fits [-1280,1270])."""
    return signed_byte * 10


def eval_full(board: chess.Board) -> int:
    """Engine's COMPLETE static eval (lazy=0 path), WHITE-POV centipawns."""
    board88, wk, bk = build_board88(board)
    return _Eval(board88, wk, bk).run()


# ---------------------------------------------------------------------------
# Verification harness
# ---------------------------------------------------------------------------
def _verify(n: int = 800) -> int:
    import json
    from sim6502_headless_runner import Sim6502HeadlessRunner, repo_root_from_script
    from run_stockfish_strength import fen_to_c64

    root = repo_root_from_script()
    data = json.load(open(root / "build" / "texel_data.json"))
    positions = data["positions"][:n]

    lazy_mism = 0
    full_mism = 0
    full_errors = []
    worst_lazy = []
    with Sim6502HeadlessRunner(repo_root=root) as r:
        for pos in positions:
            fen = pos["fen"]
            c64 = fen_to_c64(fen)
            b = chess.Board(fen)

            eng_lazy = int(r.evaluate(c64, lazy=1)["eval"])
            mine_lazy = eval_material_pst(b)
            if eng_lazy != mine_lazy:
                lazy_mism += 1
                if len(worst_lazy) < 8:
                    worst_lazy.append((eng_lazy, mine_lazy, fen))

            eng_full = int(r.evaluate(c64, lazy=0)["eval"])
            mine_full = eval_full(b)
            if eng_full != mine_full:
                full_mism += 1
                full_errors.append((eng_full, mine_full, fen))

    nN = len(positions)
    print(f"[lazy=1] material+PST: {nN - lazy_mism}/{nN} exact match")
    for eng, mine, fen in worst_lazy:
        print(f"  LAZY MISMATCH eng={eng} mine={mine} diff={mine - eng} | {fen}")

    print(f"[lazy=0] full eval:   {nN - full_mism}/{nN} exact match")
    if full_errors:
        diffs = [abs(e - m) for e, m, _ in full_errors]
        diffs.sort()
        print(f"  full mismatches: {len(full_errors)}  err cp: "
              f"min={diffs[0]} median={diffs[len(diffs)//2]} max={diffs[-1]}")
        for eng, mine, fen in full_errors[:20]:
            print(f"  FULL MISMATCH eng={eng} mine={mine} diff={mine - eng} | {fen}")

    return 0 if (lazy_mism == 0 and full_mism == 0) else 1


if __name__ == "__main__":
    raise SystemExit(_verify())
