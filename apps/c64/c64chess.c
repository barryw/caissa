/* c64chess.c -- minimal playable Commodore 64 chess front-end for the native C
 * engine (board.c/movegen.c/eval.c/search_fullwidth.c), compiled with llvm-mos for the
 * real c64 target. This is the FIRST integration proving the engine is usable in
 * a real game on a real 6502 -- a text UI over the same engine the speed campaign
 * optimized. The UI is deliberately tiny; the engine is doing all the chess.
 *
 * Build: tools/build_c64.sh  (mos-c64-clang + the hand-asm overrides).
 * Run:   x64sc chess.prg     (VICE), then play e.g. "e2e4".
 *
 * Portability: nothing here is c64-specific except stdio (KERNAL CHROUT/CHRIN via
 * llvm-mos). The same source builds for Nova once a Nova llvm-mos platform exists.
 */
#include <stdio.h>     /* getchar/putchar (KERNAL-backed); NOT printf (too big) */
#include "board.h"
#include "search.h"
#include "eval.h"
#include "movegen.h"

/* putchar a NUL-terminated string. Used instead of printf/puts so the format
 * machinery (~1-2 KB) never gets linked -- it does not fit alongside the engine
 * in the c64's ~50 KB. */
static void prints(const char *s) { while (*s) putchar(*s++); }

#define START_FEN "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

/* Engine strength/speed dial, chosen at startup (read_level). Each ply is
 * ~+100-150 Elo but costs ~3-4x the cycles. Approx strength vs search depth
 * (measured, cref_mos vs Stockfish): d2~1461 d3~1605 d4~1753 d5~1850 d6~1942.
 * Per-move time scales with the host clock -- on a stock 1 MHz c64 d3 is already
 * minutes/move, but on a 64 MHz Ultimate 64 d6 is ~19 s/move and on a 12 MHz
 * Nova d4-d5 is seconds. So the player picks the level to match their machine.
 * MAX_PLY (memcfg, =7 on the c64 profile) caps this at 6. */
#define ENGINE_DEPTH_DEFAULT 4
#define ENGINE_DEPTH_MAX 6

static const char PIECE_CH[7] = { '.', 'P', 'N', 'B', 'R', 'Q', 'K' };

static void print_board(const Board *b) {
    int rank, file;
    putchar('\n');
    for (rank = 7; rank >= 0; rank--) {           /* rank 8 (top) down to 1 */
        putchar('1' + rank);
        putchar(' ');
        for (file = 0; file < 8; file++) {
            int idx = (7 - rank) * 16 + file;     /* 0x88: a8=0 .. h1=119 */
            uint8_t p = b->sq[idx];
            char c = PIECE_CH[p & 7];
            if ((p & 7) && !(p & WHITE_FLAG)) c += 32;   /* black -> lowercase */
            putchar(c);
            putchar(' ');
        }
        putchar('\n');
    }
    putchar(' ');
    putchar(' ');
    for (file = 0; file < 8; file++) { putchar('a' + file); putchar(' '); }
    putchar('\n');
    prints(b->wtm ? "White to move\n" : "Black to move\n");
}

/* Read a move like "e2e4" (or "e7e8q") from the keyboard into buf. Returns the
 * length (4 or 5), or 0 on a blank line / 'q' quit request. */
static int read_move(char *buf) {
    int n = 0, c;
    prints("your move> ");
    for (;;) {
        c = getchar();
        if (c == '\n' || c == '\r' || c == EOF) break;
        if (n < 5) buf[n++] = (char)c;
    }
    buf[n] = 0;
    return n;
}

/* Ask the player for a search level (1..ENGINE_DEPTH_MAX). The first digit typed
 * wins; anything else (e.g. a bare RETURN) keeps the default. Higher = stronger
 * and slower -- match it to how fast your machine is. */
static int read_level(void) {
    int c, lvl = ENGINE_DEPTH_DEFAULT;
    prints("level 1-6 (6=~1942 elo, fast machine)? ");
    c = getchar();
    if (c >= '1' && c <= ('0' + ENGINE_DEPTH_MAX)) lvl = c - '0';
    while (c != '\n' && c != '\r' && c != EOF) c = getchar();   /* drain line */
    return lvl;
}

int main(void) {
    Board b;
    Undo u;
    char buf[8];
    SearchInfo info;
    int engine_depth;

    eval_reset_weights();
    search_reset_config();
    board_from_fen(&b, START_FEN);

    prints("CAISSA -- native C engine on 6502\n");
    prints("enter moves like e2e4, q to quit\n");
    engine_depth = read_level();

    for (;;) {
        print_board(&b);

        if (!board_any_legal_move(&b)) {
            prints(in_check(&b) ? "checkmate.\n" : "stalemate.\n");
            break;
        }

        /* ---- human (White) ---- */
        {
            Move m;
            int len = read_move(buf);
            if (len == 0 || buf[0] == 'q') { prints("bye\n"); break; }
            if (move_from_uci(&b, buf, &m) != 0) {
                prints("illegal move, try again\n");
                continue;
            }
            make_move(&b, m, &u);
        }

        print_board(&b);
        if (!board_any_legal_move(&b)) {
            prints(in_check(&b) ? "you win -- checkmate.\n" : "stalemate.\n");
            break;
        }

        /* ---- engine (Black) ---- */
        {
            char uci[6];
            Move m;
            hash_t hist[1];
            hist[0] = b.hash;
            prints("thinking...\n");
            m = search_bestmove(&b, engine_depth, hist, 1, &info);
            move_to_uci(m, uci);
            prints("engine plays ");
            prints(uci);
            putchar('\n');
            make_move(&b, m, &u);
        }
    }
    return 0;
}
