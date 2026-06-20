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
    !defined(CREF_PROFILE_HOST) && !defined(CREF_PROFILE_ULTIMATE) && \
    !defined(CREF_PROFILE_REU)
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

#elif defined(CREF_PROFILE_ULTIMATE)
/* Ultimate 64 (64 MHz) / fast C64. Boots with the STOCK mos-c64 link script (no
 * banking, no linker surgery). The 64K overflow is reclaimed by dropping the
 * lazy-move-selection scratch (CREF_LAZY_SELECT 0 -> no g_score_pool, ~1.5 KB):
 * lazy-select skips sorting the move tail on a beta cutoff, a SPEED win that the
 * 64 MHz clock makes irrelevant, and eager in-place ordering is bit-exact. With
 * TT_BITS 7 (the other ~1.5 KB) the build fits and MAX_PLY rises to 8 -> d7 ~2013.
 * (A bigger TT needs the Ultimate REU / Nova XRAM -- separate follow-on.) */
#  define CREF_TT_BITS       7    /* 128-entry TT (RAM reclaimed for d7 + eager) */
#  define CREF_MAX_PLY       8    /* supports search depth <= 7 (d7 ~2013) */
#  define CREF_MAX_PATH     64
#  define CREF_HISTORY_DIM   1
#  define CREF_POOL_SIZE   768
#  define CREF_LAZY_SELECT   0    /* eager in-place ordering (bit-exact, frees RAM) */

#elif defined(CREF_PROFILE_REU)
/* C64 + RAM Expansion Unit (1764/1750/1700+). The transposition table lives in the
 * REU via $DF00 DMA (CREF_TT_XRAM + CREF_TT_REU), so the big TT costs ZERO low RAM
 * -> the stock 64K build fits with lazy ordering kept, and TT_BITS rises to 14 (16K
 * entries = 192 KB REU). Measured: ~-25% nodes at d6, access penalty ~0.15% of
 * cyc/move -> net ~-25% cyc/move (grows with depth). MAX_PLY 8 -> d7. */
#  define CREF_TT_XRAM       1
#  ifndef CREF_TT_REU            /* host oracle forces 0 -> flat shim, no $DF00 DMA */
#    define CREF_TT_REU      1
#  endif
#  ifndef CREF_TT_BITS          /* overridable for bisection (default TT14 = 192 KB) */
#    define CREF_TT_BITS    14    /* 16K-entry TT in the REU (192 KB) */
#  endif
#  define CREF_MAX_PLY       8    /* d7 ~2013 */
#  define CREF_MAX_PATH     64
#  define CREF_HISTORY_DIM   1
#  define CREF_POOL_SIZE   768

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
#  ifndef CREF_TT_BITS
#    define CREF_TT_BITS     8    /* 256-entry TT (cc65 int is 16-bit; 1<<16 wraps) */
#  endif
#  ifndef CREF_MAX_PLY          /* overridable for bug-2 bisection */
#    define CREF_MAX_PLY     7    /* supports search depth <= 6 */
#  endif
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

/* Lazy move selection (negamax): keep per-node ordering scores in a pool parallel
 * to g_pool so the next-best move is picked on demand and the tail is never sorted
 * after a beta cutoff. A speed win that costs ~POOL_SIZE*2 bytes of RAM. Profiles
 * that can't spare it (or don't need it -- fast clocks) set CREF_LAZY_SELECT 0 to
 * fall back to eager in-place ordering (bit-exact, just sorts the whole list). */
#ifndef CREF_LAZY_SELECT
#  define CREF_LAZY_SELECT 1
#endif

/* TT off-address-space backing (Nova XRAM / C64 REU). Default off: the TT is a flat
 * in-RAM array. A profile sets CREF_TT_XRAM (copy entries in/out) and CREF_TT_REU
 * (the $DF00 DMA accessor) to host a >64K TT. */
#ifndef CREF_TT_XRAM
#  define CREF_TT_XRAM 0
#endif
#ifndef CREF_TT_REU
#  define CREF_TT_REU 0
#endif

#endif /* CREF_MEMCFG_H */
