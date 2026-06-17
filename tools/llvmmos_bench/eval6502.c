/* eval6502.c -- 6502-side "eval" driver for the NATIVE C chess engine, compiled
 * + linked with native/{board,movegen,eval}.c via llvm-mos (mos-sim target) and
 * run inside tools/fast6502_bridge/cpu6502.
 *
 * PHASE 1 of hand-asm'ing eval_full: this driver lets the host runner prove the
 * existing C eval_full(), compiled to 6502, is BIT-IDENTICAL to the python oracle
 * (tools/texel_eval.py eval_full) over the entire 22157-position texel corpus.
 * It is the bit-exact safety net the future asm eval is held to.
 *
 * Mirrors caissa.c's ABI/handshake exactly, except the work function calls
 * eval_full instead of search, and publishes a single result: g_score = eval.
 *
 * ===========================================================================
 *  MEMORY ABI  (symbol addresses come from the linker map -> see NOTES.md)
 * ===========================================================================
 *  Inputs  (host writes these into RAM after crt0 has zeroed .bss):
 *      char          g_fen[100]   FEN C-string (NUL-terminated)
 *  Outputs (host reads after g_done==1):
 *      signed   int  g_score      eval_full() result (WHITE-POV centipawns)
 *      unsigned char g_done       set to 1 when the eval has finished
 *      unsigned char g_status     0 = ok, 1 = FEN parse error
 *
 *  HANDSHAKE (so the host can inject the FEN AFTER crt0 zeroes .bss):
 *    main() writes SIM_READY to the sim putchar register, then BUSY-WAITS on the
 *    global `g_go` byte. The host loop:
 *      1. load image, run from reset until putchar register == SIM_READY,
 *      2. inject g_fen, set g_go = 1,
 *      3. resume until g_done == 1 (and the sim exit register is written),
 *      4. read g_score / g_status.
 *    g_go lives in .bss (zeroed by crt0), so the busy-wait is entered cleanly
 *    every run; the host flips it only after READY, which is after bss-zeroing.
 */
#include <stdint.h>
#include "../../src/board.h"
#include "../../src/eval.h"

/* ---- the ABI globals (all extern-visible; addresses dumped to the .map) ---- */
volatile char          g_fen[100];
volatile int           g_score  = 0;   /* output: eval_full() (WHITE-POV cp) */
volatile unsigned char g_done   = 0;
volatile unsigned char g_status = 0;
volatile unsigned char g_go     = 0;   /* host sets to 1 to start the eval */

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

/* The entry the host drives: parse g_fen, evaluate, publish the score. */
void bench_eval(void) {
    char fen[100];

    eval_reset_weights();

    load_fen(fen);
    if (board_from_fen(&g_board, fen) != 0) {
        g_status = 1;
        g_done = 1;
        return;
    }

    /* eval_full reads the seeded acc_mat/acc_phase/acc_egdiff from the board;
     * eval_acc_init does the full rescan that seeds them. REQUIRED -- without it
     * eval_full reads stale/zero accumulators and produces wrong scores. */
    eval_acc_init(&g_board);

    g_score  = eval_full(&g_board);   /* WHITE-POV -- do NOT negate */
    g_status = 0;
    g_done   = 1;
}

int main(void) {
    /* Signal the host: crt0 done, .bss zeroed, ready for FEN injection. */
    SIM_REG->putchar = SIM_READY;

    /* Busy-wait until the host has written the FEN and flipped g_go. */
    while (!g_go) { /* spin */ }

    bench_eval();

    /* main returning calls _Exit, which writes the sim exit register -> the
     * host run-loop stops. g_done is already 1. */
    return 0;
}
