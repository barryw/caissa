/* test_eval.c -- isolated eval verification driver.
 *   feed FENs on stdin (one per line) -> prints "<eval>\n" per line.
 * Compared against tools/texel_eval.py eval_full by tools/native_eval_check.py.
 *
 * board.o references gen_legal (via move_from_uci); the eval path never calls
 * it, so this isolated build provides a stub. The final engine links the real
 * movegen instead, so this stub is NOT in the production binary.
 */
#include "board.h"
#include "movegen.h"
#include "eval.h"
#include <stdio.h>
#include <string.h>

int gen_legal(const Board *b, Move *list) { (void)b; (void)list; return 0; }

int main(void) {
    char line[256];
    eval_reset_weights();
    while (fgets(line, sizeof(line), stdin)) {
        size_t n = strlen(line);
        while (n && (line[n-1] == '\n' || line[n-1] == '\r')) line[--n] = 0;
        if (!n) continue;
        Board b;
        if (board_from_fen(&b, line)) { printf("ERR\n"); continue; }
        printf("%d\n", eval_full(&b));
    }
    return 0;
}
