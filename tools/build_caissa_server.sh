#!/usr/bin/env bash
# build_caissa_server.sh -- build the persistent headless C64 bestmove server
# (apps/c64/caissa_server.c) into a real .prg, driven inside headless VICE by
# tools/vice_caissa.py for Caissa-vs-Colossus matches.
#
#   ./tools/build_caissa_server.sh           -> build/caissa_server.prg (+ .map)
#   ./tools/build_caissa_server.sh OUT.prg   -> custom output path
#
# Same src/ engine + same hand-asm hot-path config as the shipping C64 game
# (tools/build_c64.sh): is_square_attacked / make / unmake / gen_pseudo /
# gen_legal are asm; eval_full + order_moves stay C (the compiler inlines them
# better on this target -- see the speed-campaign notes). The .map exposes the
# ABI symbol addresses (g_fen, g_depth, g_go, g_done, g_ready, g_from, ...) that
# the VICE driver pokes/peeks over the monitor.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
N="$HERE/src"
UI="$HERE/apps/c64"
LM="${LLVM_MOS:-$HOME/Git/llvm-mos/build}/bin"
OUT="${1:-$HERE/build/caissa_server.prg}"
mkdir -p "$(dirname "$OUT")"

ASM="-DCREF_ASM_IS_SQUARE_ATTACKED $N/is_square_attacked_6502.s \
     -DCREF_ASM_UNMAKE_MOVE        $N/unmake_move_6502.s \
     -DCREF_ASM_MAKE_MOVE          $N/make_move_6502.s \
     -DCREF_ASM_GEN_PSEUDO         $N/gen_pseudo_6502.s \
     -DCREF_ASM_GEN_LEGAL          $N/gen_legal_6502.s"

# shellcheck disable=SC2086
"$LM/mos-c64-clang" -Os -I "$N" $ASM \
    "$N/board.c" "$N/movegen.c" "$N/eval.c" "$N/search.c" "$UI/caissa_server.c" \
    -o "$OUT" -Wl,-Map="${OUT%.prg}.map"

size=$(wc -c < "$OUT")
free=$(perl -ne 'if(/__heap_start = ALIGN/){/^\s+([0-9a-f]+)/;$h=hex($1)} END{print 0xD000-$h}' "${OUT%.prg}.map")
echo "built $OUT  ($size bytes; $free bytes RAM free)"

# Surface the ABI symbol addresses the driver needs (sanity + quick reference).
# Map columns are: vma lma size align symbol  (vma is bare hex, no 0x prefix).
echo "ABI symbols:"
for sym in g_fen g_depth g_go g_done g_ready g_from g_to g_promo g_score g_nodes g_qnodes g_status; do
    addr=$(awk -v s="$sym" '$NF==s && $1 ~ /^[0-9a-fA-F]+$/ {print $1; exit}' "${OUT%.prg}.map")
    printf '  %-10s %s\n' "$sym" "${addr:+0x$addr}"
done
