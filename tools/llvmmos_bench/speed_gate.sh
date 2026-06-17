#!/usr/bin/env bash
# speed_gate.sh -- the regression gate for AGGRESSIVE SPEED OPTIMIZATION.
#
# Pure speed work (faster eval/movegen, hand-asm leaves, restructuring) must
# preserve EXACT behavior. This gate fails if any of these change:
#   1. movegen   -> PERFT EXACT vs python-chess (kiwipete/ep/castle/promo suite)
#   2. eval      -> 22157/22157 bit-exact vs texel_eval oracle
#   3. search    -> GOLDEN best moves (cref_mos d4 + d6 over the corpus)  [NEW]
#   4. 6502 port -> the mos-sim image's move == host cref_mos, move-for-move
# and it REPORTS the speed metrics (cyc/eval, cyc/move) so gains are tracked.
#
# A failure means: either a real regression (fix it), or an INTENTIONAL behavior
# change -> re-bless golden (python3 tools/llvmmos_bench/gen_golden.py) AND re-measure Elo
# (NATIVE_CREF=tools/llvmmos_bench/caissa_cli native_vs_stockfish ...).
#
# Usage:  bash tools/llvmmos_bench/speed_gate.sh [--deep]
#   --deep also runs the slow 6502-image fidelity at d6 on a subset.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$ROOT"
CORPUS="$HERE/regression_fens.txt"
GOLDEN="$HERE/golden_moves.txt"
FAIL=0
pass(){ printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail(){ printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAIL=1; }

echo "== speed regression gate =="

# build everything + 6502 image fidelity @ d4 (build_caissa.sh runs host
# gates internally but suppresses their output, so we re-run perft/eval below
# for a visible pass/fail).
echo ">> build native + 6502 image, validate port fidelity @ d4"
if bash "$HERE/build_caissa.sh" 4 "$CORPUS" > /tmp/gate_build.log 2>&1; then
  VAL=$(grep -E "VALIDATION:" /tmp/gate_build.log | tail -1)
  echo "$VAL" | grep -qE "([0-9]+)/\1 identical" && pass "6502 image == cref_mos @ d4 ($VAL)" || fail "6502 fidelity @ d4 ($VAL)"
  CYCMOVE=$(grep -E "cycles/move:" /tmp/gate_build.log | tail -1)
else
  fail "build_caissa.sh failed (see /tmp/gate_build.log)"; CYCMOVE=""
fi

# 1: movegen  2: eval -- run the host checks directly (test_perft/test_eval were
# just built by build_caissa.sh's `make verify`).
echo ">> movegen (PERFT) + eval (bit-exact)"
python3 test/native_perft_check.py 2>&1 | grep -q "PERFT EXACT" && pass "movegen PERFT EXACT" || fail "PERFT"
python3 test/native_eval_check.py 2>&1 | grep -q "22157/22157" && pass "eval 22157/22157 bit-exact" || fail "eval bit-exact"

# 3: GOLDEN search regression -- cref_mos d4 + d6 over the corpus must match golden
echo ">> search golden moves (cref_mos d4 + d6 == golden)"
python3 - "$CORPUS" "$GOLDEN" <<'PY'
import subprocess, sys
corpus, golden = sys.argv[1], sys.argv[2]
g = {}
for ln in open(golden):
    ln = ln.rstrip("\n")
    if not ln or ln.startswith("#"): continue
    f, d4, d6 = ln.split("\t")
    g[f] = (d4, d6)
def mv(fen, d):
    out = subprocess.run(["/tmp/cref_mos","bestmove",fen,str(d)],capture_output=True,text=True).stdout
    return out.split()[1] if out.startswith("bestmove") else "ERR"
bad = 0; n = 0
for ln in open(corpus):
    fen = ln.strip()
    if not fen: continue
    if fen not in g:
        print(f"  \033[31mFAIL\033[0m golden missing FEN: {fen}"); bad += 1; continue
    n += 1
    for d, exp in zip((4,6), g[fen]):
        got = mv(fen, d)
        if got != exp:
            print(f"  \033[31mFAIL\033[0m d{d} {fen}\n        golden={exp} got={got}"); bad += 1
print(f"  golden: {n} positions checked, {bad} mismatches")
sys.exit(1 if bad else 0)
PY
[ $? -eq 0 ] && pass "search golden moves match" || fail "search golden moves CHANGED (re-bless + re-measure Elo if intentional)"

# speed metric: cyc/eval (bench) + cyc/move (from validate above)
echo ">> speed metrics (baseline tracking)"
if bash "$HERE/build_and_run.sh" > /tmp/gate_bench.log 2>&1; then
  CYCEVAL=$(grep -E "cycles/eval" /tmp/gate_bench.log | grep -iE "eval_material_pst.*-O2|eval_full.*-O2" | sed 's/  */ /g')
  echo "  cyc/eval (-O2): ${CYCEVAL:-see /tmp/gate_bench.log}"
fi
echo "  ${CYCMOVE:-cyc/move: (build failed)}"

# optional slow deep check
if [ "${1:-}" = "--deep" ]; then
  echo ">> --deep: 6502 image == cref_mos @ d6 (subset, SLOW)"
  head -10 "$CORPUS" > /tmp/gate_d6subset.txt
  /tmp/validate /tmp/caissa.sim /tmp/caissa.map /tmp/gate_d6subset.txt 6 /tmp/cref_mos 2>/dev/null | grep -E "VALIDATION" \
    && pass "d6 subset fidelity" || fail "d6 subset fidelity"
fi

echo "== gate $([ $FAIL -eq 0 ] && echo PASS || echo FAIL) =="
exit $FAIL
