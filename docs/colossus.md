# Colossus 4 Raw Runner Notes

These tools run Colossus Chess 4 from a dumped C64 runtime image through `sim6502`, avoiding the VICE UI loop for repeatable engine testing.

## Useful Commands

Extract PRGs from the D64:

```sh
python3 tools/extract_colossus_disk.py
```

Dump a fresh VICE runtime image:

```sh
python3 tools/dump_colossus_runtime.py
python3 tools/dump_colossus_runtime.py --bank cpu --tag ready_cpu --no-boot
```

Run Colossus raw from the ready image:

```sh
python3 tools/run_colossus_raw.py --profile default --moves e2e4
python3 tools/run_colossus_raw.py --profile easy-match --moves e2e4
python3 tools/run_colossus_raw.py --profile no-book --moves e2e4
python3 tools/run_colossus_raw.py --profile hard --moves e2e4
python3 tools/run_colossus_raw.py --profile beast --moves e2e4
python3 tools/run_colossus_raw.py --profile match --moves e2e4 b1c3
```

Run the local engine against raw Colossus:

```sh
python3 tools/run_colossus_match.py --colossus-backend raw --colossus-profile default --max-plies 4
python3 tools/run_colossus_match.py --colossus-backend raw --colossus-profile match --max-plies 20
python3 tools/run_colossus_match.py --engine-color black --colossus-backend raw --colossus-profile hard --colossus-raw-cycles 5000000000 --max-plies 12
```

Raw matches enable the local engine ponder cache by default. The raw runner
samples Colossus best/current-line text while Colossus is still thinking and
emits JSON progress events for each changed candidate line. The match harness
pre-searches the first legal Colossus reply from those samples, replaces the
cache when Colossus changes its displayed line, and reuses the cached engine
move if Colossus actually plays it. Use `--no-ponder` to disable this path while
debugging baseline search behavior. Match JSON includes a `ponder` block with
live-sample, candidate, search, cache, hit/miss, replacement, and cycle counters.
Raw runner JSON also includes `bestLineSamples`.

Live ponder uses a tiered timeout to avoid spending full engine-search budgets
on transient Colossus lines. Shallow candidates use `--ponder-timeout-cycles`
(`5M` by default). If the same candidate survives to
`--ponder-deep-min-lookahead` (`2` by default), it can retry with
`--ponder-deep-timeout-cycles` (`100M` by default). This keeps cheap likely
hits hot while bounding the cost of wrong early guesses.

Use Beast's cores by running independent opening lanes in parallel:

```sh
python3 tools/run_colossus_parallel.py --profile beast --workers 32 --max-plies 20
python3 tools/run_colossus_parallel.py --profile hard --workers 8 --colossus-raw-cycles 5000000000 --max-plies 10 --analyze-blunders --valid-blunders-only --stockfish-depth 8 --multipv 3 --threshold 20
python3 tools/run_colossus_parallel.py --reuse-existing --output-dir build/colossus_parallel --analyze-blunders --valid-blunders-only --stockfish-depth 8 --multipv 3 --threshold 20
```

One Colossus move is a serial emulated 6502 timeline, so a single game uses one core. The parallel launcher runs separate raw Colossus states from different forced white openings and writes one PGN/JSON pair per lane plus `summary.json`.
`--analyze-blunders` runs the Stockfish extractor per lane and writes a merged
`blunders.json` for direct ingestion into `tools/colossus_blunders.json`.
`--reuse-existing` skips match execution and re-runs extraction/merging over an
existing output directory.
Each lane summary includes its match `ponder` counters. The launcher also prints
aggregate live samples, searches, cached replies, hits, misses, replacements,
repeat skips, hit cycles, invested cycles, and aborted timeout cycles.
`summary.json` separates clean chess data from harness failures by execution
status, termination class, and outcome. `colossus-forfeit-time` and
`colossus-illegal-move:*` are classified as `opponent-failure`, never
completed games, and are skipped by blunder extraction. Use
`--valid-blunders-only` for tuning corpora so lane timeouts and other non-clean
lanes do not get merged with real engine mistakes. Legal timeout partials are
also skipped unless `--analyze-timeout-partials` is explicitly supplied.

## Runner Profiles

- `default`: stock dumped state. This often hits Colossus opening book immediately.
- `easy-match`: stock book/time settings with prediction disabled for automated engine-vs-engine matches.
- `no-book`: sets `$B407=0`, forcing real search instead of book lookup, and `$B49B=0` so Colossus does not predict/assume the opponent's move.
- `hard`: disables book/prediction, sets line-depth UI state high, and slows the emulated TOD clock 10x so Colossus gets a larger raw search budget.
- `hard-30m`: disables book/prediction, sets line-depth UI state high, uses a normal TOD clock, and caps each Colossus reply at about 30 real C64 minutes (`1.8B` cycles). This is useful for one-move probes, but a cycle cap can still end without a committed move.
- `hard-move-1m` / `hard-move-5m`: disables book/prediction, sets line-depth UI state high, and patches Colossus's own normal move-time state so it should commit after about one or five C64 minutes per move.
- `beast`: same strength settings as `hard`, but with no raw cycle cap. The runner stops when Colossus actually replies.
- `match`: keeps the opening book enabled, disables prediction, slows the emulated TOD clock 10x, and has no raw cycle cap. This is the preferred profile for engine-vs-engine games because Colossus hard play normally includes its book, while prediction mode can desynchronize automated input.
- `match-move-1m` / `match-move-5m`: keeps the opening book enabled, disables prediction, sets line-depth UI state high, and uses Colossus's own normal move-time state. **Known bad for full games:** in a 12-lane beast batch (2026-06-11) and an earlier local smoke, Colossus never committed moves under these profiles (every lane hit the force-move safety stop with zero completed games). Until the move-time pokes are re-verified, prefer `match` with a generous `--colossus-raw-force-move-after-seconds` for finished engine-vs-engine data.
- `correspondence`: disables book and sets mode `$B465=5`; this may not return a move within normal cycle limits, but it is useful for watching deeper current/best-line search.

Use `--cycles 0` for any profile to remove the raw cycle cap. You can add arbitrary RAM patches with repeated `--poke ADDRESS=VALUE`, for example:

```sh
python3 tools/run_colossus_raw.py --profile no-book --moves e2e4 --poke 0xb413=0x0f
```

For full automated games, prefer Colossus's own move-time profiles over a host
wall cutoff:

```sh
python3 tools/run_colossus_parallel.py --profile match-move-1m --workers 12 --max-plies 80 --analyze-blunders --valid-blunders-only
```

`--colossus-raw-force-move-after-seconds` is only a safety stop to keep lanes
from hanging. If Colossus fails to commit a legal move before that host-wall
budget, the lane is marked `opponent-failure` with result `*`; it is not clean
chess data and is not used for tuning.

## Verified Control Bytes

- `$B407`: opening book enabled flag. `1` is enabled, `0` disables the book.
- `$B413`: UI "Line depth" value. Default is `2`, valid range appears to be `1..15`; it affects Colossus state but does not override the active time limiter by itself.
- `$B465`: game mode. Default is `2`; `5` is correspondence mode and can run without returning inside normal raw cycle caps.
- `$B466/$B467`: mode/time-control menu values. These are real menu variables, but changing them did not alter the first-move raw search budget in the tested path.
- `$B469/$B46E`: normal-mode move-time bytes. `02` produced about one C64 minute on `e2e4`; `0A` produced about five C64 minutes. `$B468/$B46A/$B46F` are kept at `0` in the self-timed profiles.
- `$B49B`: prediction enabled flag. Default is `1`; set to `0` for engine-vs-engine matches. If left enabled, Colossus may display `Assumed:` and start calculating against its predicted opponent move instead of the move our engine actually supplied.

## Board/Move State Notes

Colossus uses a mailbox-style board at `$A700` while it is thinking after an
entered move, but this is not a reliable authoritative game board after
Colossus has replied. It can retain search/current-line state. Do not infer
completed Colossus replies from `$A700` alone.

- `origin = 13`
- `stride = 10`
- `address = $A700 + 13 + (8 - rank) * 10 + file`

Piece encoding:

- `00`: empty
- `01`: offboard border
- black: `02 p`, `03 n`, `04 b`, `05 r`, `06 q`, `07 k`
- white: `FE P`, `FD N`, `FC B`, `FB R`, `FA Q`, `F9 K`

For VICE-backed engine-vs-engine matches, `$B49B` must be patched to `0` to
disable Colossus's prediction mode. The harness does this automatically. With
prediction enabled, Colossus may display `Assumed:` and calculate against a
guessed opponent move, which desynchronizes automation.

Raw black-side matches start Colossus as White by injecting the shifted `G`
command byte (`--input-bytes c7`) from the ready image. The raw runner accepts
`--input-bytes` for this path because matrix text injection did not reliably
trigger Colossus's `Go` command.

## Current Baseline

From `e2e4`:

- `default`: `f7f6`, lookahead `1`, `26` positions.
- `no-book`: `f7f6`, lookahead `2`, about `156k` positions.
- `hard`: `f7f6`, lookahead `2`, about `1.5M` positions.
- `beast`: `f7f6`, lookahead `2`, about `1.5M` positions, no cycle cap; local run measured about `38s` wall time and `89M` simulated cycles/sec.

Raw match smoke tests:

- `default`, four plies: `1. e4 f6 2. Nc3 e5`.
- `beast`, two plies: `1. e4 f6`, with about `1.5M` Colossus positions searched and no cycle cap.
- `match`, four plies: `1. e4 f6 2. d4 e5`, with Colossus's second move
  searching about `1.6M` positions and `3.4B` emulated cycles in about `39s`
  wall time on the local machine.
- `match`, three four-ply live-ponder lanes (`engine`, `e2e4`, `d2d4`) produced
  no new blunders at Stockfish depth 8 / threshold 20. The live sampler saw `57`
  line samples, ran `29` ponder searches, cached `12` replies, replaced the cache
  `6` times, skipped `23` duplicate shallow candidates, and hit all `6` Colossus
  replies. It invested about `96.7M` completed C64 search cycles, aborted about
  `85M` timeout-capped speculative cycles, and reused about `91.4M` cached
  cycles.
- A twelve-lane, twelve-ply uncapped `match` batch was too slow to finish
  interactively, but the completed `e2e3` lane exposed a root shortcut failure:
  after `1. e3 e5 2. Nc3 d5 3. d4 exd4 4. Qxd4 Qf6`, the engine shortcut-played
  `5. Qxf6` while Stockfish preferred `5. Nd5`. Root major-capture and
  winning-capture shortcuts now defer queen-for-queen trades to full search.
  On the extracted four-position lane corpus, the worst Stockfish loss dropped
  from `197cp` to `52cp`, and the queen-trade position changed from `Qxf6` to
  `Qd5` with a `35cp` loss at Stockfish depth 12.
- A current-engine strict quiet-opening batch
  (`e2e3`, `c2c4`, `b1c3`, `c2c3`, eight plies, Stockfish depth 8) produced four
  clean max-ply lanes and several center/queen-response misses: delayed `d4`,
  missed `Nxe4`, queen recapture before pawn recapture, and flank drift under
  queen/bishop pressure. These are now treated as a tuning corpus, not new
  engine book rows. The root scorer carries the generic fixes: challenge enemy
  d/e center pawns with the d-pawn break, treat fourth-rank pawns as urgent
  capture targets, prefer pawn recaptures over early queen recaptures, and allow
  central pawn cover under queen pressure while still rejecting quiet flank
  drift. The center-break rule is deliberately scoped to the d-pawn break; when
  the d-pawn is already committed, e-pawn pushes stay in full search unless
  another generic tactical rule justifies them.

Tuning rule: new Colossus failures should become regression positions and
generic engine rules. Do not add exact Colossus/FEN survival rows unless the
position is an immediate tactical emergency that cannot be represented by a
compact class of positions.

The repeated `f7f6` response appears to be Colossus evaluation behavior for this position, not just a raw-runner input bug: disabling book and expanding the clock budget increases search work substantially while preserving the chosen move.

`1. e4 f6 2. Nc3` is a known bad no-book search lane: with the book disabled, Colossus accepts `Nc3`, displays `Current line e8f7`, and may fail to commit a reply even after billions of raw cycles. With the book enabled and prediction disabled, the same line replies quickly with `2...e5`.
