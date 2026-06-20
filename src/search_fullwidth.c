/* search_fullwidth.c -- full-width search plugin (#1).
 *
 * The default search on every host except (eventually) the stock 1 MHz C64: a
 * full-width alpha-beta + quiescence search that examines every legal move. This is
 * the verifiable reference engine (PERFT-exact movegen, node-exact golden, bit-exact
 * host<->chip). It is just the shared engine in search_core.inc with the selective
 * move-expansion policy left off. See the pluggable-search design doc.
 */
#include "search_core.inc"
