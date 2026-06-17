; ============================================================================
; eval_full_6502.s  --  hand-written 6502 (llvm-mos / mos-sim) eval_full().
;
; PHASE-2 PARTIAL for the wholesale eval_full hand-asm project
; (docs/eval-asm-scope.md). This file implements the eval_full STRUCTURE in asm
; -- the 0x88 board walk, every per-piece COUNTER, the endgame flag, the
; tapered-blend guard, the tempo term, and the final 16-bit wrap.
;
; TERM HELPER STATUS (the per-piece + advanced_pawn positional terms):
;   INLINE asm (groups a + b, bit-exact 22157/22157):
;     advanced_pawn, pawn_pressure, knight_outpost, queen_pressure,
;     minor_pressure   (+ their inlined probes: check_white/black_pawn_at,
;     is_pawn_attacked, is_knight_attacked, is_bishop_attacked, is_queen_attacked),
;     mobility (+ inlined count_knight_mobility, count_sliding_mobility),
;     seventh_rank
;   still jsr-to-C (the tail, later sessions):
;     bishop_pair, pawn_structure, king_pins, king_safety, endgame,
;     king_attack_escalation, pawn_storm, queen_attacks_minor
; The jsr'd helpers keep external linkage via EVAL_HELPER (eval.c) when
; CREF_ASM_EVAL_FULL is defined; the validator stays 22157/22157 the whole way
; and any divergence bisects to exactly the one term just converted.
;
; This .s is built ONLY for the mos-sim 6502 image, linked INSTEAD of the C body:
; eval.c #ifdef's out `int eval_full(const Board*)` when CREF_ASM_EVAL_FULL is
; defined. The host (clang) build keeps the C body, the bit-exact oracle. The
; validator (tools/eval_corpus_check.py -> /tmp/eval_validate) diffs this asm
; against the python oracle across all 22157 corpus positions.
;
; ----------------------------------------------------------------------------
; ABI (llvm-mos MOSCallingConv.td; confirmed by compiling probes -- see header
; of native/gen_legal_6502.s for the full convention and the imaginary-reg map):
;
;   C prototype:  int eval_full(const Board *board)
;     in:  board ptr -> __rc2 (lo) / __rc3 (hi)   (points at board->sq[0])
;     out: int score -> A (lo) / X (hi)
;
; Caller-saved (clobbered by ANY called function): A / X / Y, __rc2..__rc19.
; Callee-saved (must be preserved across our body): __rc0/1, __rc20..__rc31.
;
; This skeleton holds NO live state in registers across helper calls. ALL
; persistent state (the Eval struct, the board pointer, the loop index) lives in
; static .bss -- eval_full is non-recursive (exactly as gen_legal uses static
; g_pseudo/g_pinned). So no pha/pla of callee-saved regs is needed and the body
; never relies on a register surviving a `jsr`. (Speed is irrelevant in the
; skeleton: the C term helpers dominate cycles; a later session inlines them and
; revisits the register plan.)
;
; THE 4-ARG HELPER CALL CONVENTION (confirmed by a probe that compiles
;   `pawn_pressure(e, 0x12, 0x80, 3)` with mos-sim-clang -S -Os):
;     arg1 e     (Eval*) -> __rc2 (lo) / __rc3 (hi)
;     arg2 sq    (int)   -> A    (lo) / X    (hi)
;     arg3 color (int)   -> __rc4 (lo) / __rc5 (hi)
;     arg4 ptype (int)   -> __rc6 (lo) / __rc7 (hi)
;   The 1-arg tail helpers (bishop_pair(e) etc.) take e in __rc2/3.
;   color is `piece & 0x80` (0 or 128, hi byte 0); ptype is `piece & 7`
;   (1..6, hi byte 0); sq is 0..119 (hi byte 0). We always set the hi bytes to 0.
;
; FAR-BRANCH HAZARD: the integrated assembler SILENTLY truncates out-of-range
; bcc/bcs/beq/bne (>+/-127), corrupting control flow. This file is large, so
; EVERY conditional branch whose target could be far uses the invert-and-JMP
; idiom: a short branch over a 3-byte absolute `jmp` (jmp is 16-bit, always in
; range). Short branches are used ONLY for provably-near targets (the next few
; instructions).
;
; ----------------------------------------------------------------------------
; DERIVED LAYOUTS (all from offsetof probes compiled with mos-sim-clang;
; int = 16-bit, pointer = 16-bit). DO NOT trust by inspection -- re-probe if
; the C structs change.
;
;   Eval (file-static in eval.c) -- sizeof = 56:
;     +0   const uint8_t *b      (ptr)
;     +2   int  wk
;     +4   int  bk
;     +6   uint16_t score
;     +8   int  nonpawn
;     +10  int  pawns
;     +12  int  queens
;     +14  int  wbishops
;     +16  int  bbishops
;     +18  int  endgame
;     +20  int  phase
;     +22  int  egdiff
;     +24  int  wpf[8]   (24..39)
;     +40  int  bpf[8]   (40..55)
;
;   Board -- sizeof = 152:
;     +0    uint8_t sq[128]
;     +128  int wtm
;     +130  int wk
;     +132  int bk
;     +146  int acc_mat
;     +148  int acc_egdiff
;     +150  int acc_phase
;
;   EvalWeights g_w -- sizeof = 110:
;     +58   int heavy_seventh_rank   (field index 29; confirmed via offsetof probe)
;     +60   int endgame_nonpawn_limit
;     +100  int tempo
;     +102  int trapped_penalty      (field index 51; confirmed via offsetof probe)
;
; ----------------------------------------------------------------------------
; THE C STRUCTURE THIS REPLICATES  (native/eval.c eval_full, lines ~1298-1410):
;   seed Eval from board (b/wk/bk/score=acc_mat/phase=acc_phase/egdiff=acc_egdiff,
;     counters & wpf/bpf zeroed via .bss zero-init + crt0);
;   0x88 board walk: per non-empty square dispatch counters + 7 term calls;
;   endgame flag; tapered-egdiff blend (guarded, corpus-cold); tail
;   (bishop_pair / pawn_structure / endgame|king_pins+king_safety); A/B terms;
;   tempo; 16-bit two's-complement wrap -> return.
; ============================================================================

	.zeropage	__rc2
	.zeropage	__rc3
	.zeropage	__rc4
	.zeropage	__rc5
	.zeropage	__rc6
	.zeropage	__rc7
	.zeropage	__rc8
	.zeropage	__rc9
	.zeropage	__rc10
	.zeropage	__rc11
	.zeropage	__rc12
	.zeropage	__rc13
	.zeropage	__rc14
	.zeropage	__rc15

	.globl	eval_full
	.globl	g_w
; ET_* tables are g_w-derived int[7] arrays (externalized via EVAL_DATA in
; eval.c when CREF_ASM_EVAL_FULL is defined). The inlined pressure terms index
; them at runtime as ET_x + ptype*2 (2 bytes/entry) -- they MUST be read live,
; not baked, because eval overrides mutate g_w (and thus these tables).
	.globl	ET_PAWN_ATTACK
	.globl	ET_QUEEN_ATTACK
	.globl	ET_MINOR_ATTACK

; ---- C constants (board.h / eval.c) ----------------------------------------
EMPTY       = 0
WHITE_COLOR = 0x80
PT_PAWN     = 1
PT_BISHOP   = 3
PT_QUEEN    = 5
PT_KING     = 6
BOARD_SIZE  = 0x80

; ---- Eval struct field offsets (into E_BUF) --------------------------------
E_B        = 0
E_WK       = 2
E_BK       = 4
E_SCORE    = 6
E_NONPAWN  = 8
E_PAWNS    = 10
E_QUEENS   = 12
E_WBISH    = 14
E_BBISH    = 16
E_ENDGAME  = 18
E_PHASE    = 20
E_EGDIFF   = 22
E_WPF      = 24
E_BPF      = 40
E_SIZE     = 56

; ---- Board field offsets ---------------------------------------------------
B_SQ        = 0
B_WTM       = 128
B_WK        = 130
B_BK        = 132
B_ACC_MAT   = 146
B_ACC_EGDIFF= 148
B_ACC_PHASE = 150

; ---- EvalWeights field offsets (g_w) -- confirmed via offsetof probe --------
; (mos-clang -fno-lto -Os -S; field offset = 2*field_index since int=16-bit.)
W_KNIGHT_OUTPOST        = 24
W_ADVANCED_PAWN         = 40
W_DEEP_ADVANCED_PAWN    = 42
W_HEAVY_SEVENTH_RANK    = 58
W_ENDGAME_NONPAWN_LIMIT = 60
W_TEMPO                 = 100
W_TRAPPED_PENALTY       = 102

; ---- extra C constants used by the inlined group-(a) terms ------------------
OFFBOARD_MASK = 0x88
WHITE_PAWN    = 0x81
BLACK_PAWN    = 0x01
WHITE_KNIGHT  = 0x82
BLACK_KNIGHT  = 0x02
WHITE_BISHOP  = 0x83
BLACK_BISHOP  = 0x03
WHITE_QUEEN   = 0x85
BLACK_QUEEN   = 0x05
PT_KNIGHT     = 2
PT_ROOK       = 4
SQ_BQ_HOME    = 0x03      ; black queen home (d8) for is_queen_attacked
SQ_WQ_HOME    = 0x73      ; white queen home (d1) for is_queen_attacked

; ============================================================================
; OFFSET TABLES (compile-time constant; embedded here, NOT externalized).
; Only the LOW byte matters (add8 = (sq+off)&0xFF). Values from eval.c 142-145.
; ============================================================================
	.section	.rodata.eval_full_6502,"a",@progbits
KNIGHT_OFFS:   .byte 0xDF,0xE1,0xEE,0xF2,0x0E,0x12,0x1F,0x21   ; KNIGHT_OFFSETS[8]
DIAG_OFFS:     .byte 0xEF,0xF1,0x0F,0x11                       ; DIAGONAL_OFFSETS[4]
ORTHO_OFFS:    .byte 0xF0,0x10,0xFF,0x01                       ; ORTHOGONAL_OFFSETS[4]
ALLDIR_OFFS:   .byte 0xEF,0xF0,0xF1,0xFF,0x01,0x0F,0x10,0x11   ; ALL_DIRECTION_OFFSETS[8]

; ============================================================================
; .bss  --  persistent eval state (eval_full is non-recursive: static buffers).
; crt0 zeroes .bss before main, so the counters/wpf/bpf are 0 at entry, but the
; corpus runs eval_full repeatedly without re-zeroing, so we MUST clear the
; counters ourselves at entry (the C does `e.nonpawn=0;...` and `wpf/bpf=0`).
; ============================================================================
	.section	.bss.eval_full_6502,"aw",@nobits
	.p2align	0
E_BUF:    .zero  E_SIZE      ; the Eval struct
BPTR:     .zero  2           ; saved Board* (survives helper clobbers)
EVADDR:   .zero  2           ; cached &E_BUF (set once at entry; for arg1 reloads)
WALKX:    .zero  1           ; 0x88 loop index x (0..127, low byte; <128 so 1 byte)
CURPT:    .zero  1           ; current square's ptype  (survives helper clobbers)
CURCOL:   .zero  1           ; current square's color  (survives helper clobbers)
MDTMP:    .zero  2           ; scratch (mul/div blend hi-byte staging)

	.section	.text.eval_full,"ax",@progbits
	.type	eval_full,@function

; ============================================================================
eval_full:
; ---- save Board* (board ptr arrives in __rc2/3) ----------------------------
	lda	__rc2
	sta	BPTR
	lda	__rc3
	sta	BPTR+1
; cache &E_BUF for reloading the arg1 pointer before every helper call.
	lda	#<E_BUF
	sta	EVADDR
	lda	#>E_BUF
	sta	EVADDR+1

; ============================================================================
; SEED the Eval struct from the board (eval.c lines 1302-1322).
;   e.b   = board->sq      (== board ptr value, since sq is at offset 0)
;   e.wk  = board->wk
;   e.bk  = board->bk
;   e.score = board->acc_mat
;   e.phase = board->acc_phase
;   e.egdiff= board->acc_egdiff
;   nonpawn/pawns/queens/wbishops/bbishops/endgame = 0
;   wpf[0..7] = 0 ; bpf[0..7] = 0
; We use Y-indexed loads off BPTR (an indirect pointer in ZP) to read the
; board fields, and absolute stores into E_BUF.
; ============================================================================
; e.b = board->sq  (board pointer value; sq[] is at board offset 0)
	lda	BPTR
	sta	E_BUF + E_B
	lda	BPTR+1
	sta	E_BUF + E_B + 1

; Set up ZP indirect (__rc2/3) = BPTR so we can use (zp),Y to read board fields.
	lda	BPTR
	sta	__rc2
	lda	BPTR+1
	sta	__rc3

; e.wk = board->wk  (offset 130)
	ldy	#B_WK
	lda	(__rc2),y
	sta	E_BUF + E_WK
	iny
	lda	(__rc2),y
	sta	E_BUF + E_WK + 1
; e.bk = board->bk  (offset 132)
	ldy	#B_BK
	lda	(__rc2),y
	sta	E_BUF + E_BK
	iny
	lda	(__rc2),y
	sta	E_BUF + E_BK + 1
; e.score = board->acc_mat  (offset 146)
	ldy	#B_ACC_MAT
	lda	(__rc2),y
	sta	E_BUF + E_SCORE
	iny
	lda	(__rc2),y
	sta	E_BUF + E_SCORE + 1
; e.phase = board->acc_phase  (offset 150)
	ldy	#B_ACC_PHASE
	lda	(__rc2),y
	sta	E_BUF + E_PHASE
	iny
	lda	(__rc2),y
	sta	E_BUF + E_PHASE + 1
; e.egdiff = board->acc_egdiff  (offset 148)
	ldy	#B_ACC_EGDIFF
	lda	(__rc2),y
	sta	E_BUF + E_EGDIFF
	iny
	lda	(__rc2),y
	sta	E_BUF + E_EGDIFF + 1

; zero the counters (nonpawn,pawns,queens,wbishops,bbishops,endgame) + wpf/bpf.
; Offsets 8..55 are all counters/per-file arrays -> clear E_BUF+8 .. E_BUF+55.
	lda	#0
	ldy	#(E_SIZE - E_NONPAWN)     ; 56-8 = 48 bytes to clear
.Lseed_clr:
	sta	E_BUF + E_NONPAWN - 1, y  ; y runs 48..1 -> clears [E_NONPAWN .. E_SIZE-1]
	dey
	bne	.Lseed_clr

; ============================================================================
; MAIN BOARD PASS (eval.c lines 1330-1368):
;   for (x=0; x<128; x++, (x&0x08)?x+=8:0) { ... }
; The increment skips the offboard right half of every rank: after x++, if
; (x & 0x08) set, x += 8. We replicate by: process square x; then x++; if
; (x & 8) then x += 8; loop while x < 128.
; ============================================================================
	lda	#0
	sta	WALKX

.Lwalk:
; ---- load piece = b[x]; if EMPTY continue ----------------------------------
	lda	BPTR
	sta	__rc2
	lda	BPTR+1
	sta	__rc3
	ldy	WALKX
	lda	(__rc2),y          ; A = b[x]
	; if (piece == EMPTY) continue;
	bne	.Lnot_empty
	jmp	.Lwalk_next
.Lnot_empty:
; A = piece. Derive color = piece & 0x80, ptype = piece & 0x07 and stash both in
; .bss (CURPT/CURCOL) so they survive the helper jsr clobbers across the term
; block (every helper trashes the caller-saved imaginary regs).
	sta	__rc8              ; __rc8 = piece (volatile scratch, no call yet)
	and	#0x07
	sta	CURPT              ; ptype (1..6)
	lda	__rc8
	and	#WHITE_COLOR
	sta	CURCOL             ; color (0 or 0x80)

; ---- piece counters (eval.c 1339-1353) -------------------------------------
	lda	CURPT
	cmp	#PT_PAWN
	beq	.Lis_pawn
	jmp	.Lnot_pawn_counter
.Lis_pawn:
; e.pawns++
	inc	E_BUF + E_PAWNS
	bne	.Lpawns_nohi
	inc	E_BUF + E_PAWNS + 1
.Lpawns_nohi:
; per-file pawn count: file = x & 7 ; if (color) wpf[file]++ else bpf[file]++
; (inc abs,Y does not exist on the 6502 -- only inc abs,X -- so index with X.)
	lda	WALKX
	and	#0x07
	asl	a                  ; *2 (int array)
	tax                       ; x = file*2 (index into wpf/bpf)
	lda	CURCOL
	beq	.Lpf_black
; white: wpf[file]++
	inc	E_BUF + E_WPF, x
	bne	.Lpf_done
	inc	E_BUF + E_WPF + 1, x
	jmp	.Lpf_done
.Lpf_black:
; black: bpf[file]++
	inc	E_BUF + E_BPF, x
	bne	.Lpf_done
	inc	E_BUF + E_BPF + 1, x
.Lpf_done:
; ---- advanced_pawn (INLINE, eval.c 589-604) --------------------------------
; void advanced_pawn(e, sq, color, ptype): ptype guaranteed PAWN_T here.
;   row16 = sq & 0x70;
;   white(color!=0): ==0x30 -> +adv; >0x30 -> ret; ==0x00 -> ret; else +deep.
;   black(color==0): ==0x40 -> -adv; <0x50 -> ret; ==0x70 -> ret; else -deep.
; reload state from .bss (prior loop iteration / counters clobbered regs).
	lda	WALKX
	and	#0x70              ; A = row16
	ldy	CURCOL
	beq	.Lap_black
; --- white ---
	cmp	#0x30
	bne	.Lap_w_not30
; row16 == 0x30 -> e.score += g_w.advanced_pawn
	lda	g_w + W_ADVANCED_PAWN
	ldx	g_w + W_ADVANCED_PAWN + 1
	jsr	.Ls_score_addAX
	jmp	.Lpiece_terms
.Lap_w_not30:
	cmp	#0x30
	bcc	.Lap_w_lt30        ; row16 < 0x30
	jmp	.Lpiece_terms      ; row16 > 0x30 -> return
.Lap_w_lt30:
	cmp	#0x00
	bne	.Lap_w_deep
	jmp	.Lpiece_terms      ; row16 == 0x00 -> return
.Lap_w_deep:
; else (row16 in {0x10,0x20}) -> e.score += g_w.deep_advanced_pawn
	lda	g_w + W_DEEP_ADVANCED_PAWN
	ldx	g_w + W_DEEP_ADVANCED_PAWN + 1
	jsr	.Ls_score_addAX
	jmp	.Lpiece_terms
.Lap_black:
; --- black ---
	cmp	#0x40
	bne	.Lap_b_not40
; row16 == 0x40 -> e.score -= g_w.advanced_pawn
	lda	g_w + W_ADVANCED_PAWN
	ldx	g_w + W_ADVANCED_PAWN + 1
	jsr	.Ls_score_subAX
	jmp	.Lpiece_terms
.Lap_b_not40:
	cmp	#0x50
	bcs	.Lap_b_ge50        ; row16 >= 0x50
	jmp	.Lpiece_terms      ; row16 < 0x50 -> return
.Lap_b_ge50:
	cmp	#0x70
	bne	.Lap_b_deep
	jmp	.Lpiece_terms      ; row16 == 0x70 -> return
.Lap_b_deep:
; else (row16 in {0x50,0x60}) -> e.score -= g_w.deep_advanced_pawn
	lda	g_w + W_DEEP_ADVANCED_PAWN
	ldx	g_w + W_DEEP_ADVANCED_PAWN + 1
	jsr	.Ls_score_subAX
	jmp	.Lpiece_terms      ; pawns skip the nonpawn-counter block; go to term guard

.Lnot_pawn_counter:
; else if (ptype != KING_T) { nonpawn++; bishop/queen sub-counts }
	lda	CURPT
	cmp	#PT_KING
	bne	.Lcnt_nonking
	jmp	.Lpiece_terms      ; king: no counters; fall through to term guard
.Lcnt_nonking:
; e.nonpawn++
	inc	E_BUF + E_NONPAWN
	bne	.Lnp_nohi
	inc	E_BUF + E_NONPAWN + 1
.Lnp_nohi:
; if (ptype == BISHOP_T) { if (color) wbishops++ else bbishops++ }
	lda	CURPT
	cmp	#PT_BISHOP
	bne	.Lcnt_notbish
	lda	CURCOL
	beq	.Lbish_black
	inc	E_BUF + E_WBISH
	bne	.Lcnt_notbish
	inc	E_BUF + E_WBISH + 1
	jmp	.Lcnt_notbish
.Lbish_black:
	inc	E_BUF + E_BBISH
	bne	.Lcnt_notbish
	inc	E_BUF + E_BBISH + 1
.Lcnt_notbish:
; if (ptype == QUEEN_T) queens++
	lda	CURPT
	cmp	#PT_QUEEN
	bne	.Lpiece_terms
	inc	E_BUF + E_QUEENS
	bne	.Lpiece_terms
	inc	E_BUF + E_QUEENS + 1

; ---- per-piece term block (eval.c 1360-1367) -------------------------------
; if (ptype != PAWN_T && ptype != KING_T) { 6 term calls }
.Lpiece_terms:
	lda	CURPT
	cmp	#PT_PAWN
	bne	.Lpt_chkking
	jmp	.Lwalk_next        ; pawn: term block skipped (advanced_pawn already done)
.Lpt_chkking:
	cmp	#PT_KING
	bne	.Lpt_do
	jmp	.Lwalk_next        ; king: term block skipped
.Lpt_do:
; The six calls, in this EXACT order (must match eval.c / eval.s):
;   pawn_pressure, queen_pressure, minor_pressure, knight_outpost,
;   mobility, seventh_rank -- each (&e, x, color, ptype).
; Group (a) terms are INLINE; mobility/seventh_rank remain jsr-to-C.
; Set __rc2/3 = BPTR so the inlined probes can do (zp),Y board reads. The
; inline terms never jsr to C, so __rc2/3 survives until the first jsr (mobility).
	lda	BPTR
	sta	__rc2
	lda	BPTR+1
	sta	__rc3

; ---- pawn_pressure (INLINE, eval.c 481-486) --------------------------------
;   if (!is_pawn_attacked(e,sq,color,ptype)) return;
;   pen = ET_PAWN_ATTACK[ptype]; if (color) score-=pen else score+=pen.
	jsr	.Ls_pawn_attacked
	beq	.Lpp_done          ; not attacked -> skip
	lda	#<ET_PAWN_ATTACK
	sta	__rc10
	lda	#>ET_PAWN_ATTACK
	sta	__rc11
	jsr	.Ls_pressure_apply
.Lpp_done:

; ---- queen_pressure (INLINE, eval.c 488-493) -------------------------------
;   if (!is_queen_attacked(e,sq,color,ptype)) return;
;   pen = ET_QUEEN_ATTACK[ptype]; if (color) score-=pen else score+=pen.
; (__rc2/3 still = BPTR from above; no jsr-to-C since.)
	jsr	.Ls_queen_attacked
	beq	.Lqp_done
	lda	#<ET_QUEEN_ATTACK
	sta	__rc10
	lda	#>ET_QUEEN_ATTACK
	sta	__rc11
	jsr	.Ls_pressure_apply
.Lqp_done:

; ---- minor_pressure (INLINE, eval.c 495-504) -------------------------------
; (__rc2/3 still = BPTR from above; no jsr-to-C since.)
	jsr	.Ls_minor_pressure

; ---- knight_outpost (INLINE, eval.c 506-522) -------------------------------
; (__rc2/3 still = BPTR; the inlined terms above never jsr to C.)
	jsr	.Ls_knight_outpost

; ---- mobility (INLINE, eval.c 558-576) -------------------------------------
; (__rc2/3 still = BPTR from the .Lpt_do reload; the inline group-(a) terms
;  above never jsr to C, so it survives. .Ls_mobility needs it for board reads.)
	jsr	.Ls_mobility

; ---- seventh_rank (INLINE, eval.c 578-587) ---------------------------------
; (the C helper takes no board reads -- pure sq/color/ptype -- so __rc2/3 need
;  not be BPTR here. It reads all state fresh from .bss, so .Ls_mobility's
;  scratch clobbers are harmless.)
	jsr	.Ls_seventh_rank
	; fall through to walk_next

; ---- loop increment: x++; if (x & 8) x += 8; while (x < 128) --------------
.Lwalk_next:
	inc	WALKX
	lda	WALKX
	and	#0x08
	beq	.Lwalk_test       ; (x & 8)==0 -> no skip
	lda	WALKX
	clc
	adc	#8
	sta	WALKX
.Lwalk_test:
	lda	WALKX
	cmp	#BOARD_SIZE        ; x < 128 ?
	bcs	.Lwalk_done_j      ; x >= 128 -> done (near: target a few bytes away)
	jmp	.Lwalk
.Lwalk_done_j:
	; fall through

; ============================================================================
; ENDGAME FLAG (eval.c 1371-1375):
;   if (nonpawn < g_w.endgame_nonpawn_limit + 1) endgame = 1;
;   else if (nonpawn == g_w.endgame_nonpawn_limit + 1 && queens == 0) endgame=1;
; All ints are 16-bit signed. We compute limit1 = g_w.endgame_nonpawn_limit + 1
; (16-bit), then compare nonpawn vs limit1.
; ============================================================================
; __rc12/13 = limit1 = g_w.endgame_nonpawn_limit + 1
	clc
	lda	g_w + W_ENDGAME_NONPAWN_LIMIT
	adc	#1
	sta	__rc12
	lda	g_w + W_ENDGAME_NONPAWN_LIMIT + 1
	adc	#0
	sta	__rc13
; signed 16-bit compare: nonpawn < limit1 ?
; compute (nonpawn - limit1); signed-less-than via N != V.
	lda	E_BUF + E_NONPAWN
	sec
	sbc	__rc12
	lda	E_BUF + E_NONPAWN + 1
	sbc	__rc13
	; A = high byte of (nonpawn - limit1); V/N set from the sbc.
	bvc	.Leg_novf
	eor	#0x80              ; correct N for signed compare when V set
.Leg_novf:
	bpl	.Leg_check_eq      ; result >= 0 -> nonpawn >= limit1 -> check ==
; nonpawn < limit1 -> endgame = 1
	lda	#1
	sta	E_BUF + E_ENDGAME
	jmp	.Leg_done
.Leg_check_eq:
; else if (nonpawn == limit1 && queens == 0) endgame = 1
	lda	E_BUF + E_NONPAWN
	cmp	__rc12
	bne	.Leg_done
	lda	E_BUF + E_NONPAWN + 1
	cmp	__rc13
	bne	.Leg_done
	; nonpawn == limit1; now queens == 0 ?
	lda	E_BUF + E_QUEENS
	ora	E_BUF + E_QUEENS + 1
	bne	.Leg_done
	lda	#1
	sta	E_BUF + E_ENDGAME
.Leg_done:

; ============================================================================
; TAPERED PST BLEND (eval.c 1383-1387) -- guarded, CORPUS-COLD (egdiff always 0
; in the shipped config, so this body is never validated; it is a faithful port
; of the C source only):
;   if (e.egdiff) { int p=e.phase; if(p>24)p=24; e.score += egdiff*(24-p)/24; }
; 16-bit signed: __mulhi3 then __divhi3 (matches the compiler's codegen).
; ============================================================================
	lda	E_BUF + E_EGDIFF
	ora	E_BUF + E_EGDIFF + 1
	bne	.Lblend_do
	jmp	.Lblend_skip
.Lblend_do:
; p = e.phase; if (p > 24) p = 24   (signed compare p > 24)
	lda	E_BUF + E_PHASE
	sta	MDTMP
	lda	E_BUF + E_PHASE + 1
	sta	MDTMP+1
; signed compare: p > 24  <=>  24 - p < 0 ... do (p - 24) signed > 0.
; compute (p - 24); if result > 0 (i.e. >= 0 and != 0 ... but p>24 strictly).
; Simpler: if (p - 24) signed >= 1, clamp. Compare p vs 25 (p >= 25 => p > 24).
	lda	MDTMP
	sec
	sbc	#25
	lda	MDTMP+1
	sbc	#0
	bvc	.Lblend_novf
	eor	#0x80
.Lblend_novf:
	bmi	.Lblend_noclamp    ; (p-25) < 0 -> p <= 24 -> no clamp
; clamp p = 24
	lda	#24
	sta	MDTMP
	lda	#0
	sta	MDTMP+1
.Lblend_noclamp:
; (24 - p) -> __rc2/3  (first arg to __mulhi3)
	sec
	lda	#24
	sbc	MDTMP
	sta	__rc2
	lda	#0
	sbc	MDTMP+1
	sta	__rc3
; egdiff -> A/X  (second arg to __mulhi3): A=lo, X=hi
	lda	E_BUF + E_EGDIFF
	ldx	E_BUF + E_EGDIFF + 1
	jsr	__mulhi3           ; -> product in A/X (lo/hi)
; product -> A/X is dividend; divisor 24 -> __rc2/3
	pha
	lda	#24
	sta	__rc2
	lda	#0
	sta	__rc3
	pla
	jsr	__divhi3           ; signed 16-bit divide -> quotient A/X
; e.score += quotient
	clc
	adc	E_BUF + E_SCORE
	sta	E_BUF + E_SCORE
	txa
	adc	E_BUF + E_SCORE + 1
	sta	E_BUF + E_SCORE + 1
.Lblend_skip:

; ============================================================================
; TAIL (eval.c 1390-1397):
;   bishop_pair(&e);
;   if (e.pawns != 0) pawn_structure(&e);
;   if (e.endgame) endgame(&e); else { king_pins(&e); king_safety(&e); }
; ============================================================================
; bishop_pair(&e)
	jsr	.Lset_e_ptr
	jsr	bishop_pair
; if (e.pawns != 0) pawn_structure(&e)
	lda	E_BUF + E_PAWNS
	ora	E_BUF + E_PAWNS + 1
	beq	.Ltail_nopawnstruct
	jsr	.Lset_e_ptr
	jsr	pawn_structure
.Ltail_nopawnstruct:
; if (e.endgame) endgame(&e); else { king_pins; king_safety }
	lda	E_BUF + E_ENDGAME
	ora	E_BUF + E_ENDGAME + 1
	beq	.Ltail_notend
	jsr	.Lset_e_ptr
	jsr	endgame
	jmp	.Ltail_done
.Ltail_notend:
	jsr	.Lset_e_ptr
	jsr	king_pins
	jsr	.Lset_e_ptr
	jsr	king_safety
.Ltail_done:

; ============================================================================
; A/B TERMS (eval.c 1400-1402): king_attack_escalation, pawn_storm,
; queen_attacks_minor -- each (&e).
; ============================================================================
	jsr	.Lset_e_ptr
	jsr	king_attack_escalation
	jsr	.Lset_e_ptr
	jsr	pawn_storm
	jsr	.Lset_e_ptr
	jsr	queen_attacks_minor

; ============================================================================
; TEMPO (eval.c 1404):
;   if (board->wtm) e.score += g_w.tempo; else e.score -= g_w.tempo;
; ============================================================================
	lda	BPTR
	sta	__rc2
	lda	BPTR+1
	sta	__rc3
	ldy	#B_WTM
	lda	(__rc2),y
	ldy	#(B_WTM + 1)
	ora	(__rc2),y          ; A |= hi byte -> nonzero iff wtm != 0
	beq	.Ltempo_black
; white to move: e.score += g_w.tempo
	clc
	lda	E_BUF + E_SCORE
	adc	g_w + W_TEMPO
	sta	E_BUF + E_SCORE
	lda	E_BUF + E_SCORE + 1
	adc	g_w + W_TEMPO + 1
	sta	E_BUF + E_SCORE + 1
	jmp	.Ltempo_done
.Ltempo_black:
; black to move: e.score -= g_w.tempo
	sec
	lda	E_BUF + E_SCORE
	sbc	g_w + W_TEMPO
	sta	E_BUF + E_SCORE
	lda	E_BUF + E_SCORE + 1
	sbc	g_w + W_TEMPO + 1
	sta	E_BUF + E_SCORE + 1
.Ltempo_done:

; ============================================================================
; WRAP + RETURN (eval.c 1407-1409):
;   s = (int)(e.score & 0xFFFF); if (s >= 0x8000) s -= 0x10000; return s;
; e.score is already a 16-bit value; reinterpreting the bit pattern as a signed
; 16-bit int is exactly the C two's-complement result. So just load score into
; the int-return registers: A = lo, X = hi.
; ============================================================================
	lda	E_BUF + E_SCORE
	ldx	E_BUF + E_SCORE + 1
	rts

; ============================================================================
; (.Lcall_term_args removed: with mobility + seventh_rank now inlined, no
;  per-piece 4-arg jsr-to-C helper remains. The surviving jsr-to-C tail terms
;  are all 1-arg (&e) and use .Lset_e_ptr.)
; ============================================================================

; ============================================================================
; .Lset_e_ptr -- set __rc2/3 = &E_BUF (arg1 for the 1-arg tail helpers).
; ============================================================================
.Lset_e_ptr:
	lda	EVADDR
	sta	__rc2
	lda	EVADDR+1
	sta	__rc3
	rts

; ============================================================================
; INLINE-TERM SUPPORT SUBROUTINES (group a). These are LOCAL to this asm and
; make NO jsr to C, so they may freely use A/X/Y and the caller-saved ZP
; scratch __rc8..__rc11. They never touch __rc2/3 (left holding the BPTR
; indirect by the callers that need (zp),Y board reads). E_SCORE is the live
; 16-bit uint16 accumulator at E_BUF+E_SCORE.
; ============================================================================

; .Ls_score_addAX -- e.score += (A=lo, X=hi), 16-bit modular add. Clobbers A.
.Ls_score_addAX:
	clc
	adc	E_BUF + E_SCORE
	sta	E_BUF + E_SCORE
	txa
	adc	E_BUF + E_SCORE + 1
	sta	E_BUF + E_SCORE + 1
	rts

; .Ls_score_subAX -- e.score -= (A=lo, X=hi), 16-bit modular sub. Clobbers A.
.Ls_score_subAX:
	sta	__rc8              ; stash subtrahend lo (we need score in A first)
	lda	E_BUF + E_SCORE
	sec
	sbc	__rc8
	sta	E_BUF + E_SCORE
	txa
	sta	__rc8              ; subtrahend hi
	lda	E_BUF + E_SCORE + 1
	sbc	__rc8
	sta	E_BUF + E_SCORE + 1
	rts

; .Ls_chk_wp -- check_white_pawn_at(e, idx): idx in A (8-bit; only low byte
;   matters since add8 already wrapped). Returns A=1 if b[idx]==WHITE_PAWN
;   else A=0 (Z set when not a white pawn). Requires __rc2/3 = BPTR.
;   eval.c 397-400: if (idx & 0x88) return 0; return b[idx]==0x81.
.Ls_chk_wp:
	tay
	and	#OFFBOARD_MASK
	bne	.Ls_chk_wp_no      ; offboard -> 0
	lda	(__rc2),y          ; b[idx]
	cmp	#WHITE_PAWN
	bne	.Ls_chk_wp_no
	lda	#1
	rts
.Ls_chk_wp_no:
	lda	#0
	rts

; .Ls_chk_bp -- check_black_pawn_at(e, idx). Same shape, BLACK_PAWN.
;   eval.c 401-404.
.Ls_chk_bp:
	tay
	and	#OFFBOARD_MASK
	bne	.Ls_chk_bp_no
	lda	(__rc2),y          ; b[idx]
	cmp	#BLACK_PAWN
	bne	.Ls_chk_bp_no
	lda	#1
	rts
.Ls_chk_bp_no:
	lda	#0
	rts

; .Ls_pawn_attacked -- is_pawn_attacked(e, sq=WALKX, color=CURCOL, ptype=CURPT).
;   eval.c 407-418. Returns A=1 if attacked else A=0 (Z set when not).
;   Caller MUST have ptype in 2..5 OR rely on this routine's guard.
;   Requires __rc2/3 = BPTR.
;   color!=0 (white piece): black pawns from sq-0x0F, sq-0x11.
;   color==0 (black piece): white pawns from sq+0x0F, sq+0x11.
.Ls_pawn_attacked:
; guard: if (ptype < KNIGHT_T || ptype >= KING_T) return 0
	lda	CURPT
	cmp	#PT_KNIGHT
	bcc	.Ls_pa_no          ; ptype < 2
	cmp	#PT_KING
	bcs	.Ls_pa_no          ; ptype >= 6
	lda	CURCOL
	beq	.Ls_pa_black
; white piece: check_black_pawn_at(sq + (-0x0F)) || (sq + (-0x11))
	lda	WALKX
	clc
	adc	#<(-0x0F)          ; +0xF1 == sq-0x0F (mod 256)
	jsr	.Ls_chk_bp
	bne	.Ls_pa_yes
	lda	WALKX
	clc
	adc	#<(-0x11)          ; +0xEF == sq-0x11
	jsr	.Ls_chk_bp
	bne	.Ls_pa_yes
	jmp	.Ls_pa_no
.Ls_pa_black:
; black piece: check_white_pawn_at(sq + 0x0F) || (sq + 0x11)
	lda	WALKX
	clc
	adc	#0x0F
	jsr	.Ls_chk_wp
	bne	.Ls_pa_yes
	lda	WALKX
	clc
	adc	#0x11
	jsr	.Ls_chk_wp
	bne	.Ls_pa_yes
	; fall through to no
.Ls_pa_no:
	lda	#0
	rts
.Ls_pa_yes:
	lda	#1
	rts

; .Ls_pressure_apply -- shared tail for pawn_pressure / queen_pressure:
;   pen lives at (table base in __rc10/11) indexed by ptype*2; apply signed by
;   CURCOL. Inputs: __rc10/11 = ET table base. Reads CURPT, CURCOL.
;     pen = table[ptype]; if (color) e.score -= pen; else e.score += pen.
; (16-bit read of the int[7] entry; pen may be 0 -> add/sub of 0 is a no-op,
;  matching the C which does the +/- unconditionally for pawn/queen pressure.)
.Ls_pressure_apply:
	lda	CURPT
	asl	a                  ; ptype*2
	tay
	lda	(__rc10),y         ; pen lo
	pha
	iny
	lda	(__rc10),y         ; pen hi
	tax
	pla                       ; A = pen lo, X = pen hi
	ldy	CURCOL
	beq	.Lpa_white_add
	jmp	.Ls_score_subAX    ; color!=0 -> e.score -= pen
.Lpa_white_add:
	jmp	.Ls_score_addAX    ; color==0 -> e.score += pen

; .Ls_dir_scan -- scan ONE sliding ray from WALKX in direction __rc8 (offset
;   byte), looking for enemy piece __rc9. eval.c ray loop shape (451-475 inner /
;   431-447 inner): ray=sq; for(;;){ ray=add8(ray,off); if(ray&0x88)break;
;     p=b[ray]; if(p==0)continue; if(p==enemy)return 1; break; } return 0.
;   Returns A=1 if found else A=0. Uses A/Y; PRESERVES X, __rc8/9, __rc2/3.
;   Requires __rc2/3 = BPTR.
.Ls_dir_scan:
	lda	WALKX              ; ray = sq
.Lds_loop:
	clc
	adc	__rc8              ; ray = add8(ray, off)
	tay                       ; Y = ray (index for b[ray])
	and	#OFFBOARD_MASK
	bne	.Lds_no            ; ray & 0x88 -> break -> not found
	lda	(__rc2),y          ; p = b[ray]
	beq	.Lds_cont          ; p == EMPTY -> continue
	cmp	__rc9
	beq	.Lds_yes           ; p == enemy -> found
	bne	.Lds_no            ; else -> break (blocked)
.Lds_cont:
	tya                       ; A = ray; loop re-adds off
	jmp	.Lds_loop
.Lds_yes:
	lda	#1
	rts
.Lds_no:
	lda	#0
	rts

; .Ls_queen_attacked -- is_queen_attacked(e, sq, color, ptype). eval.c 451-476.
;   guard: ptype in [KNIGHT_T, ROOK_T) i.e. 2..3 (minors only).
;   white(color!=0): if b[0x03]!=BLACK_QUEEN return 0; enemy=BLACK_QUEEN.
;   black(color==0): if b[0x73]!=WHITE_QUEEN return 0; enemy=WHITE_QUEEN.
;   then 8-direction ray scan over ALL_DIRECTION_OFFSETS for enemy queen.
;   Returns A=1/0. Requires __rc2/3 = BPTR. Reads WALKX/CURPT/CURCOL.
.Ls_queen_attacked:
	lda	CURPT
	cmp	#PT_KNIGHT
	bcc	.Lqa_no            ; ptype < 2
	cmp	#PT_ROOK
	bcs	.Lqa_no            ; ptype >= 4
	ldy	CURCOL
	beq	.Lqa_black
; white piece: enemy black queen must sit on d8 ($03)
	ldy	#SQ_BQ_HOME
	lda	(__rc2),y
	cmp	#BLACK_QUEEN
	bne	.Lqa_no
	lda	#BLACK_QUEEN
	sta	__rc9
	jmp	.Lqa_scan
.Lqa_black:
; black piece: enemy white queen must sit on d1 ($73)
	ldy	#SQ_WQ_HOME
	lda	(__rc2),y
	cmp	#WHITE_QUEEN
	bne	.Lqa_no
	lda	#WHITE_QUEEN
	sta	__rc9
.Lqa_scan:
	ldx	#0                 ; X = direction index 0..7
.Lqa_dirloop:
	lda	ALLDIR_OFFS, x
	sta	__rc8
	jsr	.Ls_dir_scan       ; preserves X; A=1 if enemy queen on this ray
	cmp	#0
	bne	.Lqa_yes
	inx
	cpx	#8
	bcc	.Lqa_dirloop
.Lqa_no:
	lda	#0
	rts
.Lqa_yes:
	lda	#1
	rts

; .Ls_knight_attacked -- is_knight_attacked(e, sq, color). eval.c 420-429.
;   enemy = color ? BLACK_KNIGHT : WHITE_KNIGHT;
;   for 8 KNIGHT_OFFSETS: dest=add8(sq,off); if(dest&0x88)continue;
;     if(b[dest]==enemy)return 1; return 0.
;   Returns A=1/0. Requires __rc2/3 = BPTR. Reads WALKX/CURCOL. Uses A/X/Y.
.Ls_knight_attacked:
	lda	CURCOL
	beq	.Lka_white_enemy   ; color==0 -> enemy = WHITE_KNIGHT
	lda	#BLACK_KNIGHT
	bne	.Lka_setenemy      ; (always taken; BLACK_KNIGHT != 0)
.Lka_white_enemy:
	lda	#WHITE_KNIGHT
.Lka_setenemy:
	sta	__rc9              ; enemy
	ldx	#0
.Lka_loop:
	lda	WALKX
	clc
	adc	KNIGHT_OFFS, x     ; dest = add8(sq, off)
	tay
	and	#OFFBOARD_MASK
	bne	.Lka_next          ; dest & 0x88 -> continue
	lda	(__rc2),y          ; b[dest]
	cmp	__rc9
	beq	.Lka_yes
.Lka_next:
	inx
	cpx	#8
	bcc	.Lka_loop
	lda	#0
	rts
.Lka_yes:
	lda	#1
	rts

; .Ls_bishop_attacked -- is_bishop_attacked(e, sq, color). eval.c 431-447.
;   enemy = color ? BLACK_BISHOP : WHITE_BISHOP;
;   4-direction ray scan over DIAGONAL_OFFSETS for enemy bishop.
;   Returns A=1/0. Requires __rc2/3 = BPTR. Reads WALKX/CURCOL.
.Ls_bishop_attacked:
	lda	CURCOL
	beq	.Lba_white_enemy
	lda	#BLACK_BISHOP
	bne	.Lba_setenemy
.Lba_white_enemy:
	lda	#WHITE_BISHOP
.Lba_setenemy:
	sta	__rc9              ; enemy
	ldx	#0
.Lba_dirloop:
	lda	DIAG_OFFS, x
	sta	__rc8
	jsr	.Ls_dir_scan       ; preserves X; A=1 if enemy bishop on this ray
	cmp	#0
	bne	.Lba_yes
	inx
	cpx	#4
	bcc	.Lba_dirloop
	lda	#0
	rts
.Lba_yes:
	lda	#1
	rts

; .Ls_minor_pressure -- minor_pressure(e, sq, color, ptype). eval.c 495-504.
;   if (ptype < ROOK_T || ptype >= KING_T) return;   (rook=4, queen=5 only)
;   attacked = is_knight_attacked; if(!attacked) attacked = is_bishop_attacked;
;   if(!attacked) return;
;   pen = ET_MINOR_ATTACK[ptype]; if(pen==0)return; +/- pen by color.
;   (pen==0 short-circuit is numerically a no-op vs add/sub 0, so we reuse
;    .Ls_pressure_apply: bit-exact.)  Requires __rc2/3 = BPTR.
.Ls_minor_pressure:
	lda	CURPT
	cmp	#PT_ROOK
	bcc	.Lmp_ret           ; ptype < 4
	cmp	#PT_KING
	bcs	.Lmp_ret           ; ptype >= 6
	jsr	.Ls_knight_attacked
	bne	.Lmp_attacked
	jsr	.Ls_bishop_attacked
	beq	.Lmp_ret           ; neither -> return
.Lmp_attacked:
	lda	#<ET_MINOR_ATTACK
	sta	__rc10
	lda	#>ET_MINOR_ATTACK
	sta	__rc11
	jmp	.Ls_pressure_apply ; tail-call (rts)
.Lmp_ret:
	rts

; .Ls_knight_outpost -- knight_outpost(e, sq, color, ptype). eval.c 506-522.
;   if (ptype != KNIGHT_T) return;
;   file = sq & 7; if (file<2 || file>=6) return;
;   if (is_pawn_attacked(...)) return;
;   row16 = sq & 0x70;
;   white(color!=0): if(row16<0x20||row16>=0x50)ret;
;       if(chk_wp(sq+0x0F)||chk_wp(sq+0x11)) score += g_w.knight_outpost;
;   black(color==0): if(row16<0x30||row16>=0x60)ret;
;       if(chk_bp(sq-0x0F)||chk_bp(sq-0x11)) score -= g_w.knight_outpost.
;   Requires __rc2/3 = BPTR. Reads WALKX/CURPT/CURCOL.
.Ls_knight_outpost:
	lda	CURPT
	cmp	#PT_KNIGHT
	beq	.Lko_isknight
	rts                       ; ptype != KNIGHT_T
.Lko_isknight:
	lda	WALKX
	and	#0x07              ; file
	cmp	#2
	bcc	.Lko_ret           ; file < 2
	cmp	#6
	bcs	.Lko_ret           ; file >= 6
	jsr	.Ls_pawn_attacked
	bne	.Lko_ret           ; attacked -> return
	lda	WALKX
	and	#0x70              ; row16
	ldy	CURCOL
	beq	.Lko_black
; --- white: row16 in [0x20, 0x50) ---
	cmp	#0x20
	bcc	.Lko_ret           ; row16 < 0x20
	cmp	#0x50
	bcs	.Lko_ret           ; row16 >= 0x50
	lda	WALKX
	clc
	adc	#0x0F
	jsr	.Ls_chk_wp
	bne	.Lko_w_add
	lda	WALKX
	clc
	adc	#0x11
	jsr	.Ls_chk_wp
	beq	.Lko_ret           ; neither -> no bonus
.Lko_w_add:
	lda	g_w + W_KNIGHT_OUTPOST
	ldx	g_w + W_KNIGHT_OUTPOST + 1
	jmp	.Ls_score_addAX    ; e.score += g_w.knight_outpost; (tail-call, rts)
.Lko_black:
; --- black: row16 in [0x30, 0x60) ---
	cmp	#0x30
	bcc	.Lko_ret           ; row16 < 0x30
	cmp	#0x60
	bcs	.Lko_ret           ; row16 >= 0x60
	lda	WALKX
	clc
	adc	#<(-0x0F)          ; sq - 0x0F
	jsr	.Ls_chk_bp
	bne	.Lko_b_sub
	lda	WALKX
	clc
	adc	#<(-0x11)          ; sq - 0x11
	jsr	.Ls_chk_bp
	beq	.Lko_ret
.Lko_b_sub:
	lda	g_w + W_KNIGHT_OUTPOST
	ldx	g_w + W_KNIGHT_OUTPOST + 1
	jmp	.Ls_score_subAX    ; e.score -= g_w.knight_outpost; (tail-call, rts)
.Lko_ret:
	rts

; .Ls_seventh_rank -- seventh_rank(e, sq, color, ptype). eval.c 578-587.
;   if (ptype != ROOK_T && ptype != QUEEN_T) return;
;   row16 = sq & 0x70;
;   white(color!=0): if (row16 == 0x10) e.score += g_w.heavy_seventh_rank;
;   black(color==0): if (row16 == 0x60) e.score -= g_w.heavy_seventh_rank;
;   Reads WALKX/CURPT/CURCOL. No board reads (no __rc2/3 dependency).
.Ls_seventh_rank:
	lda	CURPT
	cmp	#PT_ROOK
	beq	.Lsr_ok            ; ptype == ROOK_T
	cmp	#PT_QUEEN
	beq	.Lsr_ok            ; ptype == QUEEN_T
	rts                       ; neither rook nor queen
.Lsr_ok:
	lda	WALKX
	and	#0x70              ; row16
	ldy	CURCOL
	beq	.Lsr_black
; --- white: row16 == 0x10 -> e.score += heavy_seventh_rank ---
	cmp	#0x10
	beq	.Lsr_w_add
	rts
.Lsr_w_add:
	lda	g_w + W_HEAVY_SEVENTH_RANK
	ldx	g_w + W_HEAVY_SEVENTH_RANK + 1
	jmp	.Ls_score_addAX    ; tail-call (rts)
.Lsr_black:
; --- black: row16 == 0x60 -> e.score -= heavy_seventh_rank ---
	cmp	#0x60
	beq	.Lsr_b_sub
	rts
.Lsr_b_sub:
	lda	g_w + W_HEAVY_SEVENTH_RANK
	ldx	g_w + W_HEAVY_SEVENTH_RANK + 1
	jmp	.Ls_score_subAX    ; tail-call (rts)

; ============================================================================
; .Ls_mobility -- mobility(e, sq, color, ptype). eval.c 558-576.
;   dispatch raw count by ptype (knight = single-step 8 offsets; bishop/rook/
;   queen = sliding ray scan over DIAG(4)/ORTHO(4)/ALLDIR(8)); pawn/king return.
;   then:  if (raw==0) { color ? score-=trapped : score+=trapped; }
;          half = raw>>1; if (half==0) return;
;          contrib = half*10 = (half<<1)+(half<<3);
;          color ? score+=contrib : score-=contrib.
;   ORDER matters: trapped check (raw==0) BEFORE the half computation; raw==0
;   implies half==0 so they are mutually exclusive (faithful to the C).
;   Requires __rc2/3 = BPTR. Reads WALKX/CURPT/CURCOL. Scratch: A/X/Y,
;   __rc8 (color cache), __rc9 (count), __rc10/11 (offset table), __rc12 (n).
; ----------------------------------------------------------------------------
; NB the mobility "count" test is (piece & 0x80) != color -- counts EMPTY OR
; ENEMY squares -- which is DIFFERENT from group (a)'s exact-enemy-byte attack
; probes. Implemented via:  (b[idx] & 0x80) eor color  -> nonzero iff enemy.
.Ls_mobility:
	lda	CURPT
	cmp	#PT_KNIGHT
	bne	.Lmob_chk_bishop
	jsr	.Ls_mob_knight     ; A = raw
	jmp	.Lmob_apply
.Lmob_chk_bishop:
	cmp	#PT_BISHOP
	bne	.Lmob_chk_rook
	lda	#<DIAG_OFFS
	sta	__rc10
	lda	#>DIAG_OFFS
	sta	__rc11
	lda	#4
	sta	__rc12
	jsr	.Ls_mob_slide      ; A = raw
	jmp	.Lmob_apply
.Lmob_chk_rook:
	cmp	#PT_ROOK
	bne	.Lmob_chk_queen
	lda	#<ORTHO_OFFS
	sta	__rc10
	lda	#>ORTHO_OFFS
	sta	__rc11
	lda	#4
	sta	__rc12
	jsr	.Ls_mob_slide      ; A = raw
	jmp	.Lmob_apply
.Lmob_chk_queen:
	cmp	#PT_QUEEN
	beq	.Lmob_queen
	rts                       ; not a mobile piece type -> return
.Lmob_queen:
	lda	#<ALLDIR_OFFS
	sta	__rc10
	lda	#>ALLDIR_OFFS
	sta	__rc11
	lda	#8
	sta	__rc12
	jsr	.Ls_mob_slide      ; A = raw
	; fall through to apply

; ---- apply: raw count in A (eval.c 567-575) --------------------------------
.Lmob_apply:
	tay                       ; Y = raw (preserve while testing raw==0)
	bne	.Lmob_not_trapped
; raw == 0 -> trapped: color ? score-=trapped : score+=trapped
	lda	g_w + W_TRAPPED_PENALTY
	ldx	g_w + W_TRAPPED_PENALTY + 1
	ldy	CURCOL
	beq	.Lmob_trap_white   ; color==0 (black piece) -> += trapped
	jmp	.Ls_score_subAX    ; color!=0 (white piece) -> -= trapped (tail rts)
.Lmob_trap_white:
	jmp	.Ls_score_addAX    ; black piece -> += trapped (tail rts)
.Lmob_not_trapped:
; half = raw >> 1; if (half==0) return
	tya                       ; A = raw
	lsr	a                  ; A = raw >> 1 = half
	bne	.Lmob_have_half
	rts                       ; half == 0 -> no contribution
.Lmob_have_half:
; contrib = half*10 = (half<<1) + (half<<3). half <= ~13 so contrib <= ~130:
;   fits a byte, but score add/sub is 16-bit -> compute 16-bit contrib in A/X.
;   half<<1 (call it h2) + half<<3 (h8). All single-byte intermediates here;
;   high byte = 0 (max 130 < 256), so X (contrib hi) = 0.
	sta	__rc9              ; __rc9 = half
	asl	a                  ; A = half*2
	sta	__rc8              ; __rc8 = half*2  (= h2)
	lda	__rc9
	asl	a
	asl	a
	asl	a                  ; A = half*8  (= h8)
	clc
	adc	__rc8              ; A = half*8 + half*2 = half*10  (contrib lo)
	ldx	#0                 ; contrib hi = 0
	ldy	CURCOL
	beq	.Lmob_ctb_black    ; color==0 (black piece) -> score -= contrib
	jmp	.Ls_score_addAX    ; color!=0 (white piece) -> score += contrib (tail)
.Lmob_ctb_black:
	jmp	.Ls_score_subAX    ; black piece -> score -= contrib (tail)

; ----------------------------------------------------------------------------
; .Ls_mob_knight -- count_knight_mobility(e, sq, color). eval.c 524-536.
;   for 8 KNIGHT_OFFSETS: dest=add8(sq,off); if(dest&0x88)continue;
;     p=b[dest]; if(p==EMPTY)count++; else if((p&0x80)!=color)count++.
;   Returns A = count. Requires __rc2/3 = BPTR. Reads WALKX/CURCOL.
;   Scratch: A/X/Y, __rc8 (color), __rc9 (count).
.Ls_mob_knight:
	lda	CURCOL
	sta	__rc8              ; color (0 or 0x80)
	lda	#0
	sta	__rc9              ; count = 0
	ldx	#0                 ; X = offset index 0..7
.Lmk_loop:
	lda	WALKX
	clc
	adc	KNIGHT_OFFS, x     ; dest = add8(sq, off)
	tay
	and	#OFFBOARD_MASK
	bne	.Lmk_next          ; dest & 0x88 -> continue
	lda	(__rc2),y          ; p = b[dest]
	beq	.Lmk_count         ; p == EMPTY -> count++
	and	#WHITE_COLOR       ; p & 0x80
	eor	__rc8              ; (p & 0x80) ^ color -> nonzero iff enemy
	beq	.Lmk_next          ; equal color (friendly) -> skip
.Lmk_count:
	inc	__rc9
.Lmk_next:
	inx
	cpx	#8
	bcc	.Lmk_loop
	lda	__rc9              ; A = count
	rts

; ----------------------------------------------------------------------------
; .Ls_mob_slide -- count_sliding_mobility(e, sq, color, offsets, n). eval.c 538-556.
;   for each of n offsets: ray=sq; loop{ ray=add8(ray,off); if(ray&0x88)break;
;     p=b[ray]; if(p==EMPTY){count++;continue;} if((p&0x80)!=color)count++; break; }
;   Returns A = count. Requires __rc2/3 = BPTR. Reads WALKX/CURCOL.
;   Inputs: __rc10/11 = offset table base, __rc12 = n.
;   Scratch: A/X/Y, __rc8 (color), __rc9 (count), __rc13 (current offset),
;            __rc14 (offset index), __rc15 (ray).
.Ls_mob_slide:
	lda	CURCOL
	sta	__rc8              ; color
	lda	#0
	sta	__rc9              ; count = 0
	sta	__rc14             ; offset index = 0
.Lms_dir:
	ldy	__rc14
	lda	(__rc10),y         ; off = offsets[i]
	sta	__rc13             ; __rc13 = off
	lda	WALKX
	sta	__rc15             ; ray = sq
.Lms_step:
	lda	__rc15
	clc
	adc	__rc13             ; ray = add8(ray, off)
	sta	__rc15
	tay
	and	#OFFBOARD_MASK
	bne	.Lms_dir_done      ; ray & 0x88 -> break this ray
	lda	(__rc2),y          ; p = b[ray]
	beq	.Lms_empty         ; p == EMPTY -> count++, continue ray
	and	#WHITE_COLOR       ; p & 0x80
	eor	__rc8              ; (p & 0x80) ^ color
	beq	.Lms_dir_done      ; friendly -> break (no count)
	inc	__rc9              ; enemy -> count++
	jmp	.Lms_dir_done      ; then break
.Lms_empty:
	inc	__rc9              ; empty -> count++
	jmp	.Lms_step          ; continue this ray
.Lms_dir_done:
	inc	__rc14             ; next offset
	lda	__rc14
	cmp	__rc12             ; i < n ?
	bcc	.Lms_dir
	lda	__rc9              ; A = count
	rts

.Lfunc_end_eval_full:
	.size	eval_full, .Lfunc_end_eval_full-eval_full
