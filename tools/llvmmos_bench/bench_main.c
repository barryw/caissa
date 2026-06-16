/* bench_main.c -- llvm-mos feasibility benchmark for the native chess eval.
 *
 * Sets up a fixed mid-game position in the engine's 0x88 Board representation
 * and calls eval_material_pst() (the HOT lazy eval) N times in a loop. Built
 * and linked with llvm-mos for the `mos-sim` platform, then run inside the
 * tools/fast6502_bridge cpu6502 core to count cycles.
 *
 * The result of every eval is XOR-accumulated into `sink` and emitted via the
 * sim putchar register so the optimizer cannot dead-strip the loop. The harness
 * reads the cycle counter, so timing is independent of what we print.
 *
 * Board layout (board.h, FROZEN): index = (7-rank)*16 + file, a8=0, h1=119;
 * offboard = (idx & 0x88); piece = type | 0x80(white); empty = 0.
 *
 * No FEN parser / no board.c dependency: the mid-game position is encoded as a
 * compile-time square table so this TU links against eval.c alone.
 */
#include <stdint.h>
#include "../../native/eval.h"   /* Board, eval_material_pst, eval_full, g_w */

/* Mid-game position (a real opposite-side-castled middlegame, ~26 pieces):
 *   r1bq1rk1/pp2bppp/2n1pn2/2pp4/3P1B2/2NBPN2/PPP2PPP/R2Q1RK1 w
 * Encoded rank8..rank1, file a..h. White = +0x80.
 * Piece types: P=1 N=2 B=3 R=4 Q=5 K=6.                                      */

#define WP(t) ((t) | 0x80)
#define BP(t) (t)
enum { P=1, N=2, B=3, R=4, Q=5, K=6 };

/* Build the 0x88 board at startup. Done in C (runs on the 6502) so the cost is
 * outside the timed region (we time only the eval loop). */
static Board g_board;

static void setup_board(void) {
    int rank, file, i;
    /* 8x8 piece grid, row 0 = rank 8 ... row 7 = rank 1, col 0 = file a. */
    static const uint8_t grid[8][8] = {
        /* rank 8 */ { R,0,BP(B),Q,0,R,K,0 },
        /* rank 7 */ { P,P,0,0,B,P,P,P },
        /* rank 6 */ { 0,0,N,0,P,N,0,0 },
        /* rank 5 */ { 0,0,P,P,0,0,0,0 },
        /* rank 4 */ { 0,0,0,WP(P),0,WP(B),0,0 },
        /* rank 3 */ { 0,0,WP(N),WP(B),WP(P),WP(N),0,0 },
        /* rank 2 */ { WP(P),WP(P),WP(P),0,0,WP(P),WP(P),WP(P) },
        /* rank 1 */ { WP(R),0,0,WP(Q),0,WP(R),WP(K),0 },
    };
    for (i = 0; i < 128; i++) g_board.sq[i] = 0;
    for (rank = 0; rank < 8; rank++) {
        for (file = 0; file < 8; file++) {
            int idx = rank * 16 + file;   /* row 0 (rank8) -> idx 0 */
            g_board.sq[idx] = grid[rank][file];
        }
    }
    /* fix the black bishop on c8 that the WP/BP macro confusion above leaves:
     * grid already used BP(B) for c8; nothing more to do. */
    g_board.wtm = 1;
    /* king squares: white Kg1, black Kg8.  g1 = rank1,file g -> idx 7*16+6=118.
       g8 = rank8,file g -> idx 0*16+6 = 6. */
    g_board.wk = 7 * 16 + 6;   /* 118 */
    g_board.bk = 0 * 16 + 6;   /* 6   */
    g_board.castle = 0;
    g_board.ep = -1;
    g_board.halfmove = 0;
    g_board.fullmove = 1;
    g_board.hash = 0;
}

/* Sim I/O register block lives at 0xFFF0 (mos-platform/sim/sim-io.h). */
struct sim_reg {
    uint8_t clock[4];
    uint8_t unclaimed;
    char getchar;
    char input_eof;
    uint8_t abort;
    int8_t exit;
    uint8_t putchar;
};
#define SIM_REG ((volatile struct sim_reg *)0xFFF0)

#ifndef BENCH_N
#define BENCH_N 100
#endif

/* Which eval to benchmark: 0 = eval_material_pst (lazy/hot), 1 = eval_full. */
#ifndef BENCH_FULL
#define BENCH_FULL 0
#endif

int main(void) {
    int i;
    int16_t sink = 0;
    eval_reset_weights();
    setup_board();

    for (i = 0; i < BENCH_N; i++) {
        /* Perturb the position every iteration so the eval call is NOT
         * loop-invariant and cannot be hoisted/CSE'd out of the loop. We drop a
         * white pawn onto a normally-empty central square (e4 = rank4,file e =
         * idx 4*16+4 = 68), cycling its presence so consecutive evals differ.
         * This is real work the eval must redo each call. */
        g_board.sq[68] = (uint8_t)((i & 1) ? WP(P) : 0);
#if BENCH_FULL
        sink += (int16_t)eval_full(&g_board);
#else
        sink += (int16_t)eval_material_pst(&g_board);
#endif
    }

    /* emit the low/high byte of the accumulated result so the loop is
     * observably live (a running sum does NOT cancel like an XOR fold). */
    SIM_REG->putchar = (uint8_t)(sink & 0xFF);
    SIM_REG->putchar = (uint8_t)((sink >> 8) & 0xFF);
    return 0;
}
