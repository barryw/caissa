/* memcfg.h -- search/movegen memory-profile knobs, one place per target.
 *
 * The search keeps several RAM-resident tables (transposition table, per-ply move
 * banks, killer/history tables, repetition stack). Their sizes must match the
 * target's available memory. Previously these were bound directly to the
 * `__mos__ || __CC65__` flag = ONE tight 64K profile for every bare-metal target.
 * That is wrong for a machine with more memory, so the knobs live here and are
 * selected by an explicit profile.
 *
 * Profiles
 * --------
 *   HOST -- 64-bit dev host. Generous everything (strong measurement, big TT).
 *   C64  -- stock 64K Commodore 64. The tight, PROVEN shipping config. This is
 *           also what the mos-sim measurement image and the cref_mos host proxy
 *           use, so `speed_gate.sh` measures exactly the C64 ship target.
 *   NOVA -- the e6502 "Nova" board (~/Git/e6502): custom 6502, 512 KB XRAM.
 *           CAUTION: Nova's *lower 64K* free RAM is only ~39.7 KB ($0280-$9FFF;
 *           I/O at $A000-$BFFF, ROM at $C000-$FFFF) -- TIGHTER than the C64, not
 *           roomier. The 512 KB XRAM is BANKED/WINDOWED (4x256B windows at
 *           $BC00-$BFFF via XmcWin* regs, or 64K banks via XMC_BANK $BA0C), not
 *           flat. So bumping a table here only helps once that table is physically
 *           placed in XRAM by a Nova linker script + windowed accessors. Until
 *           that exists, NOVA mirrors C64 so a Nova build still fits the lower 64K.
 *           Bump the XRAM-resident knobs (and ONLY those) when the placement lands.
 *
 * Selection (build-time): pass -DCREF_PROFILE_NOVA, -DCREF_PROFILE_C64, or
 * -DCREF_PROFILE_HOST to force a profile. Otherwise: a bare 6502 target
 * (__mos__/__CC65__) defaults to C64 (the safe small floor); a hosted build
 * defaults to HOST.
 */
#ifndef CREF_MEMCFG_H
#define CREF_MEMCFG_H

#if !defined(CREF_PROFILE_NOVA) && !defined(CREF_PROFILE_C64) && \
    !defined(CREF_PROFILE_HOST)
#  if defined(__mos__) || defined(__CC65__)
#    define CREF_PROFILE_C64 1
#  else
#    define CREF_PROFILE_HOST 1
#  endif
#endif

/* ---- per-profile knobs --------------------------------------------------- */
#if defined(CREF_PROFILE_HOST)
#  define CREF_TT_BITS      16    /* 65536-entry transposition table */
#  define CREF_MAX_PLY      48    /* killer banks + ply bound */
#  define CREF_MAX_PATH   1024    /* repetition stack (full game history) */
#  define CREF_HISTORY_DIM  64    /* full [stm][64][64] butterfly history */
#  define CREF_POOL_SIZE  8192    /* shared move pool (Move entries) */

#elif defined(CREF_PROFILE_NOVA)
/* Mirrors C64 for now -- see the XRAM caveat above. The larger values these will
 * take once XRAM placement exists are left commented as the target:
 *   TT_BITS 16, MAX_PLY 24+, MAX_PATH 256+, HISTORY_DIM 64  (all XRAM-resident). */
#  define CREF_TT_BITS       8
#  define CREF_MAX_PLY       7
#  define CREF_MAX_PATH     64
#  define CREF_HISTORY_DIM   1
#  define CREF_POOL_SIZE  1024

#else  /* CREF_PROFILE_C64 (and the default for any bare 6502 target) */
#  define CREF_TT_BITS       8    /* 256-entry TT (cc65 int is 16-bit; 1<<16 wraps) */
#  define CREF_MAX_PLY       7    /* supports search depth <= 6 */
#  define CREF_MAX_PATH     64    /* search-path-only repetition stack */
#  define CREF_HISTORY_DIM   1    /* 16 KB butterfly table does not fit -> stub off */
/* Shared move pool: replaces the old [MAX_PLY][256] negamax banks + [Q+1][256]
 * quiescence banks (~15 KB). It packs the ACTUAL per-node move counts (~35) along
 * the live path. MEASURED peak occupancy is 333 at d6 / 380 at d7 (kiwipete), and
 * a frame generates only when >= CREF_MAX_MOVES headroom remains, so 768 entries
 * (3 KB) keeps the static-eval-leaf fallback from ever firing in normal play
 * (fallback triggers above 768-256=512; peak is 380). Bit-exact in all tested
 * cases; the fallback is a safety net that degrades, never corrupts. */
#  define CREF_POOL_SIZE   768
#endif

/* ---- knobs that are the same on every profile ---------------------------- */
#define CREF_MAX_MOVES         256   /* worst-case legal move count is ~218 */
#define CREF_MAX_QUIESCE_DEPTH   6

#endif /* CREF_MEMCFG_H */
