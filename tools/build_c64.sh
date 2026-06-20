#!/usr/bin/env bash
# build_c64.sh -- build the playable C64 chess game (native C engine + text UI)
# into a real .prg for the c64, using llvm-mos and the hand-asm overrides.
#
#   ./tools/build_c64.sh          -> chess.prg
#   x64sc chess.prg               -> play in VICE (type moves like e2e4)
#
# The src/ engine the speed campaign optimized. The UI (apps/c64/c64chess.c) is
# platform-portable C -- only its stdio (KERNAL CHROUT/CHRIN) is c64-specific; the
# same source targets Nova once a Nova llvm-mos platform exists.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
N="$HERE/src"
UI="$HERE/apps/c64"
LM="${LLVM_MOS:-$HOME/Git/llvm-mos/build}/bin"
OUT="${1:-$HERE/chess.prg}"

# Hand-asm overrides that fit the real chip (is_square_attacked/make/unmake).
# order_moves + eval_full are intentionally NOT asm'd (the C inlines/optimizes
# them better -- see the speed-campaign notes).
ASM="-DCREF_ASM_IS_SQUARE_ATTACKED $N/is_square_attacked_6502.s \
     -DCREF_ASM_UNMAKE_MOVE        $N/unmake_move_6502.s \
     -DCREF_ASM_MAKE_MOVE          $N/make_move_6502.s \
     -DCREF_ASM_GEN_PSEUDO         $N/gen_pseudo_6502.s \
     -DCREF_ASM_GEN_LEGAL          $N/gen_legal_6502.s"

# CREF_LAZY_SELECT=0: drop the lazy-move-selection scratch (g_score_pool, ~1.5 KB)
# and use eager in-place ordering instead. It is BIT-EXACT (same moves, same nodes --
# it only changes WHEN the move list is sorted), so the game plays identically to the
# server/canonical engine; it just forgoes a small ordering speedup the stock 1 MHz
# game does not need. This + board_any_legal_move() reclaiming the UI's 256-move
# buffer is what keeps the full interactive game inside the stock c64's 64K. (The
# Ultimate profile already sets this for the same reason.)
# SEARCH=fullwidth (default) | selective -- which search plugin to link. The stock
# 1 MHz C64 is the selective search's eventual home (SEARCH=selective), once Phase 2
# lands; both plugin TUs #include search_core.inc.
SEARCH_SRC="$N/search_${SEARCH:-fullwidth}.c"
# shellcheck disable=SC2086
"$LM/mos-c64-clang" -Os -I "$N" -DCREF_LAZY_SELECT=0 $ASM \
    "$N/board.c" "$N/movegen.c" "$N/eval.c" "$SEARCH_SRC" "$UI/c64chess.c" \
    -o "$OUT" -Wl,-Map="${OUT%.prg}.map"

size=$(wc -c < "$OUT")
free=$(perl -ne 'if(/__heap_start = ALIGN/){/^\s+([0-9a-f]+)/;$h=hex($1)} END{print 0xD000-$h}' "${OUT%.prg}.map")
echo "built $OUT  ($size bytes; $free bytes RAM free)"
