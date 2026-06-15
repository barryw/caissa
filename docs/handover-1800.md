# Handover: land 1800 on the 6502

**Branch:** `strength-campaign-c-reference` · **HEAD:** `e18fa36`
**Status:** native engine measures **~1798 vs Stockfish** @ 12k nodes. The 1800
goal is essentially reached *on native*. One mechanical step lands it on the 6502.

Full campaign history + every dead-end is in memory: `reference-engine-tier3.md`.

---

## How we got to ~1798 (the eval stack)

Native vs Stockfish @ 12k fixed nodes went **~1335 → ~1798** via TWO eval wins,
both measured the only way that works:

> **Self-play A/B LIES for eval (+45 self-play → ~0 absolute). Texel-vs-Stockfish
> CONVERTS.** This is the load-bearing lesson. Never tune eval on self-play.

1. **+136** — Texel-tuned **material + PST** to SF (`ef8793c`). Already ported to
   the 6502 hand engine (`src/ai/pst.s` + material constants, `3dba3ab`),
   bit-exact-validated 800/800.
2. **+~250** — Texel-**calibrated the positional terms** to SF (`e18fa36`). The
   hand-set terms were badly over-weighted junk (pawn_attack=600, isolated=200 —
   phantom penalties that hurt play). Calibrating to SF (most → 0, some retuned)
   converts: SF-1500 74-79%, **SF-1700 63.7% (~1798)** vs baseline 45.6% (~1470).
   **On native only — NOT yet on the 6502.**

Other levers, settled this session: material+PST is **tapped**; tapering/MG-EG is
**neutral** (committed as no-op `2b386b0`); search +117 self-play → +39 absolute
(real, kept); 6502 can't out-node to 1800 (cc65 compile-down ~25-30× too slow,
benchmark platform built but parked — `src/ai/*.s` hand engine is the ship target).

---

## THE REMAINING TASK: port the +250 terms to the 6502

The +250 term calibration lives in `native/eval.c` (baked) + `tools/texel_eval.py`
(synced). It is **not** on the 6502 (`src/ai/eval.s`). Port the 33 tuned values.

**Tuned spec** (`build/term_tune.txt`):
```
pawn_attack_minor=0,pawn_attack_rook=0,pawn_attack_queen=0,queen_attack_minor=0,
minor_attack_rook=70,minor_attack_queen=0,knight_outpost=0,pinned_pawn=0,
pinned_minor=62,pinned_rook=87,pinned_queen=112,pinned_attacked=100,doubled_pawn=37,
isolated_pawn=0,advanced_pawn=0,deep_advanced_pawn=0,rook_behind_passer=150,
connected_passer=0,protected_passer=0,blockaded_passer=150,bishop_pair=50,
rook_open_file=0,rook_semi_open_file=30,heavy_seventh_rank=0,endgame_king_activity=0,
endgame_rook_open_file=150,endgame_rook_king_cutoff=0,castled=0,pawn_shield=0,
open_file_penalty=0,semi_open_file_penalty=0,king_center=0,king_march_base=0
```

**Name mapping** (g_w key → `src/ai/eval.s` constant; same names as
`tools/texel_eval.py`, e.g. `pawn_attack_minor` → `PAWN_ATTACK_MINOR_PENALTY`,
`knight_outpost` → `KNIGHT_OUTPOST_BONUS`, `castled` → `CASTLED_BONUS`,
`king_march_base` → `KING_MARCH_BASE`). The full explicit map is in
`tools/term_tune.py`'s sync logic and the commit `e18fa36` python (texel sync).

### Steps
1. Patch the 33 `<NAME> = <val>` constants in `src/ai/eval.s` to the tuned values
   (regex `^<NAME> = \d+`). Same idea as the +136 material port in `3dba3ab`.
2. Build: `make engine-build`.
3. **Validate bit-exact** (the gate): `python3 tools/texel_eval.py` — drives the
   6502 eval via sim6502, compares to the oracle (which already has the tuned
   terms). MUST print `[lazy=1] 800/800` AND `[lazy=0] 800/800`. (~20s.)
   - If a term mismatches: that constant didn't get patched / wrong name. Fix.
4. `make test` (all pass) and `make benchmark`. **Expect the depth-5 benchmark to
   change** — the tuned eval changes the search tree. If it exceeds budget, that's
   latency not strength (see below); bump the budget with a note like we did in
   `3dba3ab` (5M→8.5M). Don't panic on cycle deltas.
5. Commit.

### Watch out
- **Latency ≠ strength.** The eval changes nodes-per-DEPTH, not cycles-per-NODE,
  so on the 6502 fixed-cycles == fixed-nodes and the Elo holds; the only cost is
  move time. We proved the +136 net-positive at 4k nodes (6502-realistic):
  32.5% vs baseline 22.5% = +88. Re-confirm the terms similarly if paranoid:
  `native_vs_stockfish --native-nodes 4000 --native-weights "$(cat build/term_tune.txt)"`
  vs baseline-terms — already done at 12k (+262), 4k optional.
- The 6502 eval has terms in `src/ai/eval.s`; the lazy stage (material+PST) is
  already +136. The full eval (with terms) is what the tuned values fix.

---

## After the port (toward solidifying 1800)

- **Confirm on the 6502 itself** (not just the bit-exact bridge). Slow harnesses:
  `make stockfish-strength` / `colossus-match` (sim6502/VICE, minutes/game). Optional;
  the native ~1798 + bit-exact port is strong evidence.
- **More eval is now MSE-tapped** (material+PST done, terms done, tapering neutral).
  Further gains need NEW eval STRUCTURE (better king-safety/mobility models, then
  Texel-tune) or **6502 speed** (hand-opt `src/ai/*.s` → more nodes → climb the
  proven node curve: ~+158 Elo/decade-of-nodes).
- Absolute numbers carry SF-UCI_Elo calibration uncertainty; the RELATIVE gains
  (+136, +250) and the method are rock-solid.

---

## Toolbox (all built this session, on branch)

- `tools/native_vs_stockfish.py --native-nodes N --sf-elo E --native-weights "..."`
  — THE absolute gate. native vs SF at fixed nodes.
- `native/cref mse build/texel_big.tsv "weights"` — batch Texel MSE-vs-SF, 375k
  positions in ~1s. The fast eval-fit signal.
- `tools/term_tune.py` — coordinate-descent term calibration (produced the +250).
- `tools/texel_tune.py` — linear Texel for material+PST (produced the +136).
- `tools/build_texel_dataset.py gen|merge` — the dataset generator (beast SF18,
  2.69M raw → 375k phase-balanced `build/texel_data_big.json`).
- `tools/texel_eval.py` — the oracle + the sim6502 eval BRIDGE (the 6502 validator).
- cc65 cycle-benchmark recipe (for the speed path) is in memory under
  "6502-SPEED / cc65-ASM-TUNING EXPLORATION".

**First action next session:** do the term port above, get the bridge to 800/800,
commit. That lands ~1798 on the shipping 6502 engine.
