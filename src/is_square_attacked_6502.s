; ============================================================================
; is_square_attacked_6502.s
;
; Hand-written 6502 assembly replacement for native/movegen.c's
; is_square_attacked(), compiled by llvm-mos (mos-sim) and linked INSTEAD of
; the C body for the 6502 image. BIT-IDENTICAL behavior to the C function.
;
; This file is built ONLY for the mos-sim 6502 image. The C body in movegen.c
; is #ifdef'd out when CREF_ASM_IS_SQUARE_ATTACKED is defined (the build passes
; -DCREF_ASM_IS_SQUARE_ATTACKED only on the mos-sim compile of movegen.c, and
; adds this .s to the link line). The host (clang) build keeps the C body.
;
; ----------------------------------------------------------------------------
; ABI (derived empirically from `mos-sim-clang -Os -S -fno-lto movegen.c`, and
; confirmed against MOSCallingConv.td: A/X/Y + RS1..RS9 are caller-saved;
; RS0 (=__rc0/1, the soft stack pointer) and RS10..RS15 (=__rc20..__rc31) are
; callee-saved):
;   C prototype: int is_square_attacked(const Board *b, int sq, int by_white)
;
;   in:  b        ptr   -> __rc2 (lo) / __rc3 (hi)   (points at b->sq[0])
;        sq       i16   -> A (lo) / X (hi)           (0..119, hi always 0)
;        by_white i16   -> __rc4 (lo) / __rc5 (hi)   (truthy if either != 0)
;   out: int (range 0..1) -> A (lo) / X (hi=0)
;
;   Clobbers: A, X, Y and caller-saved imaginary regs (we use only __rc8..__rc12,
;   all in RS4..RS6, caller-saved). No callee-saved regs are touched, so there is
;   no save/restore.
;
; Scratch zero-page (all caller-saved, free to clobber):
;   __rc8  = sq            (target square, low byte)
;   __rc9  = color_match   (0x80 if by_white, else 0x00)
;   __rc10 = ray offset    (signed delta added each step on a slider ray)
;   __rc11 = table index   (slider direction index)
;   __rc12 = piece scratch
;   __rc13 = target piece byte (PT_x | color_match) for single-CMP loops
;   b pointer stays in __rc2/__rc3 and is the (zp),Y base.
;
; BRANCH-RANGE NOTE: this function is ~340 bytes, larger than the 8-bit
; conditional-branch reach (-128..+127). The integrated assembler silently
; emits a TRUNCATED displacement for an out-of-range bcc/bcs/beq/bne rather than
; erroring, which corrupts control flow. So every conditional branch whose target
; could be far uses the invert-and-JMP idiom (bcc/bne over a 3-byte absolute jmp);
; JMP is 16-bit absolute and always in range. Short branches are only used for
; provably-near targets (loop backedges, adjacent fall-throughs).
;
; Board geometry (board.h):
;   piece byte = type | (0x80 if white); empty = 0; type 1..6 = P,N,B,R,Q,K
;   offboard test: (idx & 0x88) != 0
;   index = (7-rank)*16 + file, a8=0 .. h1=119
; ============================================================================

	.zeropage	__rc2
	.zeropage	__rc3
	.zeropage	__rc4
	.zeropage	__rc5
	.zeropage	__rc8
	.zeropage	__rc9
	.zeropage	__rc10
	.zeropage	__rc11
	.zeropage	__rc12
	.zeropage	__rc13

	.section	.text.is_square_attacked,"ax",@progbits
	.globl	is_square_attacked
	.type	is_square_attacked,@function

PT_PAWN   = 1
PT_KNIGHT = 2
PT_BISHOP = 3
PT_ROOK   = 4
PT_QUEEN  = 5
PT_KING   = 6

is_square_attacked:
	; sq (low byte) -> __rc8.  High byte (X) ignored: sq is always 0..119.
	sta	__rc8

	; color_match = by_white ? 0x80 : 0x00.  by_white truthy iff (rc4|rc5)!=0.
	lda	__rc4
	ora	__rc5
	beq	.Lcm_black
	lda	#$80
	sta	__rc9
	jmp	.Lpawns
.Lcm_black:
	lda	#$00
	sta	__rc9
	jmp	.Lpawns               ; MUST jump: the return blocks below are not
	                              ; part of the fall-through path.

; ---------------------------------------------------------------------------
; The two return blocks live HIGH in the function so the top sections can reach
; .Lhit via short branches, and so .Lhit/.Lmiss are a single source of truth.
; Control never FALLS into them -- it only branches/jumps here. (Far sections
; reach them with absolute JMP, near sections with short branches.)
; ---------------------------------------------------------------------------
.Lhit:
	lda	#1
	ldx	#0
	rts
.Lmiss:
	lda	#0
	ldx	#0
	rts

; ===========================================================================
; 1) PAWN attacks.
;    White pawn attackers sit on sq+15, sq+17; black on sq-15, sq-17.
;    color_match encodes the side, so the per-square test is identical:
;       on-board && PT(p)==PAWN && (p & 0x80)==color_match
; ===========================================================================
.Lpawns:
	; target = PT_PAWN | color_match. A piece byte is EXACTLY type|colorbit
	; (board.h), so the C test "on-board && (p&7)==PAWN && (p&0x80)==cm" is just
	; a single CMP against the target (empty=0 never matches). Same one-CMP trick
	; the knight/king scans use; this also kills the jsr/rts to .Lcheck_pawn.
	;
	; sq is held in X across the whole pawn+knight+king block (X is otherwise free
	; until .Lbishops re-uses it), so each target is formed with `txa` (2cyc)
	; instead of reloading `lda __rc8` (3cyc) -- 1 cyc saved per check on the hot
	; (full-scan) path, 20 checks.
	ldx	__rc8                 ; X = sq (invariant through pawn/knight/king)
	lda	#PT_PAWN
	ora	__rc9
	sta	__rc13                ; __rc13 = target pawn byte
	lda	__rc9
	bne	.Lpawn_white          ; color_match==0x80 -> white -> +15/+17
	; black: attackers on sq-15 ($F1) and sq-17 ($EF)
	txa
	clc
	adc	#$F1                  ; sq - 15
	tay
	and	#$88
	bne	.Lbpawn2              ; off-board -> try other diagonal
	lda	(__rc2),y
	cmp	__rc13
	beq	.Lhit
.Lbpawn2:
	txa
	clc
	adc	#$EF                  ; sq - 17
	tay
	and	#$88
	bne	.Lknights             ; off-board -> done with pawns
	lda	(__rc2),y
	cmp	__rc13
	beq	.Lhit
	jmp	.Lknights
.Lpawn_white:
	; white: attackers on sq+15 and sq+17
	txa
	clc
	adc	#15                   ; sq + 15
	tay
	and	#$88
	bne	.Lwpawn2
	lda	(__rc2),y
	cmp	__rc13
	beq	.Lhit
.Lwpawn2:
	txa
	clc
	adc	#17                   ; sq + 17
	tay
	and	#$88
	bne	.Lknights             ; off-board -> done with pawns
	lda	(__rc2),y
	cmp	__rc13
	beq	.Lhit
	; fall through to knights

; ===========================================================================
; 2) KNIGHT attacks.  8 fixed offsets.
; ===========================================================================
; Knight check inlined (was: jsr .Lcheck_knight).  Eliminates the jsr/rts
; (12 cyc) + carry handshake per iteration; all branch targets here are local
; and provably near, so short branches are safe.
.Lknights:
	; target = PT_KNIGHT | color_match. A piece byte is EXACTLY type|colorbit
	; (no other bits ever set, board.h), so a single CMP against the target
	; matches type AND color in one shot -- and empty(0) never equals the
	; nonzero target, so the empty-check folds in too.
	;
	; FULLY UNROLLED (was an 8-iteration loop over knight_off[]). Each offset is
	; an immediate, killing the abs,x table index AND the inx/cpx/bne loop tax
	; (~6-9 cyc/iter). On a match we invert-and-jmp to .Lhit (far, out of branch
	; range); the jmp only runs on a hit (rare), so the no-match hot path is just
	; a not-taken bne. Empty/wrong-piece both fall through the cmp's bne.
	lda	#PT_KNIGHT
	ora	__rc9
	sta	__rc13                ; __rc13 = target knight byte
	; -- knight check #1: sq-33 ($DF) --
	txa
	clc
	adc	#$DF
	tay
	and	#$88
	bne	.Lkn1                 ; off-board -> next
	lda	(__rc2),y
	cmp	__rc13
	bne	.Lkn1
	jmp	.Lhit
.Lkn1:	; -- #2: sq-31 ($E1) --
	txa
	clc
	adc	#$E1
	tay
	and	#$88
	bne	.Lkn2
	lda	(__rc2),y
	cmp	__rc13
	bne	.Lkn2
	jmp	.Lhit
.Lkn2:	; -- #3: sq-18 ($EE) --
	txa
	clc
	adc	#$EE
	tay
	and	#$88
	bne	.Lkn3
	lda	(__rc2),y
	cmp	__rc13
	bne	.Lkn3
	jmp	.Lhit
.Lkn3:	; -- #4: sq-14 ($F2) --
	txa
	clc
	adc	#$F2
	tay
	and	#$88
	bne	.Lkn4
	lda	(__rc2),y
	cmp	__rc13
	bne	.Lkn4
	jmp	.Lhit
.Lkn4:	; -- #5: sq+14 ($0E) --
	txa
	clc
	adc	#$0E
	tay
	and	#$88
	bne	.Lkn5
	lda	(__rc2),y
	cmp	__rc13
	bne	.Lkn5
	jmp	.Lhit
.Lkn5:	; -- #6: sq+18 ($12) --
	txa
	clc
	adc	#$12
	tay
	and	#$88
	bne	.Lkn6
	lda	(__rc2),y
	cmp	__rc13
	bne	.Lkn6
	jmp	.Lhit
.Lkn6:	; -- #7: sq+31 ($1F) --
	txa
	clc
	adc	#$1F
	tay
	and	#$88
	bne	.Lkn7
	lda	(__rc2),y
	cmp	__rc13
	bne	.Lkn7
	jmp	.Lhit
.Lkn7:	; -- #8: sq+33 ($21) --
	txa
	clc
	adc	#$21
	tay
	and	#$88
	bne	.Lkings               ; off-board -> done with knights
	lda	(__rc2),y
	cmp	__rc13
	bne	.Lkings
	jmp	.Lhit

; ===========================================================================
; 3) KING adjacency.  8 fixed offsets.  FULLY UNROLLED (same scheme as knights).
; ===========================================================================
.Lkings:
	lda	#PT_KING
	ora	__rc9
	sta	__rc13                ; __rc13 = target king byte
	; -- #1: sq-17 ($EF) --
	txa
	clc
	adc	#$EF
	tay
	and	#$88
	bne	.Lkg1
	lda	(__rc2),y
	cmp	__rc13
	bne	.Lkg1
	jmp	.Lhit
.Lkg1:	; -- #2: sq-16 ($F0) --
	txa
	clc
	adc	#$F0
	tay
	and	#$88
	bne	.Lkg2
	lda	(__rc2),y
	cmp	__rc13
	bne	.Lkg2
	jmp	.Lhit
.Lkg2:	; -- #3: sq-15 ($F1) --
	txa
	clc
	adc	#$F1
	tay
	and	#$88
	bne	.Lkg3
	lda	(__rc2),y
	cmp	__rc13
	bne	.Lkg3
	jmp	.Lhit
.Lkg3:	; -- #4: sq-1 ($FF) --
	txa
	clc
	adc	#$FF
	tay
	and	#$88
	bne	.Lkg4
	lda	(__rc2),y
	cmp	__rc13
	bne	.Lkg4
	jmp	.Lhit
.Lkg4:	; -- #5: sq+1 ($01) --
	txa
	clc
	adc	#$01
	tay
	and	#$88
	bne	.Lkg5
	lda	(__rc2),y
	cmp	__rc13
	bne	.Lkg5
	jmp	.Lhit
.Lkg5:	; -- #6: sq+15 ($0F) --
	txa
	clc
	adc	#$0F
	tay
	and	#$88
	bne	.Lkg6
	lda	(__rc2),y
	cmp	__rc13
	bne	.Lkg6
	jmp	.Lhit
.Lkg6:	; -- #7: sq+16 ($10) --
	txa
	clc
	adc	#$10
	tay
	and	#$88
	bne	.Lkg7
	lda	(__rc2),y
	cmp	__rc13
	bne	.Lkg7
	jmp	.Lhit
.Lkg7:	; -- #8: sq+17 ($11) --
	txa
	clc
	adc	#$11
	tay
	and	#$88
	bne	.Lbishops             ; off-board -> done with kings
	lda	(__rc2),y
	cmp	__rc13
	bne	.Lbishops
	jmp	.Lhit

; ===========================================================================
; 4) DIAGONAL slider rays: bishop or queen.  4 directions; walk until offboard
;    or a piece blocks.
; ===========================================================================
.Lbishops:
	ldx	#0
.Lbishop_dir:
	lda	bishop_off,x
	sta	__rc10                ; ray delta
	stx	__rc11                ; save dir index
	lda	__rc8                 ; t = sq
	clc
	adc	__rc10                ; t = sq + off (first step)
.Lbishop_walk:
	tay                           ; Y = t
	and	#$88
	bne	.Lbishop_next         ; off-board -> stop this ray
	lda	(__rc2),y             ; p = b->sq[t]
	beq	.Lbishop_step         ; empty -> keep walking
	; blocker present: bishop/queen of color_match?
	sta	__rc12                ; save p
	and	#$80
	cmp	__rc9
	bne	.Lbishop_next         ; wrong color -> blocked, no hit
	lda	__rc12
	and	#7
	cmp	#PT_BISHOP
	beq	.Lbishop_hit
	cmp	#PT_QUEEN
	beq	.Lbishop_hit
	; right color but not B/Q -> blocked, no hit
	jmp	.Lbishop_next
.Lbishop_hit:
	jmp	.Lhit
.Lbishop_step:
	tya                           ; A = t (Y held t)
	clc
	adc	__rc10
	jmp	.Lbishop_walk
.Lbishop_next:
	ldx	__rc11
	inx
	cpx	#4
	beq	.Lrooks               ; near
	stx	__rc11
	lda	bishop_off,x
	sta	__rc10
	lda	__rc8
	clc
	adc	__rc10
	jmp	.Lbishop_walk

; ===========================================================================
; 5) ORTHOGONAL slider rays: rook or queen.  4 directions.
; ===========================================================================
.Lrooks:
	ldx	#0
.Lrook_dir:
	lda	rook_off,x
	sta	__rc10
	stx	__rc11
	lda	__rc8
	clc
	adc	__rc10
.Lrook_walk:
	tay
	and	#$88
	bne	.Lrook_next
	lda	(__rc2),y
	beq	.Lrook_step
	sta	__rc12
	and	#$80
	cmp	__rc9
	bne	.Lrook_next
	lda	__rc12
	and	#7
	cmp	#PT_ROOK
	beq	.Lrook_hit
	cmp	#PT_QUEEN
	beq	.Lrook_hit
	jmp	.Lrook_next
.Lrook_hit:
	jmp	.Lhit
.Lrook_step:
	tya
	clc
	adc	__rc10
	jmp	.Lrook_walk
.Lrook_next:
	ldx	__rc11
	inx
	cpx	#4
	beq	.Lrook_done           ; near
	stx	__rc11
	lda	rook_off,x
	sta	__rc10
	lda	__rc8
	clc
	adc	__rc10
	jmp	.Lrook_walk
.Lrook_done:
	jmp	.Lmiss

; (.Lcheck_pawn, .Lcheck_knight, .Lcheck_king helpers all removed -- inlined into
;  their checks above as single-CMP tests, eliminating the per-call jsr/rts.)

.Lfunc_end_isa:
	.size	is_square_attacked, .Lfunc_end_isa-is_square_attacked

; ===========================================================================
; offset tables (signed deltas as single bytes; index arithmetic wraps mod 256,
; exactly what the 0x88 off-board test needs)
; ===========================================================================
	.section	.rodata.is_square_attacked,"a",@progbits
; knight_off / king_off tables removed -- the knight & king scans are now fully
; unrolled with immediate offsets (see .Lknights / .Lkings), so no table is read.
bishop_off:
	.byte	256-17, 256-15, 15, 17                            ; -17,-15,15,17
rook_off:
	.byte	256-16, 16, 256-1, 1                              ; -16,16,-1,1
