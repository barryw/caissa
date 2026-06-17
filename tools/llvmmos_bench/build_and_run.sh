#!/usr/bin/env bash
# build_and_run.sh -- reproduce the llvm-mos cycles-per-eval feasibility numbers.
#
# Prereqs (one-time):
#   1. llvm-mos compiler built at ~/Git/llvm-mos/build (clang 22, MOS backend).
#   2. mos-clang* symlinks in build/bin  (created by this spike; see NOTES.md).
#   3. compiler-rt MOS builtins installed at
#        build/lib/clang/22/lib/mos-unknown-unknown/libclang_rt.builtins.a
#      (built standalone; see NOTES.md).
#   4. llvm-mos-sdk installed INTO the llvm-mos build prefix:
#        cd ~/Git/llvm-mos-sdk && rm -rf build && mkdir build && cd build && \
#        cmake -G Ninja -DCMAKE_INSTALL_PREFIX=~/Git/llvm-mos/build \
#              -DLLVM_MOS=~/Git/llvm-mos/build -DLLVM_MOS_BOOTSTRAP_COMPILER=Off \
#              -DLLVM_MOS_BUILD_EXAMPLES=Off .. && ninja install
#
# Then: ./build_and_run.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

LLVM_MOS="${LLVM_MOS:-$HOME/Git/llvm-mos/build}"
SIMCC="$LLVM_MOS/bin/mos-sim-clang"
EVAL="../../src/eval.c"
INC="-I../../src"

echo ">> building host harness (cpu6502 cycle-counting runner)"
cc -O2 -o run_sim run_sim.c ../fast6502_bridge/cpu6502.c

# per-eval = (cycles(N=200) - cycles(N=100)) / 100  -> cancels all fixed
# overhead (crt0, board setup, putchar). The two images differ only in BENCH_N.
bench() {  # $1=label  $2=OPT  $3=BENCH_FULL
  local label="$1" opt="$2" full="$3"
  "$SIMCC" "-$opt" -DBENCH_N=100 -DBENCH_FULL="$full" $INC bench_main.c "$EVAL" -o /tmp/_b100.sim
  "$SIMCC" "-$opt" -DBENCH_N=200 -DBENCH_FULL="$full" $INC bench_main.c "$EVAL" -o /tmp/_b200.sim
  local c1 c2
  c1="$(./run_sim /tmp/_b100.sim 2>/dev/null)"
  c2="$(./run_sim /tmp/_b200.sim 2>/dev/null)"
  printf '%-22s -%-3s : %s cycles/eval\n' "$label" "$opt" "$(( (c2 - c1) / 100 ))"
}

echo ">> cycles per eval (llvm-mos, mos-sim, run in fast6502 core)"
for opt in Os O2 O3; do
  bench eval_material_pst "$opt" 0
done
for opt in Os O2 O3; do
  bench eval_full "$opt" 1
done

echo
echo ">> code sizes (c64 target, no-LTO/no-inline, isolated symbols)"
"$LLVM_MOS/bin/mos-c64-clang" -O2 -fno-lto -fno-inline -c $INC "$EVAL" -o /tmp/_eval.o
"$LLVM_MOS/bin/llvm-nm" --print-size --size-sort /tmp/_eval.o 2>/dev/null \
  | grep -E ' eval_material_pst$| eval_full$' \
  | while read -r addr size t name; do
      printf '%-20s = %d bytes\n' "$name" "$((16#$size))"
    done
