# llvm-mos feasibility spike: native C eval on a real 6502

**Question:** can llvm-mos compile the native C chess engine's eval to 6502 code
*fast enough* to ship on a C64, so we can skip the hand-port?

**Answer (measured, not estimated):**

| eval               | -Os    | -O2    | -O3    | code size |
|--------------------|--------|--------|--------|-----------|
| `eval_material_pst`| 15 820 | 15 317 | 15 317 | 629 B     |
| `eval_full`        | 98 933 | 85 594 | 82 363 | 1 767 B   |

Cycles per eval, run on a cycle-exact NMOS 6502 (`tools/fast6502_bridge`).

Baselines: **cc65 ≈ 71 000 cyc** (software-stack tax), **hand-asm ≈ 1 000–3 000 cyc**.

* `eval_material_pst` (the HOT lazy eval): llvm-mos at -O2 = **15 317 cyc**, i.e.
  **~4.6x slower than cc65's 71k** (llvm-mos is *faster*), and **~5–15x slower
  than hand-asm**. That is *inside* the ~3–8x viability band. **VIABLE.**
* `eval_full` (full positional eval): **~85 600 cyc** at -O2, ~28–85x hand. Too
  heavy to call at every leaf; same as the real engine, which calls the *lazy*
  eval at leaves and only pays for full eval near the alpha-beta window.

## Verdict

Native-on-6502 via llvm-mos is **VIABLE for the hot (lazy) eval**: ~15.3k
cyc/eval is ~4.6x better than cc65 and within ~5–15x of hand-asm — close enough
for correspondence time controls. On a 1 MHz C64 (~1e6 cyc/s) that is
**~65 lazy-evals/sec**, so a leaf-eval-bound search manages on the order of
tens of nodes/sec; reaching depth 6 needs alpha-beta + good move ordering
(the engine already has both) and a correspondence-length clock, but it is in
range. The full eval at ~85k cyc is for near-window nodes only, exactly as the
engine already gates it.

This makes "design-strong-in-C, compile-down with llvm-mos" a real alternative
to hand-porting eval term-by-term — the same C the host oracle runs.

## Blockers found (full engine core)

`board.c`, `movegen.c`, `eval.c` compile **clean** under llvm-mos. Two things
stop a drop-in full-engine link:

1. **`int` is 16-bit on llvm-mos** (`sizeof(int)==2`, `sizeof(long)==4`), like
   cc65 and unlike the host. `search.c` guards its big transposition table on
   `#ifdef __CC65__` (TT_BITS 8 vs 16); llvm-mos defines neither `__CC65__` nor
   the cc65 macro, so it takes the host branch and `1<<16` overflows to a
   negative array size — compile error. Trivial source fix (broaden the guard to
   `defined(__CC65__) || defined(__mos__)`); for this spike we passed
   `-D__CC65__` to select the 6502 config without editing source.

2. **BSS does not fit 64K** (the known RAM-diet TODO). With a real
   `search_bestmove` call linked in, `ld.lld` reports:
   `section '.bss' will not fit in region 'ram': overflowed by 99 085 bytes`.
   Driver: `g_ml[48][256]` + `g_filt[48][256]` Move arrays = ~98 KB. The *code*
   links fine; only the static RAM budget blows. Trim MAX_PLY / share a move
   buffer to fit. **Not solved here — flagged as the RAM-diet TODO.**

So: the engine *logic* is llvm-mos-clean; only the int-width assumption in
search.c's TT and the move-list RAM budget need addressing for a full port.

## How the toolchain was made to work (one-time setup)

The llvm-mos compiler at `~/Git/llvm-mos/build` was a partial build: it had
`clang` (MOS backend) but **no SDK, no `mos-*` driver symlinks, and no MOS
compiler-rt builtins**. Three steps fixed it:

1. **Create the `mos-clang*` driver symlinks** clang infers its default target
   from argv[0]; plain `clang` defaults to the host (arm64-apple), `mos-clang`
   defaults to `--target=mos`. The SDK build + the convenient `mos-sim-clang` /
   `mos-c64-clang` wrappers require them:
   ```
   cd ~/Git/llvm-mos/build/bin
   ln -s clang mos-clang; ln -s clang mos-clang++; ln -s clang mos-clang-cpp
   ```

2. **Build MOS compiler-rt builtins** (the SDK refuses to configure without
   `lib/clang/22/lib/mos-unknown-unknown/libclang_rt.builtins.a`). Standalone
   build of `compiler-rt/lib/builtins` for the mos triple:
   ```
   cmake -G Ninja ~/Git/llvm-mos/compiler-rt/lib/builtins \
     -DCMAKE_BUILD_TYPE=MinSizeRel -DCMAKE_SYSTEM_NAME=Generic \
     -DCMAKE_C_COMPILER=~/Git/llvm-mos/build/bin/clang \
     -DCMAKE_ASM_COMPILER=~/Git/llvm-mos/build/bin/clang \
     -DCMAKE_C_COMPILER_TARGET=mos-unknown-unknown \
     -DCMAKE_ASM_COMPILER_TARGET=mos-unknown-unknown \
     -DCMAKE_AR=~/Git/llvm-mos/build/bin/llvm-ar \
     -DCMAKE_RANLIB=~/Git/llvm-mos/build/bin/llvm-ranlib \
     -DCOMPILER_RT_BAREMETAL_BUILD=ON -DCOMPILER_RT_BUILTINS_ENABLE_PIC=OFF \
     -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON -DCMAKE_C_FLAGS=-Os
   ninja   # -> lib/generic/libclang_rt.builtins-mos.a
   mkdir -p ~/Git/llvm-mos/build/lib/clang/22/lib/mos-unknown-unknown
   cp lib/generic/libclang_rt.builtins-mos.a \
      ~/Git/llvm-mos/build/lib/clang/22/lib/mos-unknown-unknown/libclang_rt.builtins.a
   ```

3. **Build + install llvm-mos-sdk into the llvm-mos build prefix** (provides
   crt0/libc/linker-scripts/platform multilibs for `sim`, `c64`, etc.):
   ```
   git clone https://github.com/llvm-mos/llvm-mos-sdk ~/Git/llvm-mos-sdk
   cd ~/Git/llvm-mos-sdk && mkdir build && cd build
   cmake -G Ninja -DCMAKE_INSTALL_PREFIX=~/Git/llvm-mos/build \
         -DLLVM_MOS=~/Git/llvm-mos/build -DLLVM_MOS_BOOTSTRAP_COMPILER=Off \
         -DLLVM_MOS_BUILD_EXAMPLES=Off ..
   ninja install
   ```

After this, `mos-sim-clang -Os foo.c -o foo.sim` and
`mos-c64-clang -Os foo.c -o foo.prg` both link.

## How the benchmark runs

`mos-sim` emits a **chunked image**: repeated `[load_addr u16le][len u16le][bytes]`,
ending with the 6-byte vector block at `0xFFFA` (RESET = `_start`). `run_sim.c`
loads the chunks into the fast6502 core's flat 64K, sets PC from the reset
vector, and single-steps until the program writes the sim `exit` register at
`0xFFF8` (mos-platform/sim/stdlib.c). `bench_main.c` loops the eval N times over
a fixed mid-game board and writes the running-sum result to the `putchar`
register (`0xFFF9`) so the loop can't be dead-stripped.

**Per-eval is measured by difference:** cycles(N=200) − cycles(N=100), all over
100. This cancels every fixed cost (crt0, board setup, the putchar writes) and
isolates the pure eval-loop cycles. Correctness verified: the N=100 image emits
`putchar_bytes=[112,48]` (sum 12 400) which matches the native host reference
for the same position exactly, proving the 6502 eval computes the real value.

## Reproduce

```
tools/llvmmos_bench/build_and_run.sh
```
(Assumes the one-time toolchain setup above.)

---

# Validated bestmove-on-6502 program (the measurable artifact)

`caissa.c` links the **full** native engine (board + movegen + full eval +
alpha-beta + TT + quiescence + killers + null-move + LMR) for the `mos-sim`
target and computes a best move for any FEN, **validated move-for-move against the
host reference engine** inside the cycle-exact fast6502 core (`validate.c`).

## One command to rebuild + validate

```
tools/llvmmos_bench/build_caissa.sh [DEPTH=4] [FENLIST]
```

It (1) re-runs the host gates, (2) builds `native/cref` (canonical, TT16) and
`/tmp/cref_mos` (the host engine in the **exact 6502 config**, `-D__mos__`), (3)
links `/tmp/caissa.sim`, (4) builds the validator, (5) reports N/N best moves
identical to the matched-config oracle.

## Validation result (the whole point)

* **depth 4: 30/30 and 60/60 best moves IDENTICAL** to the matched-config oracle
  (`/tmp/cref_mos`); **29/30 vs canonical `native/cref`** -- the single delta is
  the TT-size config (TT8 on 6502 vs TT16 on host: a legitimate parameter,
  measured ~1/120 at d4, NOT a port bug).
* **depth 6: 6/6 identical** to the matched-config oracle, 0 run-errors.
* cycles/move (fast6502, => seconds @ 1 MHz): depth 4 avg ~1.2e9 cyc (~1200 s),
  depth 6 ~2e8 cyc on the sampled positions (~200 s); heavy tactical positions
  reach ~9e9 cyc at d4. (Correspondence-clock territory, as expected.)

## The memory ABI (host reads these from the linker .map; `validate.c` does this
   automatically, so addresses below move freely on rebuild)

| symbol      | dir | type            | meaning                                  |
|-------------|-----|-----------------|------------------------------------------|
| `g_fen`     | in  | `char[100]`     | FEN C-string (NUL-terminated)            |
| `g_depth`   | in  | `u8`            | search depth                             |
| `g_go`      | in  | `u8`            | host sets =1 to start (after READY)      |
| `g_from`    | out | `u8`            | chosen move FROM square (0x88 encoding)  |
| `g_to`      | out | `u8`            | chosen move TO square (0x88 encoding)    |
| `g_promo`   | out | `u8`            | promotion piece type (2..5), 0 = none    |
| `g_score`   | out | `i16`           | search score (stm-relative cp)           |
| `g_nodes`   | out | `u32`           | node count (diagnostics)                 |
| `g_qnodes`  | out | `u32`           | quiescence node count (diagnostics)      |
| `g_status`  | out | `u8`            | 0 = ok, 1 = FEN parse error              |
| `g_done`    | out | `u8`            | set =1 when the search finished          |

Handshake: crt0 zeroes `.bss`, then `main()` writes `SIM_READY` (0xA5) to the sim
putchar register (0xFFF9) and busy-waits on `g_go`. The host runs the image until
READY, injects `g_fen`/`g_depth`, sets `g_go=1`, then runs until the sim `exit`
register (0xFFF8) is written (`main` returned) and reads the result. **The driver
seeds the repetition table with the root hash (`hist={root}, len 1`) exactly as
`native/cref` does** -- this is load-bearing for move-for-move agreement.

## Did it LINK and FIT in 64 K? Yes.

Final image (mos-sim, `-Os`): `.text` ~31.5 KB, `.rodata` ~1.7 KB, `.bss`
~24.8 KB; bss ends ~0xE49x, soft stack from 0xFFF0 down => ~6.6 KB stack headroom
(measured deepest soft-SP ~0xFD1E at d4, ~0.7 KB used -- comfortable).

## RAM diet (host-guarded edits in native/, host build byte-identical)

The unported driver overflowed `.bss` by ~99 KB. Fixes, all guarded under
`defined(__CC65__) || defined(__mos__)` so the **host keeps its large values and
all host gates stay green**:

1. `search.c` TT guard broadened to include `__mos__` (`TT_BITS 8`, was a 16-bit
   `1<<16` overflow under llvm-mos). [blocker 1]
2. `MAX_PLY 7` on 6502 (host 48): negamax recurses at most `depth` plies
   (measured d6 -> ply 6 over 400 positions), so the per-ply move bank `g_ml`
   only needs `depth+1`.
3. Quiescence raw list `g_qml` is now a **single shared buffer** (the raw list is
   filtered into `g_filt` before the frame recurses) instead of one per ply.
   `g_filt` is indexed by **quiescence depth** (`qd`, unique per live frame), not
   absolute ply, shrinking it from `[MAX_PLY][256]` to `[MAX_QUIESCE_DEPTH+1][256]`.
   Both changes are behavior-identical on every target (verified: host node
   counts unchanged; 6502 d1-d3 search trees bit-exact to host).
4. `g_history` (16 KB butterfly table) does not fit; on 6502 the **history
   heuristic is disabled** (`g_sc.history=0`) and the table shrinks to a 1-entry
   stub. Every other ordering term (TT move, MVV-LVA, killers) + null-move + LMR
   stay on. (Killer lookups guard `ply < MAX_PLY`; killers at higher quiescence
   plies are always empty, so skipping them is behavior-identical.)
5. `board.h`: `hash_t` pinned to **`uint32_t`** (was `unsigned long` = 64-bit on
   the LP64 host, 32-bit on the 6502). The splitmix zobrist mixer folds high bits
   down with shifts, so a 64-bit host and a 32-bit 6502 computed *different* keys
   => different TT collisions / repetition hits => occasionally different moves.
   Pinning to 32 bits makes the keys identical on both. (perft unaffected: counts
   at the verified depths stay < 2^32. All host gates still pass.)
6. `MAX_PATH 64` on 6502 (host 1024): the tool searches a single position with no
   game history, so the repetition stack only holds the search path (<= MAX_PLY).

Everything else lives under `tools/llvmmos_bench/` (`caissa.c`, `validate.c`,
`build_caissa.sh`).
