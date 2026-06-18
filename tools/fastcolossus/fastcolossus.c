/* fastcolossus.c -- run real Colossus 4.0 on the fast cpu6502 functional core.
 *
 * WHY: headless VICE warp is realtime (~1 MHz: depth-6 Caissa move = 225s), too
 * slow to tune against. The same 6502 binary on cpu6502.c runs ~100x faster
 * (3.25s). Caissa already runs there (caissa_cli); this puts COLOSSUS there too,
 * so a Caissa-vs-Colossus game runs in seconds instead of overnight.
 *
 * Colossus needs a full C64 environment (the bare flat-RAM core Caissa uses is
 * not enough): KERNAL/BASIC ROM, $01 banking, CIA1 timers + the 60Hz jiffy IRQ,
 * VIC raster. We layer that over cpu6502.c via its read/write hooks and load a
 * VICE-captured ready-state snapshot (build/colossus_extract/runtime/ready*).
 *
 * This is a PORT of the (deleted, C#) ColossusRawRunner onto cpu6502.c. That C#
 * runner had a never-root-caused fidelity bug (1.e4 -> illegal/odd replies);
 * cpu6502.c is a different, clean-room core, so the first question is empirical:
 * does 1.e4 -> e7e5 (correct -> ship) or f7f6 (bug -> differential-trace vs VICE)?
 *
 * Build:  cc -O2 -I ../fast6502_bridge fastcolossus.c ../fast6502_bridge/cpu6502.c -o fastcolossus
 * Run:    ./fastcolossus            # injects 1.e4, runs, dumps Colossus's reply
 */
#include "cpu6502.h"
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define RUNTIME "build/colossus_extract/runtime/"

/* ---- C64 memory environment layered over cpu6502.c's mem[] (= RAM) ---- */
typedef struct {
    uint8_t basic[0x2000];    /* $A000-$BFFF */
    uint8_t kernal[0x2000];   /* $E000-$FFFF */
    uint8_t chargen[0x1000];  /* $D000-$DFFF when banked in */
    uint8_t io[0x1000];       /* $D000-$DFFF I/O shadow (VIC/SID/CIA regs) */
    uint64_t dc0d_acked;      /* last jiffy period whose CIA1 ICR was read */
} c64_t;

static int loram(cpu6502_t *c)  { return c->mem[1] & 1; }
static int hiram(cpu6502_t *c)  { return c->mem[1] & 2; }
static int charen(cpu6502_t *c) { return c->mem[1] & 4; }

/* PAL timing as the C# runner served it: Colossus reads these as entropy/index
 * and (critically) needs the jiffy IRQ to not freeze check-evasion state. */
static int      raster(cpu6502_t *c) { return (int)((c->cycles / 63) % 312); }
static uint16_t timerA(cpu6502_t *c) { return (uint16_t)(16421 - (c->cycles % 16422)); }
static uint16_t timerB(cpu6502_t *c) { return (uint16_t)(0xFFFF - (c->cycles % 0x10000)); }

long g_ioreads[0x1000];   /* read frequency per $D000-offset (debug) */

static uint8_t c64_read(cpu6502_t *c, uint16_t a) {
    c64_t *m = (c64_t *)c->hook_ctx;
    if (a >= 0xD000 && a <= 0xDFFF) g_ioreads[a - 0xD000]++;
    if (a == 0x0000 || a == 0x0001) return c->mem[a];           /* CPU port */
    if (a >= 0xA000 && a <= 0xBFFF)
        return (loram(c) && hiram(c)) ? m->basic[a - 0xA000] : c->mem[a];
    if (a >= 0xD000 && a <= 0xDFFF) {
        if (!loram(c) && !hiram(c)) return c->mem[a];           /* RAM */
        if (!charen(c))            return m->chargen[a - 0xD000];
        switch (a) {                                            /* I/O */
            case 0xD012: return (uint8_t)(raster(c) & 0xFF);
            case 0xD011: return (uint8_t)((m->io[0x11] & 0x7F) | (((raster(c) >> 8) & 1) << 7));
            case 0xDC04: return (uint8_t)(timerA(c) & 0xFF);
            case 0xDC05: return (uint8_t)(timerA(c) >> 8);
            case 0xDC06: return (uint8_t)(timerB(c) & 0xFF);
            case 0xDC07: return (uint8_t)(timerB(c) >> 8);
            case 0xDC00: return 0xFF;   /* keyboard matrix port A: no key (we use the buffer) */
            case 0xDC01: return 0xFF;   /* keyboard matrix port B */
            case 0xDC0D: {              /* CIA1 ICR: Timer A underflow, latched, clear-on-read */
                uint64_t period = c->cycles / 16422;
                if (period > m->dc0d_acked) { m->dc0d_acked = period; return 0x81; } /* IRQ|TA */
                return 0x00;
            }
            default:     return m->io[a - 0xD000];
        }
    }
    if (a >= 0xE000 && hiram(c)) return m->kernal[a - 0xE000];
    return c->mem[a];
}

static void c64_write(cpu6502_t *c, uint16_t a, uint8_t v) {
    c64_t *m = (c64_t *)c->hook_ctx;
    /* Writes to the I/O window hit I/O; writes everywhere else (incl. under ROM)
     * hit the underlying RAM. */
    if (a >= 0xD000 && a <= 0xDFFF && (loram(c) || hiram(c)) && charen(c)) {
        m->io[a - 0xD000] = v;
        return;
    }
    c->mem[a] = v;
}

/* ---- helpers ---- */
static void load64k(const char *path, uint8_t *dst) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); exit(2); }
    size_t n = fread(dst, 1, 0x10000, f);
    fclose(f);
    if (n != 0x10000) { fprintf(stderr, "%s: read %zu bytes (want 65536)\n", path, n); exit(2); }
}

static char sc_to_ascii(uint8_t b) {
    b &= 0x7F;
    if (b >= 1 && b <= 26) return 'a' + b - 1;
    if (b >= 0x30 && b <= 0x39) return (char)b;
    if (b == 0x20) return ' ';
    if (b >= 0x41 && b <= 0x5A) return (char)b;
    switch (b) { case 0x2D: return '-'; case 0x2B: return '+'; case 0x2A: return '*';
                 case 0x3A: return ':'; case 0x3D: return '='; case 0x28: return '(';
                 case 0x29: return ')'; case 0x2E: return '.'; }
    return '.';
}

static void dump_screen(cpu6502_t *c) {
    printf("---- screen ($0400) ----\n");
    for (int row = 0; row < 25; row++) {
        char line[41];
        for (int col = 0; col < 40; col++) line[col] = sc_to_ascii(c->mem[0x0400 + row * 40 + col]);
        line[40] = 0;
        /* rstrip */
        int e = 40; while (e > 0 && line[e - 1] == ' ') line[--e] = 0;
        printf("%s\n", line);
    }
    printf("------------------------\n");
}

/* IRQ delivery (standard NMOS, vectoring through $FFFE which banks to KERNAL). */
static void deliver_irq(cpu6502_t *c) {
    c->mem[0x100 + c->sp] = (uint8_t)(c->pc >> 8);   c->sp--;
    c->mem[0x100 + c->sp] = (uint8_t)(c->pc & 0xFF); c->sp--;
    c->mem[0x100 + c->sp] = (uint8_t)((c->status & ~FLAG_B) | FLAG_U); c->sp--;
    c->status |= FLAG_I;
    c->pc = (uint16_t)c64_read(c, 0xFFFE) | ((uint16_t)c64_read(c, 0xFFFF) << 8);
    c->cycles += 7;
}

int main(int argc, char **argv) {
    const char *ram_path = RUNTIME "ready.ram.bin";
    const char *cpu_path = RUNTIME "ready_cpu.ram.bin";
    /* e2e4 keyboard input: <rank><FILE>RET per square (from analysis.json). */
    static const uint8_t move_in[] = { 0x32, 0x45, 0x0D, 0x34, 0x45, 0x0D };
    long max_cycles = (argc > 1) ? atol(argv[1]) : 80000000L;  /* ~ a few s on fast core */

    cpu6502_t *c = calloc(1, sizeof *c);
    c64_t *m = calloc(1, sizeof *m);

    /* RAM view -> mem[]; CPU view -> extract banked ROM/IO. */
    load64k(ram_path, c->mem);
    uint8_t *cpuview = malloc(0x10000);
    load64k(cpu_path, cpuview);
    memcpy(m->basic,  cpuview + 0xA000, 0x2000);
    memcpy(m->kernal, cpuview + 0xE000, 0x2000);
    memcpy(m->io,     cpuview + 0xD000, 0x1000);
    free(cpuview);

    c->read_hook = c64_read;
    c->write_hook = c64_write;
    c->hook_ctx = m;

    /* The RAM-view snapshot's $00/$01 are the bytes UNDER the CPU port, not the
     * effective banking latch (which a RAM dump can't capture). Force the normal
     * running-C64 banking so KERNAL+BASIC+I/O are visible: $01=$37, DDR $00=$2F.
     * Without this, $01=0 banks everything to RAM and PC=$F155 executes garbage. */
    c->mem[0x0000] = 0x2F;
    c->mem[0x0001] = 0x37;

    /* Ready-state registers (build/colossus_extract/runtime/ready.json). */
    c->pc = 61781;          /* 0xF155, KERNAL keyboard-wait loop */
    c->sp = 0xF5;
    c->a = c->x = c->y = 0;
    c->status = FLAG_U | FLAG_Z | FLAG_C;   /* C=1 Z=1 */

    /* Keyboard input is fed ONE byte at a time as the buffer drains (mirroring
     * the C# runner's QueuedKeyboardInput) -- Colossus reads a char, processes,
     * then expects the next keypress, not a pre-stuffed 6-byte buffer. */
    size_t kb_idx = 0;
    uint64_t kb_next = 0;          /* feed when cycles >= kb_next and buffer empty */
    const uint64_t KB_GAP = 20000; /* ~1 jiffy between keypresses */

    printf("Colossus on fast core: injecting 1.e4, running up to %ld cycles ...\n", max_cycles);
    struct timespec t0; clock_gettime(CLOCK_MONOTONIC, &t0);

    int dbg = getenv("FCDEBUG") != NULL;
    uint64_t next_irq = 16421;
    long steps = 0;
    uint16_t pc_hist_max = 0; long pc_hist_cnt = 0, irqs = 0; int irq_pending = 0;
    while (c->cycles < (uint64_t)max_cycles) {
        if (c->cycles >= next_irq) { next_irq += 16421; irq_pending = 1; }
        /* Latch the jiffy IRQ until the I flag clears (the line stays asserted,
         * like the CIA). Dropping it when I=1 was starving Colossus's timing. */
        if (irq_pending && !(c->status & FLAG_I)) { deliver_irq(c); irq_pending = 0; irqs++; }
        /* Feed the next move keystroke once the buffer has drained. */
        if (kb_idx < sizeof move_in && c->mem[0x00C6] == 0 && c->cycles >= kb_next) {
            c->mem[0x0277] = move_in[kb_idx++];
            c->mem[0x00C6] = 1;
            kb_next = c->cycles + KB_GAP;
        }
        long dbgmod = getenv("FCFINE") ? 5000 : 2000000;
        if (dbg && (steps % dbgmod) == 0)
            fprintf(stderr, "[dbg] step=%ld pc=%04x sp=%02x C6=%02x op=%02x irqs=%ld I=%d $01=%02x\n",
                    steps, c->pc, c->sp, c->mem[0xC6], c64_read(c, c->pc), irqs,
                    (c->status & FLAG_I) ? 1 : 0, c->mem[1]);
        (void)pc_hist_max; (void)pc_hist_cnt;
        cpu6502_step(c);
        steps++;
    }
    if (dbg) {
        fprintf(stderr, "[dbg] total irqs delivered: %ld\n", irqs);
        fprintf(stderr, "[dbg] hottest I/O reads:\n");
        for (int pass = 0; pass < 8; pass++) {
            int best = -1; long bv = 0;
            for (int i = 0; i < 0x1000; i++) if (g_ioreads[i] > bv) { bv = g_ioreads[i]; best = i; }
            if (best < 0) break;
            fprintf(stderr, "   $%04X : %ld\n", 0xD000 + best, bv);
            g_ioreads[best] = 0;
        }
    }

    struct timespec t1; clock_gettime(CLOCK_MONOTONIC, &t1);
    double secs = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
    printf("ran %ld steps, %llu cycles in %.2fs (%.1f M cyc/s)\n",
           steps, (unsigned long long)c->cycles, secs, c->cycles / 1e6 / secs);
    dump_screen(c);
    return 0;
}
