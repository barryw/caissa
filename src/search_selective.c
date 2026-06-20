/* search_selective.c -- selective search plugin (#2), for the stock 1 MHz C64.
 *
 * Colossus-style plausibility forward-pruning: at each interior node, search only the
 * top-K most plausible moves (a depth-narrowing width schedule), hard-prune the rest,
 * and let forcing moves (checks, captures, 7th-rank pushes) bypass the cap and extend.
 * The point is narrow-and-deep instead of wide-and-shallow, to reach useful depth on a
 * machine that cannot afford full width. See the pluggable-search design doc for the
 * design, the accepted risk (a quiet winning move can be pruned), and the verification
 * contract (safety invariants + tactical suites + SPRT-beats-full-width + quiet-win
 * suite -- selective is NOT node-exact, so it gets a different bar than full-width).
 *
 * PHASE 1 (this commit): SCAFFOLD ONLY. No selectivity is implemented yet, so this TU
 * compiles the shared engine identically to search_fullwidth.c -- a bit-exact checkpoint
 * proving the plugin socket + conditional link work before any heuristic changes the
 * search tree. The width schedule / forcing extensions land in Phase 2 inside
 * search_core.inc, guarded by CREF_SEARCH_SELECTIVE.
 */
/* CREF_SEARCH_SELECTIVE is defined build-wide via -DCREF_SEARCH_SELECTIVE=1 (set by
 * the Makefile / build scripts when SEARCH=selective), NOT with a #define here: a
 * later task adds fields to SearchConfig (src/search.h), and EVERY TU in a selective
 * build must see the same struct for ABI consistency. Full-width builds leave it
 * undefined -> SearchConfig unchanged -> byte-identical reference preserved. */
#include "search_core.inc"
