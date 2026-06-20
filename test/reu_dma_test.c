/* reu_test.c -- standalone validation of the REU DMA TT accessor on a real C64+REU
 * (run in VICE: x64sc -reu -reusize 512 reu_test.prg). Writes 1000 distinct 12-byte
 * "entries" to REU[idx*12] via $DF00 stash, reads them back via fetch, verifies.
 * Mirrors the reu_xfer in src/search.c EXACTLY. Result byte at `g_result`
 * (peek via the monitor): 0xAA = PASS, 0xFF = FAIL, 0x00 = not finished. */
#include <stdint.h>
#include <stdio.h>

#define REU ((volatile unsigned char *)0xDF00)
static void reu_xfer(const void *c64, unsigned long reu, unsigned len, unsigned char cmd) {
    unsigned a = (unsigned)c64;
    REU[0x02] = (unsigned char)a;          REU[0x03] = (unsigned char)(a >> 8);
    REU[0x04] = (unsigned char)reu;        REU[0x05] = (unsigned char)(reu >> 8);
    REU[0x06] = (unsigned char)(reu >> 16);
    REU[0x07] = (unsigned char)len;        REU[0x08] = (unsigned char)(len >> 8);
    REU[0x0A] = 0;
    REU[0x01] = cmd;
}
#define ENTRY 12
#define N 1000

volatile unsigned char g_result = 0;   /* monitor peeks this */

static unsigned char pat(int idx, int i) { return (unsigned char)(idx * 7 + i * 13 + 1); }

int main(void) {
    unsigned char buf[ENTRY];
    int idx, i, ok = 1;
    printf("reu test...\n");
    for (idx = 0; idx < N; idx++) {
        for (i = 0; i < ENTRY; i++) buf[i] = pat(idx, i);
        reu_xfer(buf, (unsigned long)idx * ENTRY, ENTRY, 0x90);   /* stash C64->REU */
    }
    for (idx = 0; idx < N; idx++) {
        for (i = 0; i < ENTRY; i++) buf[i] = 0;
        reu_xfer(buf, (unsigned long)idx * ENTRY, ENTRY, 0x91);   /* fetch REU->C64 */
        for (i = 0; i < ENTRY; i++) if (buf[i] != pat(idx, i)) { ok = 0; }
    }
    g_result = ok ? 0xAA : 0xFF;
    printf(ok ? "REU OK\n" : "REU FAIL\n");
    for (;;) { }   /* spin so the monitor can read g_result */
}
