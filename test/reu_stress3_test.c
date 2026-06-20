/* reu_stress3_test.c -- full-scale ($DF00 DMA) REU accessor self-test.
 *
 * Goes well past reu_dma_test (which does idx<1000, write-all-then-read-all): this
 * covers ALL TT14 entries (16384 x 12B, addr 0..196596) with the search's actual
 * clear+read-modify-write pattern, verifying EVERY read. No 192KB shadow needed: a
 * per-idx 1-byte `ver` (write-count) array (16KB, fits RAM) lets the expected 12
 * bytes be recomputed as f(idx,ver). g_result 0xAA/0xFF; g_failidx/g_failiter mark
 * the first divergence.
 *
 * NOTE: this PASSES even on the buggy (pre-sei/cli) engine -- it proves the DMA
 * transport is byte-perfect but does NOT exercise the IRQ-during-setup window the
 * real search hit. The trustworthy end-to-end check is tools/reu_validate.py
 * (a real search in x64sc -reu vs the host oracle). Run: x64sc -reu reu_stress3.prg */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
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
#define N 16384
static unsigned char ver[N];          /* write-count per idx (16 KB) */
volatile unsigned char g_result = 0;
volatile unsigned      g_failidx  = 0xFFFF;
volatile unsigned long g_failiter = 0;
static unsigned char expect(unsigned idx, unsigned char v, int i) {
    return (unsigned char)(idx * 5 + v * 31 + i * 13 + 7);
}
int main(void) {
    unsigned char buf[ENTRY];
    unsigned long it, lfsr = 0x1234u;
    unsigned idx; int i, ok = 1;
    printf("reu stress3...\n");
    /* clear: every entry -> ver 0 pattern (== the search's zero-clear analogue) */
    memset(ver, 0, sizeof(ver));
    for (idx = 0; idx < N; idx++) {
        for (i = 0; i < ENTRY; i++) buf[i] = expect(idx, 0, i);
        reu_xfer(buf, (unsigned long)idx * ENTRY, ENTRY, 0x90);
    }
    /* RMW across the full range, verifying each read */
    for (it = 0; it < 60000UL; it++) {
        lfsr ^= lfsr << 7; lfsr ^= lfsr >> 9; lfsr ^= lfsr << 8;
        idx = (unsigned)(lfsr % N);
        reu_xfer(buf, (unsigned long)idx * ENTRY, ENTRY, 0x91);     /* fetch */
        for (i = 0; i < ENTRY; i++)
            if (buf[i] != expect(idx, ver[idx], i)) {
                ok = 0; g_failidx = idx; g_failiter = it; goto done;
            }
        ver[idx]++;
        for (i = 0; i < ENTRY; i++) buf[i] = expect(idx, ver[idx], i);
        reu_xfer(buf, (unsigned long)idx * ENTRY, ENTRY, 0x90);     /* stash */
    }
done:
    g_result = ok ? 0xAA : 0xFF;
    printf(ok ? "STRESS3 OK\n" : "STRESS3 FAIL\n");
    for (;;) { }
}
