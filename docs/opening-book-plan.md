# Opening Book — Compile & Wire Plan

This document is the hand-off for the **later src-touching step** that turns the
engine-independent dataset `tools/opening_repertoire.json` into a working opening
book inside the Caïssa C64 engine.

It is written so that whoever picks it up can implement the book without
re-deriving any of the constraints below. Everything in this plan was verified
against the live source (`src/ai/zobrist.s`, `src/ai/search.s`,
`src/engine/platform_c64.s`, `src/engine/platform_test.s`, `src/constants.s`).

> **Producer side (already done, this commit):**
> `tools/build_opening_repertoire.py` walks a curated, Stockfish-vetted set of
> SOUND structural mainlines and emits `tools/opening_repertoire.json` as a list
> of `{fen, best_move_uci, best_move_san, eval_cp, depth, line_name, ply}`
> entries, de-duplicated by FEN. It is **engine-independent**: it is keyed by FEN,
> not by the engine's Zobrist hash.

---

## 0. The single most important constraint: the engine's Zobrist key is 16-bit

`ComputeZobristHash` (`src/ai/zobrist.s:190`) stores its result in
`ZobristHash`, which is **2 bytes (16 bits)** — see the header comment
"Result stored in ZobristHash (2 bytes)" and the storage at
`src/ai/zobrist.s:175`.

Consequences the compile step **must** design around:

1. **The key space is only 65,536 buckets.** With a few hundred to low-thousands
   of book positions the birthday-paradox collision rate is non-trivial. The
   engine is *already built to tolerate this*: after a book hit it regenerates
   legal moves and only plays the candidate if it is legal in the current
   position (`src/ai/search.s:10584`+), and then runs the pawn-attack guard. A
   16-bit collision therefore degrades to "ignore the book here, search
   normally" — never an illegal move. **Do not** try to widen the key in the
   probe path; match whatever `ComputeZobristHash` produces, bug-for-bug.
2. **Keys MUST come from the engine, not from Python.** Reimplementing Zobrist
   in Python is a drift hazard (square ordering, the 0x88 skip, side-to-move
   XOR via `ZobristSide`, piece encoding). Drive the engine instead — see §1.

---

## 1. Computing keys: drive the engine, never reimplement Zobrist

For each entry's `fen`, obtain the engine's own 16-bit key by **driving the
engine through the sim6502 bridge** (the same headless bridge used elsewhere in
`tools/`):

1. Set up the board from the FEN (the bridge already has an API to load a
   position / FEN for the engine state — reuse whatever
   `tools/sim6502_headless_runner.py` / the bridge expose; the engine builds its
   `Board88`, `currentplayer`, piece lists, etc.).
2. Call `ComputeZobristHash`.
3. Read back the 2-byte `ZobristHash` (little-endian on 6502: low byte at
   `ZobristHash`, high byte at `ZobristHash + 1`). Record it as a 16-bit
   integer.

Notes:
* The side-to-move bit is folded in (`ZobristSide` XOR when white to move,
  `src/ai/zobrist.s` `HashZobristState`), so the FEN's side-to-move is already
  captured — no extra work needed.
* Castling rights / en-passant: confirm whether the engine's hash includes them.
  As of this writing `HashZobristState` XORs side-to-move and iterates pieces; if
  it does **not** hash castling/EP, then two of our FEN entries that differ only
  in castling/EP will produce the **same** engine key. De-duplicate **on the
  engine key** at compile time (see §2 step 3) and, on a key clash, keep the
  lower-ply / mainline entry. (The producer already de-duplicates by FEN; this is
  the second, engine-key-level dedup that only the engine can do.)
* **Do this offline at compile time**, emit a static blob, and link it. The
  runtime probe must not need Python.

> Reproducibility caveat: this is the *only* step that needs the engine binary
> and the bridge. It races the concurrent assembly rebuild, so run it when the
> engine is stable, against a known-good build, and cache the resulting
> key→move table.

---

## 2. Binary format

Two reserved regions already exist in `src/constants.s`:

```
BOOK_HASH_TABLE = $5600   ; sorted hash table start
BOOK_HASH_SIZE  = $4A00   ; ~18.5 KB   ($5600–$9FFF)
BOOK_ENTRIES    = $E000   ; entry data start
BOOK_ENTRIES_SIZE = $2000 ; 8 KB
```

Both live in the extended memory available under `MEMORY_CONFIG_NORMAL`
(`src/constants.s`).

### Recommended layout: a single sorted key→move table (O(log n) probe)

A book entry needs three things: the 16-bit key and the move's `from`/`to`
squares. The runtime consumer (`src/ai/search.s:10580`) expects the lookup to
return **A = from, Y = to** (board square indices, the same encoding the move
list uses — `MoveListFrom`/`MoveListTo`, 0x88-style square bytes; the engine
re-validates the move against generated legal moves so the exact square encoding
just has to match what `GenerateLegalMoves` produces).

Lay out **one** array, sorted ascending by 16-bit key, for binary search:

```
; BOOK_HASH_TABLE region, N entries, 4 bytes each:
;   +0  key_lo
;   +1  key_hi
;   +2  from   (square byte, as in MoveListFrom)
;   +3  to     (square byte, as in MoveListTo)
```

* 4 bytes/entry into the 18.5 KB `BOOK_HASH_TABLE` region → up to ~4,736
  entries. That comfortably covers a "few hundred to low-thousands" book.
* Store the entry **count** (16-bit) somewhere the probe can read — either as a
  2-byte header at `BOOK_HASH_TABLE` (then entries start at `BOOK_HASH_TABLE+2`)
  or as a separate linked constant (e.g. `BOOK_ENTRY_COUNT`). Pick one and
  document it next to the table.
* Sorted-by-key enables a binary search: O(log₂ 4736) ≈ 13 comparisons worst
  case — trivial on the 6502 versus a full search.

The separate `BOOK_ENTRIES` ($E000, 8 KB) region is **not needed** for this
flat layout (move is inlined as the 2 trailing bytes). Keep it reserved for a
future variant (e.g. multiple weighted moves per position, or a key→offset
indirection if entries grow). If you prefer the split design, put the sorted
2-byte keys + 2-byte offsets in `BOOK_HASH_TABLE` and the move payloads in
`BOOK_ENTRIES`; the flat layout above is simpler and recommended first.

### Endianness / sorting
Sort on the **numeric** 16-bit key. The 6502 probe compares `key_hi` first then
`key_lo`. Make the compile step's sort match (sort by `(key_hi, key_lo)` =
sort by the integer key). Keep keys little-endian in the bytes as shown.

### Build integration
Emit the blob from a new offline tool (not part of this commit), e.g.
`tools/compile_opening_book.py`, that:
1. reads `tools/opening_repertoire.json`,
2. computes each engine key via the bridge (§1),
3. dedups on the engine key,
4. converts each `best_move_uci` to the engine's `from`/`to` square bytes
   (square index in the engine's board encoding — verify against how the engine
   reports moves through the bridge; do **not** assume 0–63 vs 0x88 without
   checking),
5. sorts by key and writes the table, plus the count,
6. links the result into the build (a generated `.s`/`.bin` `.incbin`'d into the
   image, or written straight into the reserved region by the loader).

A blob that overflows `BOOK_HASH_SIZE` must hard-fail the compile.

---

## 3. The consumption hook (already wired for graceful degradation)

The search already probes the book — this is **done**, the later step only has
to supply the data + the `LookupOpeningMove` routine. Flow in
`FindBestMove` (`src/ai/search.s` ≈ 10560–10610):

1. **Hang guards first** — book is skipped entirely if the side to move already
   has a piece hanging:
   * `SideHasPawnAttackedPiece` → skip book
   * `SideHasMinorAttackedMajor` → skip book
   This stops the engine reciting development moves while material is hanging.
2. `ComputeZobristHash` → fills `ZobristHash`.
3. `jsr EngineLookupOpeningMove` — carry **set** = hit (A = from, Y = to),
   carry **clear** = miss.
4. On a hit: store `BestMoveFrom`/`BestMoveTo`, run `GenerateLegalMoves`, and
   **only accept the move if it appears in the legal move list**
   (`src/ai/search.s:10584`+). This is the collision safety net for the 16-bit
   key — an aliased key that yields an illegal move is silently rejected and the
   engine falls through to a normal search.
5. Final guard: `jsr EngineBookMoveAvoidsPawnAttack` — rejects a book move that
   parks a valuable piece (knight..queen; pawns/king ignored) onto a square
   attacked by a cheap pawn (`BookMoveAvoidsPawnAttack`, `src/ai/search.s:8039`).
   Carry clear → reject, search normally.
6. Accept: set `SearchUsedBook`, `jmp FinishBestMoveZero`.

### What the later step must actually add in src/
* **`LookupOpeningMove`** — the real probe routine. It is **referenced but not
  yet defined**: `src/engine/platform_c64.s:63` does `jmp LookupOpeningMove`,
  but no `LookupOpeningMove:` label exists anywhere in `src/`. The later step
  writes it: binary-search `BOOK_HASH_TABLE` for `ZobristHash`; on match load
  `from`→A, `to`→Y, `sec`, `rts`; on miss `clc`, `rts`. Put it alongside the
  other C64 platform book code so the existing `jmp` resolves.
* That is the **only** missing engine piece. `EngineLookupOpeningMove`,
  `EngineBookMoveAvoidsPawnAttack`, and `BookMoveAvoidsPawnAttack` already exist
  and are wired.

---

## 4. Graceful degradation (already the design — preserve it)

* **Test / rules-only build**: `src/engine/platform_test.s:40` stubs
  `EngineLookupOpeningMove` as `clc / rts` (always "miss"), so with no book
  linked every position falls through to a full search. The engine is strong
  without the book — the book is a latency/quality optimization on known lines,
  not a crutch.
* **C64 build with no/short book**: a miss returns `clc` → full search. A key
  collision returns a move that fails the legality check → full search. A book
  move that hangs a piece fails `EngineBookMoveAvoidsPawnAttack` → full search.
  Every failure path degrades to "search normally," never to a bad move.
* Therefore the book can be added, grown, shrunk, or omitted entirely with **no**
  correctness impact — only a behavioral/perf difference on booked positions.

---

## 5. Dataset contract (what the compile step consumes)

`tools/opening_repertoire.json`:

```jsonc
{
  "meta": {
    "clean_room": "...public theory + Stockfish only...",
    "keyed_by": "FEN (NOT engine Zobrist ...)",
    "params": { "depth": 18, "max_plies": 12, "max_loss_cp": -100, ... },
    "counts": { "positions": N, "dropped_unsound": K, "dropped_lines": [...] }
  },
  "entries": [
    { "fen": "...", "best_move_uci": "e2e4", "best_move_san": "e4",
      "eval_cp": 34, "depth": 18, "line_name": "Ruy Lopez Closed", "ply": 0 },
    ...
  ],
  "dropped": [ ... unsound nodes that were flagged + removed ... ],
  "illegal": [ ... should be empty; safety net ... ]
}
```

* `entries` is already FEN-deduped and sorted by `(ply, line_name, fen)`.
* Every `best_move_uci` is guaranteed legal in its `fen` (the producer asserts
  this and refuses to write otherwise).
* `eval_cp` is from the side-to-move POV; all kept entries are ≥ `max_loss_cp`.
* The compile step should treat `line_name`/`eval_cp`/`depth`/`ply` as
  metadata (useful for debugging / weighting) — only `fen` + `best_move_uci`
  are load-bearing for the blob.

---

## 6. Checklist for the later (src-touching) step

1. [ ] Write `tools/compile_opening_book.py` (offline; drives the bridge).
2. [ ] For each entry: load FEN into engine, `ComputeZobristHash`, read back
       16-bit key. **Never** compute Zobrist in Python.
3. [ ] Convert `best_move_uci` → engine `from`/`to` square bytes (verify the
       encoding against the bridge; don't assume).
4. [ ] Dedup on the engine key; on clash keep lower-ply/mainline entry.
5. [ ] Sort by 16-bit key; emit 4-byte records into `BOOK_HASH_TABLE`; store the
       entry count; hard-fail if > `BOOK_HASH_SIZE`.
6. [ ] Implement `LookupOpeningMove` in the C64 platform (binary search;
       A=from, Y=to, carry=found) so the existing
       `platform_c64.s` `jmp LookupOpeningMove` resolves.
7. [ ] Leave the test stub (`platform_test.s`) as `clc/rts`.
8. [ ] Verify in-emulator: a booked position returns the book move; an unbooked
       position returns `clc` and searches; confirm the hang/pawn-attack guards
       still reject bad book moves.
