/* caissa_server.c -- persistent headless C64 "bestmove server" for the Caissa
 * engine, built with mos-c64-clang (see tools/build_caissa_server.sh) and driven
 * inside a real (headless) VICE x64sc by tools/vice_caissa.py.
 *
 * Unlike tools/llvmmos_bench/caissa.c (the one-shot mos-sim fidelity driver, which
 * talks to the sim's 0xFFF0 I/O registers), this is a C64 .prg that BOOTS ONCE and
 * then LOOPS FOREVER serving one move per request. VICE boot is ~18s, so a match
 * must never re-boot per move; the driver pokes a new FEN into RAM and reads the
 * reply over the x64sc monitor between moves.
 *
 * ===========================================================================
 *  MEMORY ABI  (symbol addresses come from the linker map; vice_caissa.py reads
 *  caissa_server.map and pokes/peeks these globals over the monitor)
 * ===========================================================================
 *  Inputs  (driver writes these into RAM):
 *      char          g_fen[100]   FEN C-string (NUL-terminated)
 *      unsigned char g_depth      search depth (1..8)
 *  Outputs (driver reads after g_done==1):
 *      unsigned char g_from       chosen move FROM square (0x88 encoding)
 *      unsigned char g_to         chosen move TO   square (0x88 encoding)
 *      unsigned char g_promo      promotion piece TYPE (PT_KNIGHT..PT_QUEEN), 0=none
 *      signed   int  g_score      search score (stm-POV centipawns)
 *      unsigned long g_nodes      search node count   (per-ply instrumentation)
 *      unsigned long g_qnodes     quiescence node count
 *      unsigned char g_status     0 = ok, 1 = FEN parse error
 *      unsigned char g_done       set to 1 when the search has finished
 *  Liveness:
 *      unsigned char g_ready      set to 1 once, after boot, before the serve loop
 *
 *  HANDSHAKE (pure RAM; the driver single-steps the monitor, the 6502 runs free):
 *    1. boot the .prg; wait until g_ready == 1.
 *    2. per move: write g_fen + g_depth; set g_done = 0; set g_go = 1 (LAST).
 *    3. poll until g_done == 1; read g_from/g_to/g_promo/g_score/g_nodes/g_status.
 *    The server clears g_go the instant it starts a search and writes g_done = 1
 *    only AFTER every result field is published, so a g_done==1 read is coherent.
 */
#include <stdint.h>
#include <stdio.h>
#include "../../src/board.h"
#include "../../src/search.h"
#include "../../src/eval.h"

/* ---- the ABI globals (extern-visible; addresses dumped to the .map) ---- */
volatile char          g_fen[100];
volatile unsigned char g_depth  = 4;
volatile unsigned char g_go     = 0;   /* driver sets to 1 to start a search */
volatile unsigned char g_done   = 0;   /* server sets to 1 when finished */
volatile unsigned char g_ready  = 0;   /* server sets to 1 once, after boot */
volatile unsigned char g_from   = 0xFF;
volatile unsigned char g_to     = 0xFF;
volatile unsigned char g_promo  = 0;
volatile int           g_score  = 0;
volatile unsigned char g_status = 0;
volatile unsigned long g_nodes  = 0;
volatile unsigned long g_qnodes = 0;

/* The board is large-ish; keep it off the C stack (static .bss). */
static Board g_board;

/* Copy the volatile FEN buffer into a plain char[] for board_from_fen. */
static void load_fen(char *dst) {
    int i;
    for (i = 0; i < 99 && g_fen[i]; i++) dst[i] = g_fen[i];
    dst[i] = 0;
}

/* Parse g_fen, search to g_depth, publish the move. Identical search setup to
 * the validated fidelity driver (tools/llvmmos_bench/caissa.c) so the server's
 * moves match host `cref bestmove FEN DEPTH` exactly. */
static void serve_one(void) {
    char fen[100];
    SearchInfo si;
    Move best;
    hash_t hist[1];

    eval_reset_weights();
    search_reset_config();

    load_fen(fen);
    if (board_from_fen(&g_board, fen) != 0) {
        g_status = 1;
        g_done = 1;
        return;
    }

    /* Seed the repetition table with the root hash, EXACTLY like host cref
     * (cmd_bestmove): hist = { root_hash }, len 1. Load-bearing for move-for-move
     * agreement -- without the root in the stack, lines that return to the root
     * are not scored as draws and the search can prefer a different move. */
    hist[0] = g_board.hash;
    best = search_bestmove(&g_board, g_depth, hist, 1, &si);

    /* Publish every result field BEFORE flipping g_done -- the driver treats a
     * g_done==1 read as "all fields coherent". */
    g_from   = best.from;
    g_to     = best.to;
    g_promo  = best.promo;
    g_score  = si.score;
    g_nodes  = si.nodes;
    g_qnodes = si.qnodes;
    g_status = 0;
    g_done   = 1;
}

int main(void) {
    /* One-line banner so a human watching the (headless) VICE screen, or a
     * screen-scrape, can confirm the server booted. */
    printf("caissa bestmove server ready\n");

    /* Announce liveness to the driver, then serve forever. */
    g_ready = 1;
    for (;;) {
        while (!g_go) { /* spin until the driver hands us a position */ }
        g_go = 0;       /* consume the request immediately */
        g_done = 0;     /* invalidate the previous reply before recomputing */
        serve_one();    /* publishes results, sets g_done = 1 */
    }
}
