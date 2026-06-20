#!/usr/bin/env bash
# build_c64_ultimate.sh -- the Ultimate 64 / banked-TT build of the chess game.
#
#   ./tools/build_c64_ultimate.sh        -> chess_ultimate.prg
#
# Same engine + UI as build_c64.sh, but with CREF_PROFILE_ULTIMATE: eager move
# ordering (no g_score_pool) + TT_BITS 7 reclaim the RAM the stock build overflowed,
# and MAX_PLY is 8 (enables d7 ~2013). Boots with the STOCK mos-c64 link script --
# no banking, no linker surgery. The eager-ordering speed cost is irrelevant at the
# Ultimate's 64 MHz; it is bit-exact with the lazy default (gate-verified).
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
N="$HERE/src"
UI="$HERE/apps/c64"
LM="${LLVM_MOS:-$HOME/Git/llvm-mos/build}/bin"
OUT="${1:-$HERE/chess_ultimate.prg}"

ASM="-DCREF_ASM_IS_SQUARE_ATTACKED $N/is_square_attacked_6502.s \
     -DCREF_ASM_UNMAKE_MOVE        $N/unmake_move_6502.s \
     -DCREF_ASM_MAKE_MOVE          $N/make_move_6502.s \
     -DCREF_ASM_GEN_PSEUDO         $N/gen_pseudo_6502.s \
     -DCREF_ASM_GEN_LEGAL          $N/gen_legal_6502.s"

# shellcheck disable=SC2086
"$LM/mos-c64-clang" -Os -I "$N" \
    -DCREF_PROFILE_ULTIMATE \
    $ASM \
    "$N/board.c" "$N/movegen.c" "$N/eval.c" "$N/search.c" "$UI/c64chess.c" \
    -o "$OUT" -Wl,-Map="${OUT%.prg}.map"

size=$(wc -c < "$OUT")
free=$(perl -ne 'if(/__heap_start = ALIGN/){/^\s+([0-9a-f]+)/;$h=hex($1)} END{print 0xD000-$h}' "${OUT%.prg}.map")
echo "built $OUT  ($size bytes; $free bytes low-RAM free)"
