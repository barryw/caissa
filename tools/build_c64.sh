#!/usr/bin/env bash
# build_c64.sh -- build the playable C64 chess game (native C engine + text UI)
# into a real .prg for the c64, using llvm-mos and the hand-asm overrides.
#
#   ./tools/build_c64.sh          -> chess.prg
#   x64sc chess.prg               -> play in VICE (type moves like e2e4)
#
# The same native/ engine the speed campaign optimized; nothing here is the old
# ca65 src/ engine. The UI (native/c64chess.c) is platform-portable C -- only its
# stdio (KERNAL CHROUT/CHRIN) is c64-specific; the same source targets Nova once a
# Nova llvm-mos platform exists.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
N="$HERE/native"
LM="${LLVM_MOS:-$HOME/Git/llvm-mos/build}/bin"
OUT="${1:-$HERE/chess.prg}"

# Hand-asm overrides that fit the real chip (is_square_attacked/make/unmake).
# order_moves + eval_full are intentionally NOT asm'd (the C inlines/optimizes
# them better -- see the speed-campaign notes).
ASM="-DCREF_ASM_IS_SQUARE_ATTACKED $N/is_square_attacked_6502.s \
     -DCREF_ASM_UNMAKE_MOVE        $N/unmake_move_6502.s \
     -DCREF_ASM_MAKE_MOVE          $N/make_move_6502.s \
     -DCREF_ASM_GEN_PSEUDO         $N/gen_pseudo_6502.s"

# shellcheck disable=SC2086
"$LM/mos-c64-clang" -Os -I "$N" $ASM \
    "$N/board.c" "$N/movegen.c" "$N/eval.c" "$N/search.c" "$N/c64chess.c" \
    -o "$OUT" -Wl,-Map="${OUT%.prg}.map"

size=$(wc -c < "$OUT")
free=$(perl -ne 'if(/__heap_start = ALIGN/){/^\s+([0-9a-f]+)/;$h=hex($1)} END{print 0xD000-$h}' "${OUT%.prg}.map")
echo "built $OUT  ($size bytes; $free bytes RAM free)"
