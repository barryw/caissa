/* profile6502.c -- PC-sampling profiler for the llvm-mos 6502 chess image.
 *
 * Runs a bestmove search on the caissa.sim image inside the cycle-exact
 * fast6502 core, samples the program counter every SAMPLE_EVERY cycles, and
 * attributes samples to functions parsed from the linker .map. Tells us where
 * the cycles actually go so the speed campaign optimizes the right thing.
 *
 * Build: cc -O2 profile6502.c ../fast6502_bridge/cpu6502.c -o profile6502
 * Run:   ./profile6502 /tmp/caissa.sim /tmp/caissa.map "FEN" DEPTH
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include "../fast6502_bridge/cpu6502.h"

#define SIM_EXIT_REG    0xFFF8
#define SIM_PUTCHAR_REG 0xFFF9
#define EXIT_SENTINEL   0x5A
#define SIM_READY       0xA5
#define MAX_CYCLES_RUN  400000000000ULL
#define SAMPLE_EVERY    64          /* sample PC every N instructions */

static cpu6502_t cpu;
static uint16_t A_g_fen, A_g_depth, A_g_go, A_g_done;

typedef struct { uint16_t start, end; char name[48]; unsigned long long samples; } Func;
static Func funcs[512]; static int nfuncs;

static int map_addr(const char *mapfile, const char *sym, uint16_t *out) {
    FILE *f = fopen(mapfile, "r"); char line[512]; size_t slen = strlen(sym);
    if (!f) return -1;
    while (fgets(line, sizeof line, f)) {
        char *tok, *last = NULL, *save, buf[512];
        strncpy(buf, line, sizeof buf - 1); buf[sizeof buf - 1] = 0;
        for (tok = strtok_r(buf," \t\r\n",&save); tok; tok = strtok_r(NULL," \t\r\n",&save)) last = tok;
        if (last && strlen(last)==slen && !strcmp(last,sym)) {
            unsigned v; if (sscanf(line," %x",&v)==1){*out=(uint16_t)v;fclose(f);return 0;}
        }
    }
    fclose(f); return -1;
}

/* parse function symbols: lines "  VMA  LMA  SIZE  ALIGN  name" (5 tokens, name
 * a bare identifier with no ':' or '/'). */
static void load_funcs(const char *mapfile) {
    FILE *f = fopen(mapfile, "r"); char line[512];
    if (!f) { fprintf(stderr,"no map\n"); exit(2); }
    while (fgets(line, sizeof line, f)) {
        char buf[512]; strncpy(buf,line,sizeof buf-1); buf[sizeof buf-1]=0;
        char *t[8]; int n=0, save_i; char *save, *tok;
        for (tok=strtok_r(buf," \t\r\n",&save); tok && n<8; tok=strtok_r(NULL," \t\r\n",&save)) t[n++]=tok;
        if (n!=5) continue;
        /* t0=VMA t2=SIZE hex; t4=name identifier (no :,/,( ) */
        char *nm=t[4]; if (strpbrk(nm,":/(.")) continue;
        if (!(nm[0]=='_'||(nm[0]>='a'&&nm[0]<='z')||(nm[0]>='A'&&nm[0]<='Z'))) continue;
        unsigned vma, sz;
        if (sscanf(t[0],"%x",&vma)!=1 || sscanf(t[2],"%x",&sz)!=1) continue;
        if (sz==0 || nfuncs>=512) continue;
        funcs[nfuncs].start=(uint16_t)vma; funcs[nfuncs].end=(uint16_t)(vma+sz);
        strncpy(funcs[nfuncs].name,nm,47); funcs[nfuncs].samples=0; nfuncs++;
        (void)save_i;
    }
    fclose(f);
}

static int load_image(const char *path) {
    FILE *f=fopen(path,"rb"); long fsz,off=0; uint8_t *buf; int ch=0;
    if(!f){perror("img");return -1;}
    fseek(f,0,SEEK_END); fsz=ftell(f); fseek(f,0,SEEK_SET); buf=malloc(fsz);
    if(fread(buf,1,fsz,f)!=(size_t)fsz){fclose(f);return -1;} fclose(f);
    memset(cpu.mem,0,sizeof(cpu.mem));
    while(off+4<=fsz){uint16_t a=buf[off]|(buf[off+1]<<8),l=buf[off+2]|(buf[off+3]<<8);off+=4;
        if(off+l>fsz)break; for(uint16_t i=0;i<l;i++)cpu.mem[(uint16_t)(a+i)]=buf[off+i]; off+=l; ch++;}
    free(buf); return ch;
}

static void record(uint16_t pc) {
    for (int i=0;i<nfuncs;i++) if (pc>=funcs[i].start && pc<funcs[i].end){funcs[i].samples++;return;}
    /* unattributed (runtime/crt/inlined) -> bucket 0 via a sentinel name */
}

int main(int argc, char **argv) {
    if (argc<5){fprintf(stderr,"usage: %s sim map FEN depth\n",argv[0]);return 2;}
    const char *sim=argv[1],*map=argv[2],*fen=argv[3]; int depth=atoi(argv[4]);
    load_funcs(map);
    if(map_addr(map,"g_fen",&A_g_fen)||map_addr(map,"g_depth",&A_g_depth)||
       map_addr(map,"g_go",&A_g_go)||map_addr(map,"g_done",&A_g_done)){fprintf(stderr,"abi?\n");return 2;}
    if(load_image(sim)<0)return 2;
    cpu6502_reset(&cpu);
    cpu.mem[SIM_EXIT_REG]=EXIT_SENTINEL; cpu.mem[SIM_PUTCHAR_REG]=0;
    cpu.pc=cpu.mem[0xFFFC]|(cpu.mem[0xFFFD]<<8);
    while(cpu.cycles<MAX_CYCLES_RUN){cpu6502_step(&cpu);if(cpu.mem[SIM_PUTCHAR_REG]==SIM_READY)break;
        if(cpu.mem[SIM_EXIT_REG]!=EXIT_SENTINEL){fprintf(stderr,"exit before ready\n");return 1;}}
    { size_t i; for(i=0;i<strlen(fen)&&i<99;i++)cpu.mem[(uint16_t)(A_g_fen+i)]=(uint8_t)fen[i];
      cpu.mem[(uint16_t)(A_g_fen+i)]=0; cpu.mem[A_g_depth]=(uint8_t)depth; cpu.mem[A_g_done]=0; cpu.mem[A_g_go]=1; }
    unsigned long long step=0, total=0;
    while(cpu.cycles<MAX_CYCLES_RUN){
        cpu6502_step(&cpu);
        if((++step & (SAMPLE_EVERY-1))==0){ record(cpu.pc); total++; }
        if(cpu.mem[SIM_EXIT_REG]!=EXIT_SENTINEL)break;
    }
    /* sort by samples desc (simple) */
    for(int i=0;i<nfuncs;i++)for(int j=i+1;j<nfuncs;j++)
        if(funcs[j].samples>funcs[i].samples){Func t=funcs[i];funcs[i]=funcs[j];funcs[j]=t;}
    unsigned long long attributed=0; for(int i=0;i<nfuncs;i++)attributed+=funcs[i].samples;
    printf("=== profile: %s d%d (%llu cycles, %llu samples) ===\n", fen, depth, cpu.cycles, total);
    printf("%-26s %8s %6s\n","function","samples","%");
    for(int i=0;i<nfuncs && i<20;i++){ if(!funcs[i].samples)break;
        printf("%-26s %8llu %5.1f%%\n",funcs[i].name,funcs[i].samples,100.0*funcs[i].samples/total); }
    printf("%-26s %8llu %5.1f%%\n","[unattributed/runtime]",total-attributed,100.0*(total-attributed)/total);
    return 0;
}
