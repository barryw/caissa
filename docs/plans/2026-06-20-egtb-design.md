# EGTB (endgame tablebases) — design, Phase 1 (3-man)

**Date:** 2026-06-20  **Status:** design locked (brainstorm), implementing on `main`.

Endgame tablebases give perfect play in the engine's weakest phase. The search
already mates KQK/KRK (shallow) but misplays KPK (opposition / critical squares).
EGTB lives in the REU (pairs with the just-finished REU work).

## Decisions (locked)
- **Phase 1 scope: 3-man** — KPK (the real win), KQK, KRK. (4-man = 38 MB
  uncompressed, infeasible without block value-compression → Phase 2.)
- **Encoding: DTM, 1 byte/entry.** `0`=draw; `1..127`=STM mates in `v` plies;
  `129..255`=STM mated in `256-v`. Gen asserts max DTM ≤ 127 for the set.
- **Probe: in-search**, at every node with `popcount(occ) ≤ 3` whose material
  signature is in the set → return EXACT score, prune subtree.
- **Storage: REU**, EGTB region above the TT (`[ TT | EGTB ]`), via the validated
  REU DMA accessor. Loaded at boot.
- **Validation: self-contained** — host retrograde gen + python-chess play-out
  (forced mate in N? draws hold?) + index-parity (host==6502) + on-chip probe in
  `x64sc -reu` + spot checks (KPK rule-of-the-square).

## Sizes (dense, 1 B/entry — simple O(1) index, REU absorbs the waste)
| table | index dims | bytes |
|---|---|---|
| KPK | pawn_idx(24) × wk(64) × bk(64) × stm(2) | 196 608 |
| KQK | kk_idx(462) × wq(64) × stm(2) | 59 136 |
| KRK | kk_idx(462) × wr(64) × stm(2) | 59 136 |
| **total** | | **~308 KB** |

Needs a **512 KB REU** (1750 / Ultimate) alongside the TT (use TT13=96 KB to leave
headroom, or TT14 tight = 500 KB / 512 KB). A 256 KB 1764 is too small for 3-man+TT.

## Canonical index (THE invariant — byte-identical host gen ↔ 6502 probe)
Squares are 0–63 (`rank*8 + file`, a1=0). Steps:
1. **Color-normalize.** "Strong side" = the side with the P/Q/R. If it is Black:
   vertical-mirror every square (`sq ^= 56`), swap colors, flip `stm`. Now strong =
   White (WK, BK, white strong piece).
2. **Symmetry fold:**
   - **KPK** (pawn → horizontal mirror only): if pawn file ≥ 4, `sq ^= 7` (mirror
     file) on all pieces. `pawn_idx = (rank(P)-1)*4 + file(P)` ∈ [0,24) (ranks 2–7,
     files a–d). `idx = ((pawn_idx*64 + wk)*64 + bk)*2 + stm`.
   - **KQK/KRK** (no pawn → 8-fold D4): pick the one of 8 D4 ops (identity, file
     mirror `^7`, rank mirror `^56`, both, and the 4 diagonal variants `swap
     rank/file`) that puts WK in the a1–d1–d4 triangle (file ≤ rank ≤ 3); apply it
     to BK and the strong piece. `idx = (kk_idx[wk'][bk']*64 + strong') * 2 + stm`.
     `kk_idx[64*64]` (host-generated, shipped, 4 KB) maps a folded king pair to
     [0,462) or `0xFFFF` (illegal: kings adjacent / off-triangle WK).

The D4 op list, the triangle test, and `kk_idx` are specified ONCE and implemented
identically in `tools/egtb_gen.py` and `src/egtb.c`. A parity test cross-checks.

## Components
- `tools/egtb_gen.py` — per combo: enumerate canonical positions, retrograde BFS
  from checkmates (compute DTM), pack 1 B/entry at `idx`, emit `egtb_tables.bin` +
  `src/egtb_tables.h` (per-table REU base offset, dims, `kk_idx[]`, MAX_DTM assert).
  Then self-validate (play DTM line via python-chess).
- `src/egtb.h` / `src/egtb.c` — `int egtb_probe(const Board *b, int ply, int *score)`:
  `popcount ≤ 3` gate → signature → color-normalize → fold → REU read 1 byte →
  decode to ply-anchored score. Returns 1 (hit, `*score` set) / 0 (no table).
- `src/search.c` — call `egtb_probe` at `negamax`/`quiesce` entry; on hit return the
  exact score (TT-store optional).
- Loader — boot-copy `egtb_tables.bin` → REU EGTB region.

## Build order (prove correctness layer by layer)
1. `egtb_gen.py` (gen + python-chess play-out validation) — host only, the oracle.
2. Host probe (`egtb.c` compiled for host, table in RAM) — cross-check vs
   python-chess WDL/DTM for EVERY legal position (index-parity + correctness).
3. Host search integration — confirm the engine plays KPK perfectly (spot positions
   + vs Stockfish), measure node savings.
4. 6502/REU: load tables to REU, probe via DMA; on-chip validation in `x64sc -reu`
   (reuse `reu_validate.py` / `CREF_TT_REU_DEBUG`-style parity).

## Profile
`CREF_PROFILE_REU` (already MAX_PLY 8 + REU). EGTB gated by a new `CREF_EGTB`
(default on for REU/host, off elsewhere). Reuses [[reu-tt-validation]] +
`docs/xram-tt-design.md`.
