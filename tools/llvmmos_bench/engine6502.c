/* engine6502.c -- 6502-side "bestmove" driver for the NATIVE C chess engine,
 * compiled+linked with native/{board,movegen,eval,search}.c via llvm-mos
 * (mos-sim target) and run inside tools/fast6502_bridge/cpu6502.
 *
 * GOAL: prove the native engine computes a best move on a real (cycle-exact)
 * 6502, move-for-move identical to host `./native/cref bestmove FEN DEPTH`.
 *
 * ===========================================================================
 *  MEMORY ABI  (symbol addresses come from the linker map -> see NOTES.md)
 * ===========================================================================
 *  Inputs  (host writes these into RAM after crt0 has zeroed .bss):
 *      char          g_fen[100]   FEN C-string (NUL-terminated)
 *      unsigned char g_depth      search depth (1..8)
 *  Outputs (host reads after g_done==1):
 *      unsigned char g_from       chosen move FROM square (0x88 encoding)
 *      unsigned char g_to         chosen move TO   square (0x88 encoding)
 *      unsigned char g_promo      promotion piece TYPE (PT_KNIGHT..PT_QUEEN), 0 = none
 *      signed   int  g_score      search score (white-relative cp, stm-POV)
 *      unsigned char g_done       set to 1 when the search has finished
 *      unsigned char g_status     0 = ok, 1 = FEN parse error
 *
 *  HANDSHAKE (so the host can inject the FEN AFTER crt0 zeroes .bss):
 *    main() writes SIM_READY to the sim putchar register, then BUSY-WAITS on the
 *    global `g_go` byte. The host loop:
 *      1. load image, run from reset until putchar register == SIM_READY,
 *      2. inject g_fen / g_depth, set g_go = 1,
 *      3. resume until g_done == 1 (and the sim exit register is written),
 *      4. read g_from / g_to / g_promo / g_score.
 *    g_go lives in .bss (zeroed by crt0), so the busy-wait is entered cleanly
 *    every run; the host flips it only after READY, which is after bss-zeroing.
 */
#include <stdint.h>
#include "../../native/board.h"
#include "../../native/search.h"
#include "../../native/eval.h"

/* ---- the ABI globals (all extern-visible; addresses dumped to the .map) ---- */
volatile char          g_fen[100];
volatile unsigned char g_depth  = 4;
volatile unsigned char g_from   = 0xFF;
volatile unsigned char g_to     = 0xFF;
volatile unsigned char g_promo  = 0;
volatile int           g_score  = 0;
volatile unsigned char g_done   = 0;
volatile unsigned char g_status = 0;
volatile unsigned char g_go     = 0;   /* host sets to 1 to start the search */
volatile unsigned long g_nodes  = 0;   /* diagnostics: search node count */
volatile unsigned long g_qnodes = 0;   /* diagnostics: quiescence node count */

/* The board is large-ish; keep it off the C stack (static .bss). */
static Board g_board;

/* Sim I/O register block at 0xFFF0 (mos-platform/sim/sim-io.h):
 * clock[4], unclaimed, getchar, input_eof, abort, exit, putchar. */
struct sim_reg {
    uint8_t clock[4];
    uint8_t unclaimed;
    char    getchar;
    char    input_eof;
    uint8_t abort;
    int8_t  exit;
    uint8_t putchar;
};
#define SIM_REG ((volatile struct sim_reg *)0xFFF0)

#define SIM_READY 0xA5   /* main() emits this to putchar when ready for input */

/* Copy the volatile FEN buffer into a plain char[] for board_from_fen. */
static void load_fen(char *dst) {
    int i;
    for (i = 0; i < 99 && g_fen[i]; i++) dst[i] = g_fen[i];
    dst[i] = 0;
}

/* The entry the host drives: parse g_fen, search to g_depth, publish the move. */
void bench_bestmove(void) {
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

    /* Seed the repetition table with the root position's hash, EXACTLY like the
     * host driver (native/cref cmd_bestmove): pass hist = { root_hash }, len 1.
     * This is load-bearing for move-for-move agreement -- without the root in the
     * repetition stack, lines that return to the root are not scored as draws, so
     * the search occasionally prefers a different move than host cref. */
    hist[0] = g_board.hash;
    best = search_bestmove(&g_board, g_depth, hist, 1, &si);

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
    /* Signal the host: crt0 done, .bss zeroed, ready for FEN injection. */
    SIM_REG->putchar = SIM_READY;

    /* Busy-wait until the host has written the FEN+depth and flipped g_go. */
    while (!g_go) { /* spin */ }

    bench_bestmove();

    /* main returning calls _Exit, which writes the sim exit register -> the
     * host run-loop stops. g_done is already 1. */
    return 0;
}
