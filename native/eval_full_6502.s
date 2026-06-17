; ============================================================================
; eval_full_6502.s  --  hand-written 6502 (llvm-mos / mos-sim) eval_full().
;
; BRING-UP SKELETON for the wholesale eval_full hand-asm project
; (docs/eval-asm-scope.md, phase 2). This file implements the eval_full
; STRUCTURE in asm -- the 0x88 board walk, every per-piece COUNTER, the endgame
; flag, the tapered-blend guard, the tempo term, and the final 16-bit wrap --
; but for the 15 positional TERM helpers it does NOT inline them yet: it `jsr`s
; to the existing C functions in native/eval.c (which expose external linkage via
; the EVAL_HELPER macro when CREF_ASM_EVAL_FULL is defined). Later phase-2
; sessions replace those jsr-to-C calls one at a time with inline asm,
; re-validating 22157/22157 each step. DO NOT inline the term math here.
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
;     +60   int endgame_nonpawn_limit
;     +100  int tempo
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

	.globl	eval_full
	.globl	g_w

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

; ---- EvalWeights field offsets (g_w) --------------------------------------
W_ENDGAME_NONPAWN_LIMIT = 60
W_TEMPO                 = 100

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
; advanced_pawn(&e, x, color, ptype)
	jsr	.Lcall_term_args   ; sets up __rc2/3=e, A/X=sq, __rc4/5=color, __rc6/7=ptype
	jsr	advanced_pawn
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
	jsr	.Lcall_term_args
	jsr	pawn_pressure
	jsr	.Lcall_term_args
	jsr	queen_pressure
	jsr	.Lcall_term_args
	jsr	minor_pressure
	jsr	.Lcall_term_args
	jsr	knight_outpost
	jsr	.Lcall_term_args
	jsr	mobility
	jsr	.Lcall_term_args
	jsr	seventh_rank
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
; .Lcall_term_args -- set up the 4-arg helper ABI from the current loop state:
;   __rc2/3 = &E_BUF      (arg1 e)
;   A / X   = sq (=WALKX) / 0   (arg2 sq)
;   __rc4/5 = color / 0   (arg3 color, from CURCOL)
;   __rc6/7 = ptype / 0   (arg4 ptype, from CURPT)
; color/ptype come from .bss (CURCOL/CURPT) so they are reconstructed fresh
; before EACH helper call -- the previous helper clobbered the caller-saved regs,
; but .bss is untouched. Returns with A/X = sq ready; caller immediately jsr's
; the helper.
; ============================================================================
.Lcall_term_args:
	lda	EVADDR
	sta	__rc2
	lda	EVADDR+1
	sta	__rc3
	lda	CURCOL             ; color
	sta	__rc4
	lda	#0
	sta	__rc5
	lda	CURPT              ; ptype
	sta	__rc6
	lda	#0
	sta	__rc7
	ldx	#0                 ; sq hi = 0
	lda	WALKX              ; sq lo = x
	rts

; ============================================================================
; .Lset_e_ptr -- set __rc2/3 = &E_BUF (arg1 for the 1-arg tail helpers).
; ============================================================================
.Lset_e_ptr:
	lda	EVADDR
	sta	__rc2
	lda	EVADDR+1
	sta	__rc3
	rts

.Lfunc_end_eval_full:
	.size	eval_full, .Lfunc_end_eval_full-eval_full
