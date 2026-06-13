# Engine Optimization Backlog

Ranked perf/size/reuse opportunities from a read-only 6510 audit (2026-06-13).
Each item is independently actionable. Verify every change with
`make test` (6 suites) + `make benchmark` (9 gates) + Colossus corpus
(`tools/colossus_blunders.json`, must stay 8/8 top1). HOT = inner
search/eval/movegen/attack/make-unmake (millions of calls/move).

## Batch A — safe, behavior-identical (size + easy cycles)
- **Delete dead QSave/QRestore.** `search.s` QSaveMoveList/QRestoreMoveList routines + `QSavedCount`/`QSavedFrom`/`QSavedTo` `.res` buffers + `QSAVED_MAX_MOVES`. Zero callers (left over from the reverted save/restore). ~640-670 bytes (520 BSS + ~150 code). Keep `MAX_QUIESCE_DEPTH`. LOW.
- **Delete `CheckEnemyColor`** (`attack.s:207`) IF unreferenced — `grep -rn 'jsr CheckEnemyColor\|jmp CheckEnemyColor' src/` first. Hot paths use SMC now. ~17 bytes. LOW.
- **`TTComputeEntryPtr` helper** — TTProbe (`tt.s:123`) and TTStore (`tt.s:222`) share identical index*8+TT_BASE math. ~16 bytes, cycle-neutral. LOW.
- **MVV-LVA swap via ZP temp** (`movegen.s:804,872`) — replace pha/pla stack swaps with a ZP scratch byte. ~20 cyc/swap. LOW.
- **Merge move-list snapshot pointer helpers** (`search.s:7604-7642`) — SetMoveListSnapshotFromPtr/ToPtr differ only by base. ~20 bytes. LOW.

## Batch B — cycle wins, light verification
- **Zobrist LUT reuse** (`zobrist.s:392`) — replace inline 0x88→64 math with eval's existing `Sq88To64` table (export symbol). ~14 cyc/piece × ~16-32 pieces/node = ~300-450 cyc/node. HOT. LOW.
- **Dual-array snapshot loop** (`search.s:7644-7696`) — copy From+To in one loop instead of two. ~5 cyc/move × ~35 × (save+restore)/node. HOT. LOW-MED.
- **Movegen jump table** (`movegen.s:667,1640`) — replace 6-`cmp` piece dispatch with `jmp (table,x)`. ~6-15 cyc/piece. MED.

## Isolated, measured individually
- **Cache `SearchDepth*8` NegamaxState offset** — 28 sites recompute `lda SearchDepth/asl/asl/asl/tax` (~12 cyc/7 bytes each); SearchDepth invariant across a node body. Cache in ZP, reload after X-clobbering JSRs; drop the no-JSR-between redundant ones outright. ~18 convertible. HOT. MED (per-site clobber check).
- **Eval per-piece dispatch** (`eval.s:248-258`) — the 6 positional calls fire unconditionally per non-pawn; each callee re-rejects wrong types. Type-indexed dispatch saves 3-5 wasted jsr/cmp/rts. ~40-60 cyc/non-pawn piece. HOT-when-full-eval. MED (A/B eval output identical).
- **Movegen driver merge** (`movegen.s:636-718` vs `1610-1689`) — GenerateAllMoves/GenerateCaptures share the piece-list walk; one driver + dispatch-table param. ~80-120 bytes. MED.

## Future / HIGH risk
- **Incremental Zobrist** in MakeMove/UnmakeMove (XOR-out/in vs full recompute) — biggest theoretical win (~300-500 cyc/node) but touches every special move. Isolated project.
- **Eval ray-scan dedup** (`eval.s` IsPieceBishop/Queen/KnightAttacked) — share diagonal-walk inner loop. ~40-60 bytes, semantics-sensitive. Do after eval dispatch.
