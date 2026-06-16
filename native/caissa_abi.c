/* caissa_abi.c -- the asm<->C handoff for embedding the native engine inside the
 * pure-assembly C64 game (~/Git/Chess), which keeps its KickAssembler UI + sprite
 * multiplexer. The two toolchains (llvm-mos C vs KickAssembler) cannot link, so
 * the engine is built as a separate fixed-address BLOB that the game embeds and
 * calls via this fixed-memory ABI:
 *
 *   1. game converts its Board88 ($30-based) into g_caissa.sq[] with one AND #$8F
 *      per square (color bit 7 + type in the low nibble == the engine encoding;
 *      same 0x88 indices), and copies wtm/castle/ep/king-squares + the depth.
 *   2. game does jsr caissa_move (with its raster IRQ off for the search -- the
 *      engine owns the machine while thinking; sprites resume after).
 *   3. caissa_move runs the real search and writes from/to/promo back.
 *
 * g_caissa lives at a fixed address (the game reads it from the blob's map). The
 * board encoding matches exactly: Chess EMPTY=$30, PAWN_SPR..KING_SPR=$31..$36,
 * WHITE_COLOR=$80; engine empty=0, type 1..6, WHITE_FLAG=$80 -> engine = b88 & $8F.
 * Castle bits are identical on both sides (WK=1,WQ=2,BK=4,BQ=8).
 */
#include "board.h"
#include "search.h"
#include "eval.h"

typedef struct {
    uint8_t sq[128];   /* IN: engine-encoded board (game fills via AND #$8F)      */
    uint8_t wtm;       /* IN: 1 = white to move                                   */
    uint8_t castle;    /* IN: CASTLE_* bits (same order as the game)              */
    uint8_t ep;        /* IN: en-passant 0x88 square, 0xFF = none                 */
    uint8_t wk, bk;    /* IN: king 0x88 squares                                   */
    uint8_t depth;     /* IN: search depth (game maps difficulty -> depth)        */
    uint8_t from;      /* OUT: best-move from-square (0x88)                       */
    uint8_t to;        /* OUT: best-move to-square (0x88)                         */
    uint8_t promo;     /* OUT: promotion piece type (0 = none)                    */
} CaissaABI;

/* The shared handoff block. The game references it at the address the blob's link
 * map reports (or pin it with a linker section when the blob is built). */
CaissaABI g_caissa;

/* Call once at game startup (after the blob's own runtime init) before the first
 * caissa_move: sets the eval weights + search config the engine searches with. */
void caissa_init(void) {
    eval_reset_weights();
    search_reset_config();
}

/* Per-move entry: read g_caissa, search, write the best move back. jsr/rts ABI. */
void caissa_move(void) {
    Board b;
    SearchInfo info;
    hash_t hist[1];
    Move m;
    int i;

    for (i = 0; i < 128; i++) b.sq[i] = g_caissa.sq[i];
    b.wtm = g_caissa.wtm;
    b.castle = g_caissa.castle;
    b.ep = (g_caissa.ep == 0xFF) ? -1 : g_caissa.ep;
    b.wk = g_caissa.wk;
    b.bk = g_caissa.bk;
    b.halfmove = 0;
    b.fullmove = 1;
    b.hash = board_zobrist(&b);   /* recompute hash + accumulators from the board */
    eval_acc_init(&b);
    hist[0] = b.hash;

    m = search_bestmove(&b, g_caissa.depth, hist, 1, &info);
    g_caissa.from = m.from;
    g_caissa.to = m.to;
    g_caissa.promo = m.promo;
}
