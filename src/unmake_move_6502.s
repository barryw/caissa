; ============================================================================
; unmake_move_6502.s
;
; Hand-written 6502 assembly replacement for native/board.c's unmake_move(),
; compiled by llvm-mos (mos-sim) and linked INSTEAD of the C body for the 6502
; image. BIT-IDENTICAL behavior to the C function.
;
; This file is built ONLY for the mos-sim 6502 image. The C body in board.c is
; #ifdef'd out when CREF_ASM_UNMAKE_MOVE is defined (the build passes
; -DCREF_ASM_UNMAKE_MOVE only on the mos-sim compile of board.c, and adds this
; .s to the link line). The host (clang) build keeps the C body, which is the
; bit-exact oracle the gate checks against.
;
; unmake_move is SELF-CONTAINED -- it calls no other function -- so there is no
; jsr and no callee-save bookkeeping beyond the imaginary-reg scratch contract.
;
; ----------------------------------------------------------------------------
; ABI (derived empirically from `mos-sim-clang -Os -S -fno-lto board.c`, and
; confirmed against a caller probe + MOSCallingConv.td: A/X/Y + RS1..RS9 are
; caller-saved; RS0 (=__rc0/1, the soft stack ptr) and RS10.. are callee-saved):
;
;   C prototype: void unmake_move(Board *b, Move m, const Undo *u)
;   Move = { uint8 from, to, promo, flags }  (4-byte struct, BY VALUE, in regs)
;
;   in:  b     ptr  -> __rc2 (lo) / __rc3 (hi)   (points at b->sq[0])
;        m.from u8  -> A
;        m.to   u8  -> X
;        m.promo u8 -> __rc4                      (UNUSED by unmake)
;        m.flags u8 -> __rc5
;        u     ptr  -> __rc6 (lo) / __rc7 (hi)
;   out: void (no return value)
;
;   The C body uses ONLY m.from, m.to, m.flags (never m.promo): the promotion
;   restore writes (PT_PAWN | colorflag), independent of which piece was promoted
;   to. So m.promo (__rc4) is free scratch here.
;
; Scratch zero-page (all caller-saved RS-regs, free to clobber):
;   __rc8  = m.from                 (saved from A)
;   __rc9  = m.to                   (saved from X)
;   __rc10 = m.flags                (copied from __rc5; __rc5 is also caller-saved
;                                    but we keep a stable named slot)
;   __rc11 = colorflag              (0x80 if white-to-move after the wtm^=1, else 0)
;   __rc12 = white                  (0/1)
;   __rc13 = scratch (placed piece, rook square, temp)
;   b ptr (__rc2/3) and u ptr (__rc6/7) stay put as the two (zp),Y bases.
;
; BRANCH-RANGE NOTE: this function exceeds the 8-bit conditional-branch reach
; (-128..+127). The integrated assembler SILENTLY emits a truncated displacement
; for an out-of-range bcc/bcs/beq/bne rather than erroring, corrupting control
; flow. So every conditional branch whose target could be far uses invert-and-JMP
; (a short branch over a 3-byte absolute jmp); JMP is 16-bit and always in range.
; Short branches are only used for provably-near fall-throughs.
;
; Board field offsets (board.h on mos, int=16-bit; confirmed via offsetof -S):
;   sq=0  wtm=128  wk=130  bk=132  castle=134  ep=136  halfmove=138
;   fullmove=140  hash=142..145  acc_mat=146  acc_egdiff=148  acc_phase=150
; Undo field offsets:
;   captured=0  cap_sq=1  castle=3  ep=5  halfmove=7  wk=9  bk=11
;   hash=13..16  acc_mat=17  acc_egdiff=19  acc_phase=21
; All scalar ints are 2 bytes; hash is 4 bytes.
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

	.section	.text.unmake_move,"ax",@progbits
	.globl	unmake_move
	.type	unmake_move,@function

PT_PAWN     = 1
MF_PROMO    = 32
MF_CASTLE_K = 8
MF_CASTLE_Q = 16
WHITE_FLAG  = 0x80

; Board field offsets
B_WTM       = 128
B_WK        = 130
B_BK        = 132
B_CASTLE    = 134
B_EP        = 136
B_HALFMOVE  = 138
B_FULLMOVE  = 140
B_HASH      = 142
B_ACC_MAT   = 146
B_ACC_EGD   = 148
B_ACC_PHASE = 150

; Undo field offsets
U_CAPTURED  = 0
U_CAPSQ     = 1
U_CASTLE    = 3
U_EP        = 5
U_HALFMOVE  = 7
U_WK        = 9
U_BK        = 11
U_HASH      = 13
U_ACC_MAT   = 17
U_ACC_EGD   = 19
U_ACC_PHASE = 21

unmake_move:
	; --- save the by-value Move bytes into stable named scratch ---
	sta	__rc8                 ; __rc8 = m.from
	stx	__rc9                 ; __rc9 = m.to
	lda	__rc5
	sta	__rc10                ; __rc10 = m.flags

	; --- b->wtm ^= 1 ;  white = b->wtm ;  colorflag = white ? 0x80 : 0 ---
	ldy	#B_WTM
	lda	(__rc2),y             ; A = b->wtm (low byte; wtm is 0/1)
	eor	#1
	sta	(__rc2),y             ; b->wtm ^= 1  (low byte)
	sta	__rc12                ; white = new wtm (0/1)
	; (wtm is always 0/1; the high byte stays 0 and we never touch it,
	;  matching the C `eor #1` on the low byte only.)
	bne	.Lis_white
	lda	#0
	sta	__rc11                ; colorflag = 0 (black)
	jmp	.Lrestore_mover
.Lis_white:
	lda	#WHITE_FLAG
	sta	__rc11                ; colorflag = 0x80 (white)

.Lrestore_mover:
	; placed = b->sq[m.to] ;  b->sq[m.to] = 0
	ldy	__rc9                 ; Y = m.to
	lda	(__rc2),y             ; A = placed = b->sq[m.to]
	sta	__rc13                ; __rc13 = placed
	lda	#0
	sta	(__rc2),y             ; b->sq[m.to] = 0

	; b->sq[m.from] = (flags & MF_PROMO) ? (PT_PAWN|colorflag) : placed
	lda	__rc10
	and	#MF_PROMO
	beq	.Lnot_promo           ; near
	lda	#PT_PAWN
	ora	__rc11                ; PT_PAWN | colorflag
	jmp	.Lstore_from
.Lnot_promo:
	lda	__rc13                ; placed
.Lstore_from:
	ldy	__rc8                 ; Y = m.from
	sta	(__rc2),y             ; b->sq[m.from] = ...

	; --- restore captured: if (u->captured) b->sq[u->cap_sq] = u->captured ---
	ldy	#U_CAPTURED
	lda	(__rc6),y             ; A = u->captured
	beq	.Lno_capture          ; 0 -> skip (near)
	sta	__rc13                ; save captured byte
	ldy	#U_CAPSQ
	lda	(__rc6),y             ; A = u->cap_sq (low byte = 0x88 square 0..119)
	tay                           ; Y = cap_sq
	lda	__rc13
	sta	(__rc2),y             ; b->sq[u->cap_sq] = u->captured
.Lno_capture:

	; --- un-castle rook ---
	; if (flags & MF_CASTLE_K) { rf=to+1; rt=to-1; b->sq[rf]=b->sq[rt]; b->sq[rt]=0; }
	; else if (flags & MF_CASTLE_Q) { rf=to-2; rt=to+1; b->sq[rf]=b->sq[rt]; b->sq[rt]=0; }
	lda	__rc10
	and	#MF_CASTLE_K
	beq	.Lck_no               ; near
	; kingside: rf = to+1, rt = to-1
	lda	__rc9
	clc
	adc	#1
	sta	__rc13                ; __rc13 = rf = to+1
	lda	__rc9
	sec
	sbc	#1                    ; A = rt = to-1
	tay                           ; Y = rt
	lda	(__rc2),y             ; A = b->sq[rt]
	pha                           ; save b->sq[rt]
	lda	#0
	sta	(__rc2),y             ; b->sq[rt] = 0
	pla
	ldy	__rc13                ; Y = rf
	sta	(__rc2),y             ; b->sq[rf] = (old b->sq[rt])
	jmp	.Luncastle_done
.Lck_no:
	lda	__rc10
	and	#MF_CASTLE_Q
	beq	.Luncastle_done       ; near
	; queenside: rf = to-2, rt = to+1
	lda	__rc9
	sec
	sbc	#2
	sta	__rc13                ; __rc13 = rf = to-2
	lda	__rc9
	clc
	adc	#1                    ; A = rt = to+1
	tay                           ; Y = rt
	lda	(__rc2),y             ; A = b->sq[rt]
	pha
	lda	#0
	sta	(__rc2),y             ; b->sq[rt] = 0
	pla
	ldy	__rc13                ; Y = rf
	sta	(__rc2),y             ; b->sq[rf] = (old b->sq[rt])
.Luncastle_done:

	; --- if (!white) b->fullmove-- ---
	lda	__rc12
	bne	.Lno_fullmove_dec     ; white -> skip
	; black to move (we just flipped TO the mover; mover was black): fullmove--
	; 16-bit decrement of b->fullmove
	ldy	#B_FULLMOVE
	lda	(__rc2),y             ; lo
	sec
	sbc	#1
	sta	(__rc2),y
	iny
	lda	(__rc2),y             ; hi
	sbc	#0
	sta	(__rc2),y
.Lno_fullmove_dec:

	; --- restore scalar ints from Undo (each 2 bytes) ---
	; b->castle    = u->castle
	ldy	#U_CASTLE
	lda	(__rc6),y
	ldy	#B_CASTLE
	sta	(__rc2),y
	ldy	#U_CASTLE+1
	lda	(__rc6),y
	ldy	#B_CASTLE+1
	sta	(__rc2),y

	; b->ep        = u->ep
	ldy	#U_EP
	lda	(__rc6),y
	ldy	#B_EP
	sta	(__rc2),y
	ldy	#U_EP+1
	lda	(__rc6),y
	ldy	#B_EP+1
	sta	(__rc2),y

	; b->halfmove  = u->halfmove
	ldy	#U_HALFMOVE
	lda	(__rc6),y
	ldy	#B_HALFMOVE
	sta	(__rc2),y
	ldy	#U_HALFMOVE+1
	lda	(__rc6),y
	ldy	#B_HALFMOVE+1
	sta	(__rc2),y

	; b->wk        = u->wk
	ldy	#U_WK
	lda	(__rc6),y
	ldy	#B_WK
	sta	(__rc2),y
	ldy	#U_WK+1
	lda	(__rc6),y
	ldy	#B_WK+1
	sta	(__rc2),y

	; b->bk        = u->bk
	ldy	#U_BK
	lda	(__rc6),y
	ldy	#B_BK
	sta	(__rc2),y
	ldy	#U_BK+1
	lda	(__rc6),y
	ldy	#B_BK+1
	sta	(__rc2),y

	; b->hash      = u->hash   (4 bytes)
	ldy	#U_HASH
	lda	(__rc6),y
	ldy	#B_HASH
	sta	(__rc2),y
	ldy	#U_HASH+1
	lda	(__rc6),y
	ldy	#B_HASH+1
	sta	(__rc2),y
	ldy	#U_HASH+2
	lda	(__rc6),y
	ldy	#B_HASH+2
	sta	(__rc2),y
	ldy	#U_HASH+3
	lda	(__rc6),y
	ldy	#B_HASH+3
	sta	(__rc2),y

	; b->acc_mat   = u->acc_mat
	ldy	#U_ACC_MAT
	lda	(__rc6),y
	ldy	#B_ACC_MAT
	sta	(__rc2),y
	ldy	#U_ACC_MAT+1
	lda	(__rc6),y
	ldy	#B_ACC_MAT+1
	sta	(__rc2),y

	; b->acc_egdiff = u->acc_egdiff
	ldy	#U_ACC_EGD
	lda	(__rc6),y
	ldy	#B_ACC_EGD
	sta	(__rc2),y
	ldy	#U_ACC_EGD+1
	lda	(__rc6),y
	ldy	#B_ACC_EGD+1
	sta	(__rc2),y

	; b->acc_phase = u->acc_phase
	ldy	#U_ACC_PHASE
	lda	(__rc6),y
	ldy	#B_ACC_PHASE
	sta	(__rc2),y
	ldy	#U_ACC_PHASE+1
	lda	(__rc6),y
	ldy	#B_ACC_PHASE+1
	sta	(__rc2),y

	rts

.Lfunc_end_umm:
	.size	unmake_move, .Lfunc_end_umm-unmake_move
