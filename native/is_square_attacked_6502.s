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
	lda	__rc9
	bne	.Lpawn_white          ; color_match==0x80 -> white -> +15/+17
	; black: deltas -15 (=$F1) and -17 (=$EF)
	lda	__rc8
	clc
	adc	#$F1                  ; sq - 15
	jsr	.Lcheck_pawn
	bcs	.Lhit                 ; near (.Lhit is just above)
	lda	__rc8
	clc
	adc	#$EF                  ; sq - 17
	jsr	.Lcheck_pawn
	bcs	.Lhit
	jmp	.Lknights
.Lpawn_white:
	; white: deltas +15 and +17
	lda	__rc8
	clc
	adc	#15                   ; sq + 15
	jsr	.Lcheck_pawn
	bcs	.Lhit
	lda	__rc8
	clc
	adc	#17                   ; sq + 17
	jsr	.Lcheck_pawn
	bcs	.Lhit
	; fall through to knights

; ===========================================================================
; 2) KNIGHT attacks.  8 fixed offsets.
; ===========================================================================
.Lknights:
	ldx	#0
.Lknight_loop:
	lda	__rc8
	clc
	adc	knight_off,x
	jsr	.Lcheck_knight
	bcc	.Lknight_cont         ; no hit -> continue (near)
	jmp	.Lhit                 ; hit -> return (absolute, always in range)
.Lknight_cont:
	inx
	cpx	#8
	bne	.Lknight_loop

; ===========================================================================
; 3) KING adjacency.  8 fixed offsets.
; ===========================================================================
.Lkings:
	ldx	#0
.Lking_loop:
	lda	__rc8
	clc
	adc	king_off,x
	jsr	.Lcheck_king
	bcc	.Lking_cont
	jmp	.Lhit
.Lking_cont:
	inx
	cpx	#8
	bne	.Lking_loop

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

; ===========================================================================
; helper: .Lcheck_pawn
;   in:  A = target square t (may be off-board)
;   out: carry SET if a pawn of color_match sits at t, else carry CLEAR.
;        A,Y clobbered; X preserved.
; ===========================================================================
.Lcheck_pawn:
	tay
	and	#$88
	bne	.Lcp_no               ; off-board
	lda	(__rc2),y
	beq	.Lcp_no               ; empty
	sta	__rc12
	and	#7
	cmp	#PT_PAWN
	bne	.Lcp_no
	lda	__rc12
	and	#$80
	cmp	__rc9
	bne	.Lcp_no
	sec
	rts
.Lcp_no:
	clc
	rts

; ===========================================================================
; helper: .Lcheck_knight  (expects PT_KNIGHT)
; ===========================================================================
.Lcheck_knight:
	tay
	and	#$88
	bne	.Lck_no
	lda	(__rc2),y
	beq	.Lck_no
	sta	__rc12
	and	#7
	cmp	#PT_KNIGHT
	bne	.Lck_no
	lda	__rc12
	and	#$80
	cmp	__rc9
	bne	.Lck_no
	sec
	rts
.Lck_no:
	clc
	rts

; ===========================================================================
; helper: .Lcheck_king  (expects PT_KING)
; ===========================================================================
.Lcheck_king:
	tay
	and	#$88
	bne	.Lckg_no
	lda	(__rc2),y
	beq	.Lckg_no
	sta	__rc12
	and	#7
	cmp	#PT_KING
	bne	.Lckg_no
	lda	__rc12
	and	#$80
	cmp	__rc9
	bne	.Lckg_no
	sec
	rts
.Lckg_no:
	clc
	rts

.Lfunc_end_isa:
	.size	is_square_attacked, .Lfunc_end_isa-is_square_attacked

; ===========================================================================
; offset tables (signed deltas as single bytes; index arithmetic wraps mod 256,
; exactly what the 0x88 off-board test needs)
; ===========================================================================
	.section	.rodata.is_square_attacked,"a",@progbits
knight_off:
	.byte	256-33, 256-31, 256-18, 256-14, 14, 18, 31, 33   ; -33,-31,-18,-14,14,18,31,33
king_off:
	.byte	256-17, 256-16, 256-15, 256-1, 1, 15, 16, 17     ; -17,-16,-15,-1,1,15,16,17
bishop_off:
	.byte	256-17, 256-15, 15, 17                            ; -17,-15,15,17
rook_off:
	.byte	256-16, 16, 256-1, 1                              ; -16,16,-1,1
