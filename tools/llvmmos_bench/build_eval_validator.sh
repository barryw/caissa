#!/usr/bin/env bash
# build_eval_validator.sh -- build the 6502 eval-over-corpus validator harness.
#
# Phase 1 of hand-asm'ing eval_full: this builds the bit-exact safety net that
# proves the 6502-compiled C eval_full is identical to the python oracle. Later,
# the same harness validates the hand-asm eval via the EXTRA arg (see below).
#
# Produces:
#   /tmp/eval6502.sim    -- the mos-sim 6502 image (native eval + ABI driver)
#   /tmp/eval6502.map    -- linker map (ABI symbol addresses; read by eval_validate)
#   /tmp/eval_validate   -- host runner (cpu6502 cycle-exact core + stdin/stdout)
#
# Then run:  python3 test/eval_corpus_check.py
#   -> "[6502 eval] 22157/22157 bit-exact vs texel_eval"
#
# Prereqs: the one-time llvm-mos toolchain setup in NOTES.md (compiler at
# ~/Git/llvm-mos/build, mos-sim-clang driver, compiler-rt builtins, llvm-mos-sdk).
#
# Usage: ./build_eval_validator.sh ["EXTRA compile flags + asm files"]
#   default EXTRA empty -> pure C eval.
#   later, to test the hand-asm eval:
#     ./build_eval_validator.sh "-DCREF_ASM_EVAL_FULL ../../src/eval_full_6502.s"
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
NATIVE="$HERE/../../src"
LLVM_MOS="${LLVM_MOS:-$HOME/Git/llvm-mos/build}"
SIMCC="$LLVM_MOS/bin/mos-sim-clang"
EXTRA="${1:-}"

# eval6502 never calls search -- only board/movegen/eval are needed. (board.c
# references gen_legal via move_from_uci, so movegen.c is linked to satisfy it;
# the eval path itself never enters movegen.)
CORE="$NATIVE/board.c $NATIVE/movegen.c $NATIVE/eval.c"

echo ">> [1/2] compile + link the 6502 eval image (mos-sim, native eval + ABI driver)"
# shellcheck disable=SC2086
"$SIMCC" -Os -I"$NATIVE" eval6502.c $CORE $EXTRA \
    -o /tmp/eval6502.sim -Wl,-Map=/tmp/eval6502.map
ls -l /tmp/eval6502.sim | awk '{print "   image:", $5, "bytes ->", $NF}'
echo "   map:   /tmp/eval6502.map"

echo ">> [2/2] build host runner (cpu6502 cycle-exact core + eval_validate)"
cc -O2 -o /tmp/eval_validate eval_validate.c ../fast6502_bridge/cpu6502.c
echo "   built /tmp/eval_validate"

echo
echo "DONE. Now run:  python3 test/eval_corpus_check.py"
echo "  (or a quick subset:  python3 test/eval_corpus_check.py 500)"
echo "Harness: /tmp/eval_validate /tmp/eval6502.sim /tmp/eval6502.map < fenlist"
