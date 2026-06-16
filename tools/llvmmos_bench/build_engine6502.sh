#!/usr/bin/env bash
# build_engine6502.sh -- build the validated NATIVE-C-on-6502 "bestmove" program
# and validate it move-for-move against the host reference engine.
#
# Produces:
#   /tmp/engine6502.sim   -- the mos-sim 6502 image (native engine + ABI driver)
#   /tmp/engine6502.map   -- linker map (ABI symbol addresses; read by validate)
#   native/cref           -- canonical host engine (TT16, history on)
#   /tmp/cref_mos          -- host engine built in the EXACT 6502 config (-D__mos__:
#                            TT8, MAX_PLY=7, history off) = the matched-config oracle
#
# Then runs validate over a FEN corpus at the requested depth and reports N/N
# identical to the matched-config oracle (the rigorous port-correctness gate).
#
# Prereqs: the one-time llvm-mos toolchain setup in NOTES.md (compiler at
# ~/Git/llvm-mos/build, mos-sim-clang driver, compiler-rt builtins, llvm-mos-sdk).
#
# Usage: ./build_engine6502.sh [DEPTH=4] [FENLIST]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
NATIVE="$HERE/../../native"
LLVM_MOS="${LLVM_MOS:-$HOME/Git/llvm-mos/build}"
SIMCC="$LLVM_MOS/bin/mos-sim-clang"
DEPTH="${1:-4}"
FENLIST="${2:-/tmp/fenlist.txt}"

CORE="$NATIVE/board.c $NATIVE/movegen.c $NATIVE/eval.c $NATIVE/search.c"

echo ">> [1/5] host gates (perft + eval bit-exact) must stay green"
( cd "$NATIVE" && make -s verify >/dev/null && echo "   host gates: PASS" )

echo ">> [2/5] build canonical host engine (native/cref) + matched-config oracle (/tmp/cref_mos)"
( cd "$NATIVE" && make -s cref )
cc -O3 -w -D__mos__ -I"$NATIVE" $CORE "$NATIVE/cref.c" -o /tmp/cref_mos -lm
echo "   built native/cref and /tmp/cref_mos"

echo ">> [3/5] compile + link the 6502 image (mos-sim, full native engine + ABI driver)"
# HAND-ASM OVERRIDE: is_square_attacked (~15% of 6502 cycles) is replaced by a
# hand-written 6502 asm version. -DCREF_ASM_IS_SQUARE_ATTACKED #ifdef's out the
# C body in movegen.c (only matters for movegen.c; harmless for the others), and
# native/is_square_attacked_6502.s supplies the override symbol. The asm is
# BIT-IDENTICAL to the C (proven by the gate: PERFT EXACT + image == cref_mos).
# This affects ONLY the mos-sim image; the host cref/cref_mos builds keep the C.
ASM_OVERRIDE="$NATIVE/is_square_attacked_6502.s $NATIVE/unmake_move_6502.s"
# shellcheck disable=SC2086
"$SIMCC" -Os -DCREF_ASM_IS_SQUARE_ATTACKED -DCREF_ASM_UNMAKE_MOVE -I"$NATIVE" engine6502.c $CORE $ASM_OVERRIDE \
    -o /tmp/engine6502.sim -Wl,-Map=/tmp/engine6502.map
ls -l /tmp/engine6502.sim | awk '{print "   image:", $5, "bytes ->", $NF}'

echo ">> [4/5] build host harness (cpu6502 cycle-exact runner + validator)"
cc -O2 -o /tmp/validate validate.c ../fast6502_bridge/cpu6502.c
echo "   built /tmp/validate"

echo ">> [5/5] VALIDATE: 6502 best move == matched-config oracle, for every FEN"
if [ ! -f "$FENLIST" ]; then
    echo "   (no FENLIST at $FENLIST; generating a 30-FEN corpus from the strength corpus)"
    python3 - "$FENLIST" <<'PY'
import json, sys
out = sys.argv[1]
fens = [p["fen"] for p in json.load(open("../stockfish_strength_corpus.json"))["positions"]]
try:
    lines = open("../../build/texel_big.tsv").read().splitlines()
    for i in range(0, len(lines), 1500):
        fens.append(lines[i].split("\t")[0])
except FileNotFoundError:
    pass
seen, uniq = set(), []
for f in fens:
    if f not in seen:
        seen.add(f); uniq.append(f)
open(out, "w").write("\n".join(uniq[:30]) + "\n")
PY
fi
/tmp/validate /tmp/engine6502.sim /tmp/engine6502.map "$FENLIST" "$DEPTH" /tmp/cref_mos
