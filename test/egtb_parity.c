/* egtb_parity.c -- host harness: read FENs on stdin, print egtb_probe result per line
 * as "hit score" (or "miss") at ply 0. A python driver (in egtb_gen.py --parity)
 * compares against the tables to prove the C index == the generator index. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "board.h"
#include "egtb.h"

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s egtb_tables.bin < fenlist\n", argv[0]); return 2; }
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror("open bin"); return 2; }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    unsigned char *blob = malloc(n);
    if (fread(blob, 1, n, f) != (size_t)n) { fprintf(stderr, "short read\n"); return 2; }
    fclose(f);
    egtb_set_data(blob);

    char line[256];
    while (fgets(line, sizeof line, stdin)) {
        char *nl = strpbrk(line, "\r\n"); if (nl) *nl = 0;
        if (!line[0]) continue;
        Board b;
        if (board_from_fen(&b, line)) { printf("badfen\n"); continue; }
        int sc, hit = egtb_probe(&b, 0, &sc);
        if (hit) printf("hit %d\n", sc); else printf("miss\n");
    }
    return 0;
}
