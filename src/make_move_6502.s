; ============================================================================
; make_move_6502.s
;
; Hand-written 6502 assembly replacement for native/board.c's make_move(),
; compiled by llvm-mos (mos-sim) and linked INSTEAD of the C body for the 6502
; image. BIT-IDENTICAL behavior to the C function.
;
; Built ONLY for the mos-sim 6502 image. The C body in board.c is #ifdef'd out
; when CREF_ASM_MAKE_MOVE is defined (the build passes -DCREF_ASM_MAKE_MOVE only
; on the mos-sim compile of board.c, and adds this .s to the link line). The host
; (clang) build keeps the C body, which is the bit-exact oracle the gate checks
; against.
;
; make_move CALLS eval_acc_apply at its tail (one jsr). It does NOT call
; castle_mask (that C helper is static / not externally visible) -- the 6-case
; castle-right mask switch is inlined here.
;
; ----------------------------------------------------------------------------
; ABI (derived empirically via `mos-sim-clang -Os -S -fno-lto board.c` + a
; caller/passthrough probe; confirmed against MOSCallingConv.td: A/X/Y + RS1..RS9
; (=__rc2..__rc19) are caller-saved; RS0 (=__rc0/1, soft stack ptr) and RS10..
; (=__rc20..__rc31) are callee-saved):
;
;   C prototype: void make_move(Board *b, Move m, Undo *u)
;   Move = { uint8 from, to, promo, flags }  (4-byte struct, BY VALUE, in regs)
;
;   in:  b      ptr -> __rc2 (lo) / __rc3 (hi)   (points at b->sq[0])
;        m.from u8  -> A
;        m.to   u8  -> X
;        m.promo u8 -> __rc4
;        m.flags u8 -> __rc5
;        u      ptr -> __rc6 (lo) / __rc7 (hi)   (NON-const: we write it)
;   out: void
;
; eval_acc_apply has the IDENTICAL incoming Move/Board slots (proven: a
; passthrough wrapper tail-jumps to it), plus three extra args:
;   void eval_acc_apply(Board *b, Move m, uint8_t mover, uint8_t captured,
;                       int cap_sq)
;        mover    u8  -> __rc6
;        captured u8  -> __rc7
;        cap_sq   i16 -> __rc8 (lo) / __rc9 (hi)
; So at the tail we keep b in __rc2/3, m.promo in __rc4, m.flags in __rc5, set
; A=m.from, X=m.to, __rc6=mover(piece), __rc7=u->captured, __rc8/9=u->cap_sq,
; then jsr eval_acc_apply.  (mover is the ORIGINAL piece on m.from, read at entry
; BEFORE the from-square is zeroed.)
;
; Because we call eval_acc_apply, every value we still need at the tail must
; survive that call. eval_acc_apply preserves the callee-saved regs (__rc20+,
; __rc0/1) and may clobber any caller-saved reg -- but we only need things BEFORE
; the call, so all working state lives in caller-saved scratch and we set up the
; call's argument regs last. The only callee-saved regs we touch are __rc20/__rc21
; (used as the Z_PIECE entry pointer in the zobrist helper); we pha/pla them so
; OUR caller's contract is honored.
;
; Register plan (caller-saved unless noted):
;   __rc2/3   b ptr            (incoming; (zp),Y base for board)
;   __rc4     m.promo          (incoming; preserved untouched for the tail call)
;   __rc5     m.flags          (incoming; preserved untouched for the tail call)
;   __rc6/7   u ptr            (incoming; (zp),Y base for undo) until the tail,
;                              where __rc6=mover and __rc7=captured are set up
;   __rc8     m.from
;   __rc9     m.to
;   __rc10    flags (working copy of __rc5)
;   __rc11    piece  (original mover byte)
;   __rc12    colorflag (0x80 white / 0x00 black)
;   __rc13    white (0/1)  -- dead after the mutation block; reused as helper temp
;   __rc14    placed (piece byte written to m.to)
;   __rc15..18  hash accumulator h0(lo)..h3(hi)  (zobrist block only)
;   __rc19    scratch byte (and helper temp)
;   __rc20/21 Z_PIECE entry pointer (callee-saved -> pha/pla guarded)
;
; BRANCH-RANGE NOTE: this function is large (well over the 8-bit branch reach of
; -128..+127). The integrated assembler SILENTLY truncates an out-of-range
; bcc/bcs/beq/bne displacement rather than erroring, which corrupts control flow.
; So every conditional branch whose target could be far uses invert-and-JMP (a
; short branch over a 3-byte absolute jmp); JMP is 16-bit and always in range.
; Short branches are used only for provably-near targets.
;
; Board field offsets (board.h on mos, int=16-bit; static_assert-confirmed):
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
	.zeropage	__rc14
	.zeropage	__rc15
	.zeropage	__rc16
	.zeropage	__rc17
	.zeropage	__rc18
	.zeropage	__rc19
	.zeropage	__rc20
	.zeropage	__rc21

	.section	.text.make_move,"ax",@progbits
	.globl	make_move
	.type	make_move,@function

; piece types
PT_PAWN     = 1
PT_ROOK     = 4
PT_KING     = 6
; move flags
MF_CAPTURE  = 1
MF_DOUBLE   = 2
MF_EP       = 4
MF_CASTLE_K = 8
MF_CASTLE_Q = 16
MF_PROMO    = 32
WHITE_FLAG  = 0x80
; castle-right bits
CASTLE_WK   = 1
CASTLE_WQ   = 2
CASTLE_BK   = 4
CASTLE_BQ   = 8

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

make_move:
	; save Move bytes / preserve callee-saved scratch we use
	sta	__rc8                 ; __rc8 = m.from
	stx	__rc9                 ; __rc9 = m.to
	lda	__rc5
	sta	__rc10                ; __rc10 = m.flags (working copy)
	lda	__rc20
	pha
	lda	__rc21
	pha                           ; save callee-saved __rc20/21

	; piece = b->sq[m.from]
	ldy	__rc8
	lda	(__rc2),y
	sta	__rc11                ; __rc11 = piece
	; white = IS_WHITE(piece) ? 1 : 0 ; colorflag = white ? 0x80 : 0
	and	#WHITE_FLAG
	beq	.Lblack
	lda	#1
	sta	__rc13                ; white = 1
	lda	#WHITE_FLAG
	sta	__rc12                ; colorflag = 0x80
	jmp	.Lsave_undo
.Lblack:
	lda	#0
	sta	__rc13                ; white = 0
	sta	__rc12                ; colorflag = 0
.Lsave_undo:
	; push = white ? -16 : 16  -- computed inline where needed (ep / double).

	; --- save prior state into Undo ---
	; u->castle = b->castle  (2 bytes)
	ldy	#B_CASTLE
	lda	(__rc2),y
	ldy	#U_CASTLE
	sta	(__rc6),y
	ldy	#B_CASTLE+1
	lda	(__rc2),y
	ldy	#U_CASTLE+1
	sta	(__rc6),y
	; u->ep = b->ep
	ldy	#B_EP
	lda	(__rc2),y
	ldy	#U_EP
	sta	(__rc6),y
	ldy	#B_EP+1
	lda	(__rc2),y
	ldy	#U_EP+1
	sta	(__rc6),y
	; u->halfmove = b->halfmove
	ldy	#B_HALFMOVE
	lda	(__rc2),y
	ldy	#U_HALFMOVE
	sta	(__rc6),y
	ldy	#B_HALFMOVE+1
	lda	(__rc2),y
	ldy	#U_HALFMOVE+1
	sta	(__rc6),y
	; u->wk = b->wk
	ldy	#B_WK
	lda	(__rc2),y
	ldy	#U_WK
	sta	(__rc6),y
	ldy	#B_WK+1
	lda	(__rc2),y
	ldy	#U_WK+1
	sta	(__rc6),y
	; u->bk = b->bk
	ldy	#B_BK
	lda	(__rc2),y
	ldy	#U_BK
	sta	(__rc6),y
	ldy	#B_BK+1
	lda	(__rc2),y
	ldy	#U_BK+1
	sta	(__rc6),y
	; u->hash = b->hash  (4 bytes)
	ldy	#B_HASH
	lda	(__rc2),y
	ldy	#U_HASH
	sta	(__rc6),y
	ldy	#B_HASH+1
	lda	(__rc2),y
	ldy	#U_HASH+1
	sta	(__rc6),y
	ldy	#B_HASH+2
	lda	(__rc2),y
	ldy	#U_HASH+2
	sta	(__rc6),y
	ldy	#B_HASH+3
	lda	(__rc2),y
	ldy	#U_HASH+3
	sta	(__rc6),y
	; u->captured = 0
	lda	#0
	ldy	#U_CAPTURED
	sta	(__rc6),y
	; NOTE: the unconditional `u->cap_sq = m.to` store is deferred. cap_sq is
	; only ever READ when u->captured != 0 (unmake, zobrist, eval_acc_apply all
	; gate on captured), so writing it on quiet moves is dead work. The EP path
	; writes its own cap_sq; the normal-capture path writes cap_sq=m.to below.
	; A quiet move leaves Undo.cap_sq stale, but with captured==0 nobody reads it.

	; ================= board mutation =================
	; lift mover: b->sq[m.from] = 0
	lda	#0
	ldy	__rc8
	sta	(__rc2),y

	; capture
	lda	__rc10
	and	#MF_EP
	beq	.Lnot_ep              ; near
	; ep: u->cap_sq = m.to - push  (push white=-16 -> +16 ; black=+16 -> -16)
	;     u->captured = b->sq[u->cap_sq] ; b->sq[u->cap_sq] = 0
	lda	__rc13                ; white?
	beq	.Lep_black
	; white: cap_sq = m.to + 16
	lda	__rc9
	clc
	adc	#16
	jmp	.Lep_store_capsq
.Lep_black:
	; black: cap_sq = m.to - 16
	lda	__rc9
	sec
	sbc	#16
.Lep_store_capsq:
	tay                           ; Y = cap_sq (low byte; on-board 0..119)
	sty	__rc19                ; remember cap_sq low
	ldy	#U_CAPSQ
	lda	__rc19
	sta	(__rc6),y             ; u->cap_sq low
	lda	#0
	ldy	#U_CAPSQ+1
	sta	(__rc6),y             ; u->cap_sq high = 0
	ldy	__rc19                ; Y = cap_sq
	lda	(__rc2),y             ; captured pawn
	ldy	#U_CAPTURED
	sta	(__rc6),y             ; u->captured = pawn
	lda	#0
	ldy	__rc19
	sta	(__rc2),y             ; b->sq[cap_sq] = 0
	jmp	.Lplace
.Lnot_ep:
	lda	__rc10
	and	#MF_CAPTURE
	beq	.Lplace               ; near
	; normal capture: u->captured = b->sq[m.to] ; u->cap_sq = m.to (low/high=0)
	ldy	__rc9
	lda	(__rc2),y
	ldy	#U_CAPTURED
	sta	(__rc6),y
	lda	__rc9
	ldy	#U_CAPSQ
	sta	(__rc6),y             ; u->cap_sq low = m.to
	lda	#0
	ldy	#U_CAPSQ+1
	sta	(__rc6),y             ; u->cap_sq high = 0

.Lplace:
	; placed = (flags & MF_PROMO) ? (m.promo | colorflag) : piece
	lda	__rc10
	and	#MF_PROMO
	beq	.Lplace_normal        ; near
	lda	__rc4                 ; m.promo
	ora	__rc12                ; | colorflag
	jmp	.Lplace_store
.Lplace_normal:
	lda	__rc11                ; piece
.Lplace_store:
	sta	__rc14                ; placed
	ldy	__rc9                 ; m.to
	sta	(__rc2),y             ; b->sq[m.to] = placed

	; if (PT(piece)==PT_KING) { white ? b->wk : b->bk = m.to }
	lda	__rc11
	and	#7
	cmp	#PT_KING
	bne	.Lnot_king            ; near
	lda	__rc13                ; white?
	beq	.Lking_black
	; b->wk = m.to  (low=m.to, high=0)
	lda	__rc9
	ldy	#B_WK
	sta	(__rc2),y
	lda	#0
	ldy	#B_WK+1
	sta	(__rc2),y
	jmp	.Lnot_king
.Lking_black:
	lda	__rc9
	ldy	#B_BK
	sta	(__rc2),y
	lda	#0
	ldy	#B_BK+1
	sta	(__rc2),y
.Lnot_king:

	; castling: relocate rook
	lda	__rc10
	and	#MF_CASTLE_K
	beq	.Lck_no               ; near
	; kingside: rf = to+1, rt = to-1 ; b->sq[rt]=b->sq[rf]; b->sq[rf]=0
	lda	__rc9
	clc
	adc	#1
	tay                           ; Y = rf
	lda	(__rc2),y             ; rook = b->sq[rf]
	sta	__rc19
	lda	#0
	sta	(__rc2),y             ; b->sq[rf] = 0
	lda	__rc9
	sec
	sbc	#1
	tay                           ; Y = rt = to-1
	lda	__rc19
	sta	(__rc2),y             ; b->sq[rt] = rook
	jmp	.Lcastle_done
.Lck_no:
	lda	__rc10
	and	#MF_CASTLE_Q
	beq	.Lcastle_done         ; near
	; queenside: rf = to-2, rt = to+1
	lda	__rc9
	sec
	sbc	#2
	tay                           ; Y = rf = to-2
	lda	(__rc2),y
	sta	__rc19                ; rook
	lda	#0
	sta	(__rc2),y             ; b->sq[rf] = 0
	lda	__rc9
	clc
	adc	#1
	tay                           ; Y = rt = to+1
	lda	__rc19
	sta	(__rc2),y             ; b->sq[rt] = rook
.Lcastle_done:

	; castle rights: b->castle = castle_mask(m.to, castle_mask(m.from, b->castle))
	; (low byte only; high byte of castle stays 0 -- castle is a small bitmask)
	ldy	#B_CASTLE
	lda	(__rc2),y             ; A = b->castle (low)
	ldx	__rc8                 ; from
	jsr	.Lcastle_mask         ; A = mask(from, A)
	ldx	__rc9                 ; to
	jsr	.Lcastle_mask         ; A = mask(to, A)
	ldy	#B_CASTLE
	sta	(__rc2),y             ; b->castle low = result
	; high byte unchanged (was 0); leave as-is.

	; ep square: if (flags & MF_DOUBLE) b->ep = m.from + push; else b->ep = -1
	lda	__rc10
	and	#MF_DOUBLE
	beq	.Lep_neg              ; near
	lda	__rc13                ; white?
	beq	.Lep_blackpush
	; white push = -16 : ep = from - 16
	lda	__rc8
	sec
	sbc	#16
	jmp	.Lep_store
.Lep_blackpush:
	; black push = +16 : ep = from + 16
	lda	__rc8
	clc
	adc	#16
.Lep_store:
	ldy	#B_EP
	sta	(__rc2),y             ; b->ep low = from+push
	lda	#0
	ldy	#B_EP+1
	sta	(__rc2),y             ; high = 0
	jmp	.Lhalfmove
.Lep_neg:
	lda	#$FF
	ldy	#B_EP
	sta	(__rc2),y
	ldy	#B_EP+1
	sta	(__rc2),y             ; b->ep = -1 (0xFFFF)

.Lhalfmove:
	; if (PT(piece)==PT_PAWN || (flags & (MF_CAPTURE|MF_EP))) b->halfmove=0
	; else b->halfmove++
	lda	__rc11
	and	#7
	cmp	#PT_PAWN
	beq	.Lhm_zero             ; near
	lda	__rc10
	and	#(MF_CAPTURE | MF_EP)
	bne	.Lhm_zero             ; near
	; b->halfmove++  (16-bit)
	ldy	#B_HALFMOVE
	lda	(__rc2),y
	clc
	adc	#1
	sta	(__rc2),y
	ldy	#B_HALFMOVE+1
	lda	(__rc2),y
	adc	#0
	sta	(__rc2),y
	jmp	.Lfullmove
.Lhm_zero:
	lda	#0
	ldy	#B_HALFMOVE
	sta	(__rc2),y
	ldy	#B_HALFMOVE+1
	sta	(__rc2),y

.Lfullmove:
	; if (!white) b->fullmove++
	lda	__rc13
	bne	.Lflip_wtm            ; white -> skip
	ldy	#B_FULLMOVE
	lda	(__rc2),y
	clc
	adc	#1
	sta	(__rc2),y
	ldy	#B_FULLMOVE+1
	lda	(__rc2),y
	adc	#0
	sta	(__rc2),y

.Lflip_wtm:
	; b->wtm ^= 1   (low byte only)
	ldy	#B_WTM
	lda	(__rc2),y
	eor	#1
	sta	(__rc2),y

	; ================= incremental zobrist (g_make_hash) =================
	lda	g_make_hash
	ora	g_make_hash+1
	bne	.Lzob                 ; nonzero -> do block
	jmp	.Leval_tail           ; both bytes zero -> skip
.Lzob:
	; h = u->hash
	ldy	#U_HASH
	lda	(__rc6),y
	sta	__rc15
	ldy	#U_HASH+1
	lda	(__rc6),y
	sta	__rc16
	ldy	#U_HASH+2
	lda	(__rc6),y
	sta	__rc17
	ldy	#U_HASH+3
	lda	(__rc6),y
	sta	__rc18

	; if (u->ep >= 0) h ^= Z_EP[u->ep & 7]
	; u->ep is a 2-byte int; >=0 means high byte not 0xFF / value != -1. The C
	; test is `u->ep >= 0`; the only negative ep value the engine stores is -1
	; (0xFFFF). Test the sign bit of the high byte.
	ldy	#U_EP+1
	lda	(__rc6),y
	bmi	.Lzob_no_ep           ; high byte negative -> ep<0 -> skip
	ldy	#U_EP
	lda	(__rc6),y
	and	#7
	asl	a
	asl	a                     ; *4 (hash_t = 4 bytes)
	tax
	lda	__rc15
	eor	Z_EP,x
	sta	__rc15
	lda	__rc16
	eor	Z_EP+1,x
	sta	__rc16
	lda	__rc17
	eor	Z_EP+2,x
	sta	__rc17
	lda	__rc18
	eor	Z_EP+3,x
	sta	__rc18
.Lzob_no_ep:

	; h ^= Z_CASTLE[u->castle & 15]
	ldy	#U_CASTLE
	lda	(__rc6),y
	and	#15
	asl	a
	asl	a
	tax
	lda	__rc15
	eor	Z_CASTLE,x
	sta	__rc15
	lda	__rc16
	eor	Z_CASTLE+1,x
	sta	__rc16
	lda	__rc17
	eor	Z_CASTLE+2,x
	sta	__rc17
	lda	__rc18
	eor	Z_CASTLE+3,x
	sta	__rc18

	; lift mover: h ^= Z_PIECE[idx64(m.from)][pidx(piece)]
	lda	__rc11
	sta	__rc19                ; piece
	lda	__rc8                 ; m.from
	jsr	.Lxor_piece

	; captured: if (u->captured) h ^= Z_PIECE[idx64(u->cap_sq)][pidx(u->captured)]
	ldy	#U_CAPTURED
	lda	(__rc6),y
	beq	.Lzob_no_cap          ; near
	sta	__rc19                ; captured piece
	ldy	#U_CAPSQ
	lda	(__rc6),y             ; cap_sq low (on-board)
	jsr	.Lxor_piece
.Lzob_no_cap:

	; place: h ^= Z_PIECE[idx64(m.to)][pidx(placed)]
	lda	__rc14
	sta	__rc19                ; placed
	lda	__rc9                 ; m.to
	jsr	.Lxor_piece

	; castle rook squares
	lda	__rc10
	and	#MF_CASTLE_K
	beq	.Lzob_ck_no           ; near
	; rook = PT_ROOK | colorflag ; squares to+1 and to-1
	lda	#PT_ROOK
	ora	__rc12
	sta	__rc19                ; rook  (saved; restored before 2nd call)
	lda	__rc9
	clc
	adc	#1                    ; to+1
	jsr	.Lxor_piece
	lda	#PT_ROOK
	ora	__rc12
	sta	__rc19
	lda	__rc9
	sec
	sbc	#1                    ; to-1
	jsr	.Lxor_piece
	jmp	.Lzob_castle_done
.Lzob_ck_no:
	lda	__rc10
	and	#MF_CASTLE_Q
	beq	.Lzob_castle_done     ; near
	; squares to-2 and to+1
	lda	#PT_ROOK
	ora	__rc12
	sta	__rc19
	lda	__rc9
	sec
	sbc	#2                    ; to-2
	jsr	.Lxor_piece
	lda	#PT_ROOK
	ora	__rc12
	sta	__rc19
	lda	__rc9
	clc
	adc	#1                    ; to+1
	jsr	.Lxor_piece
.Lzob_castle_done:

	; h ^= Z_CASTLE[b->castle & 15]   (new rights)
	ldy	#B_CASTLE
	lda	(__rc2),y
	and	#15
	asl	a
	asl	a
	tax
	lda	__rc15
	eor	Z_CASTLE,x
	sta	__rc15
	lda	__rc16
	eor	Z_CASTLE+1,x
	sta	__rc16
	lda	__rc17
	eor	Z_CASTLE+2,x
	sta	__rc17
	lda	__rc18
	eor	Z_CASTLE+3,x
	sta	__rc18

	; if (flags & MF_DOUBLE) h ^= Z_EP[b->ep & 7]   (new ep target)
	lda	__rc10
	and	#MF_DOUBLE
	beq	.Lzob_no_newep        ; near
	ldy	#B_EP
	lda	(__rc2),y
	and	#7
	asl	a
	asl	a
	tax
	lda	__rc15
	eor	Z_EP,x
	sta	__rc15
	lda	__rc16
	eor	Z_EP+1,x
	sta	__rc16
	lda	__rc17
	eor	Z_EP+2,x
	sta	__rc17
	lda	__rc18
	eor	Z_EP+3,x
	sta	__rc18
.Lzob_no_newep:

	; h ^= Z_SIDE
	lda	__rc15
	eor	Z_SIDE
	sta	__rc15
	lda	__rc16
	eor	Z_SIDE+1
	sta	__rc16
	lda	__rc17
	eor	Z_SIDE+2
	sta	__rc17
	lda	__rc18
	eor	Z_SIDE+3
	sta	__rc18

	; b->hash = h
	ldy	#B_HASH
	lda	__rc15
	sta	(__rc2),y
	ldy	#B_HASH+1
	lda	__rc16
	sta	(__rc2),y
	ldy	#B_HASH+2
	lda	__rc17
	sta	(__rc2),y
	ldy	#B_HASH+3
	lda	__rc18
	sta	(__rc2),y

.Leval_tail:
	; --- stash pre-move accumulators into Undo (2 bytes each) ---
	ldy	#B_ACC_MAT
	lda	(__rc2),y
	ldy	#U_ACC_MAT
	sta	(__rc6),y
	ldy	#B_ACC_MAT+1
	lda	(__rc2),y
	ldy	#U_ACC_MAT+1
	sta	(__rc6),y
	ldy	#B_ACC_EGD
	lda	(__rc2),y
	ldy	#U_ACC_EGD
	sta	(__rc6),y
	ldy	#B_ACC_EGD+1
	lda	(__rc2),y
	ldy	#U_ACC_EGD+1
	sta	(__rc6),y
	ldy	#B_ACC_PHASE
	lda	(__rc2),y
	ldy	#U_ACC_PHASE
	sta	(__rc6),y
	ldy	#B_ACC_PHASE+1
	lda	(__rc2),y
	ldy	#U_ACC_PHASE+1
	sta	(__rc6),y

	; --- set up eval_acc_apply(b, m, mover=piece, captured=u->captured,
	;      cap_sq=u->cap_sq) ---
	; Target arg regs at the jsr:
	;   A=m.from  X=m.to  b=__rc2/3  m.promo=__rc4  m.flags=__rc5
	;   mover=__rc6  captured=__rc7  cap_sq=__rc8(lo)/__rc9(hi)
	; m.from/m.to currently live in __rc8/__rc9, which become cap_sq -- so stage
	; the Undo reads into FREE scratch first, preserve from/to, then assign.
	;
	; Read from Undo while __rc6/7 still hold the u ptr:
	ldy	#U_CAPSQ
	lda	(__rc6),y
	sta	__rc14                ; cap_sq lo
	ldy	#U_CAPSQ+1
	lda	(__rc6),y
	sta	__rc15                ; cap_sq hi
	ldy	#U_CAPTURED
	lda	(__rc6),y
	sta	__rc16                ; captured
	; preserve m.from / m.to before __rc8/__rc9 are repurposed
	lda	__rc8
	sta	__rc17                ; m.from
	lda	__rc9
	sta	__rc18                ; m.to
	; assign the call's argument regs
	lda	__rc11
	sta	__rc6                 ; mover = piece (overwrites u-ptr lo; done with u)
	lda	__rc16
	sta	__rc7                 ; captured     (overwrites u-ptr hi)
	lda	__rc14
	sta	__rc8                 ; cap_sq lo
	lda	__rc15
	sta	__rc9                 ; cap_sq hi
	; restore callee-saved __rc20/21 (handed back to OUR caller); eval_acc_apply
	; itself preserves them, so restoring here (before the call) is correct.
	pla
	sta	__rc21
	pla
	sta	__rc20
	; A = m.from, X = m.to (last, so nothing clobbers them before the call)
	ldx	__rc18                ; X = m.to
	lda	__rc17                ; A = m.from
	jsr	eval_acc_apply
	rts

; ============================================================================
; helper: .Lcastle_mask
;   Inlined equivalent of board.c's static castle_mask(sq, cur):
;     home squares clear specific rights, else identity.
;   in:  A = cur (castle bits, low byte) ; X = sq (0x88 square)
;   out: A = masked cur ; X preserved ; Y clobbered
; ============================================================================
.Lcastle_mask:
	cpx	#116                  ; e1 -> clear WK|WQ (1|2)  -> &0xFC
	bne	.Lcm_112
	and	#$FC
	rts
.Lcm_112:
	cpx	#112                  ; a1 -> clear WQ (2)       -> &0xFD
	bne	.Lcm_119
	and	#$FD
	rts
.Lcm_119:
	cpx	#119                  ; h1 -> clear WK (1)       -> &0xFE
	bne	.Lcm_4
	and	#$FE
	rts
.Lcm_4:
	cpx	#4                    ; e8 -> clear BK|BQ (4|8)  -> &0xF3
	bne	.Lcm_0
	and	#$F3
	rts
.Lcm_0:
	cpx	#0                    ; a8 -> clear BQ (8)       -> &0xF7
	bne	.Lcm_7
	and	#$F7
	rts
.Lcm_7:
	cpx	#7                    ; h8 -> clear BK (4)       -> &0xFB
	bne	.Lcm_id
	and	#$FB
	rts
.Lcm_id:
	rts                           ; identity (A unchanged)

; ============================================================================
; helper: .Lxor_piece
;   h ^= Z_PIECE[idx64_from_0x88(sq)][pidx(p)]   (XOR the 4-byte entry into
;   the running hash in __rc15..__rc18)
;     idx64 = (7 - (sq>>4))*8 + (sq&7)            (0..63)
;     pidx  = ((p&7)-1)*2 + ((p&0x80)?1:0)        (0..11)
;     entry byte offset = idx64*48 + pidx*4       ( = (idx64*12 + pidx)*4 )
;   in:  A = sq (0x88 square, on-board) ; __rc19 = piece byte p
;   out: __rc15..18 updated. Clobbers A,X,Y, __rc13, __rc19, __rc20/21.
;        Preserves __rc8..__rc12, __rc14, __rc2..__rc7.
; ============================================================================
.Lxor_piece:
	pha                           ; save sq
	; pidx4 = pidx*4 -> __rc13
	lda	__rc19
	and	#7
	sec
	sbc	#1                    ; (p&7)-1   (0..5)
	asl	a                     ; *2
	sta	__rc13                ; partial pidx (even part)
	lda	__rc19
	and	#WHITE_FLAG
	beq	.Lxp_noW
	inc	__rc13                ; +1 (white)
.Lxp_noW:
	asl	__rc13                ; pidx*2
	asl	__rc13                ; pidx*4   (max (5*2+1)*4 = 44)
	; idx64 -> A
	pla                           ; A = sq
	pha                           ; keep a copy
	lsr	a
	lsr	a
	lsr	a
	lsr	a                     ; sq>>4 (rank index 0..7)
	sta	__rc19                ; reuse __rc19 as tmp
	lda	#7
	sec
	sbc	__rc19                ; 7-(sq>>4)
	asl	a
	asl	a
	asl	a                     ; *8
	sta	__rc19
	pla                           ; A = sq
	and	#7                    ; file
	clc
	adc	__rc19                ; A = idx64 (0..63)
	; build idx64*48 (16-bit) in __rc20/21
	sta	__rc20
	lda	#0
	sta	__rc21
	asl	__rc20
	rol	__rc21                ; *2
	asl	__rc20
	rol	__rc21                ; *4
	asl	__rc20
	rol	__rc21                ; *8
	asl	__rc20
	rol	__rc21                ; *16
	; save *16 (push hi then lo so the pull order is lo,hi)
	lda	__rc21
	pha
	lda	__rc20
	pha
	asl	__rc20
	rol	__rc21                ; *32
	pla                           ; A = *16 lo
	clc
	adc	__rc20
	sta	__rc20                ; *48 lo
	pla                           ; A = *16 hi
	adc	__rc21
	sta	__rc21                ; *48 hi
	; + pidx4 (byte)
	lda	__rc20
	clc
	adc	__rc13
	sta	__rc20
	lda	__rc21
	adc	#0
	sta	__rc21
	; + base Z_PIECE
	lda	__rc20
	clc
	adc	#mos16lo(Z_PIECE)
	sta	__rc20
	lda	__rc21
	adc	#mos16hi(Z_PIECE)
	sta	__rc21
	; XOR the 4-byte entry into the hash
	ldy	#0
	lda	(__rc20),y
	eor	__rc15
	sta	__rc15
	iny
	lda	(__rc20),y
	eor	__rc16
	sta	__rc16
	iny
	lda	(__rc20),y
	eor	__rc17
	sta	__rc17
	iny
	lda	(__rc20),y
	eor	__rc18
	sta	__rc18
	rts

.Lfunc_end_mm:
	.size	make_move, .Lfunc_end_mm-make_move
