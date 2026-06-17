; ============================================================================
; gen_pseudo_6502.s
;
; Hand-written 6502 assembly replacement for native/movegen.c's gen_pseudo(),
; compiled by llvm-mos (mos-sim) and linked INSTEAD of the C body for the 6502
; image. BIT-IDENTICAL behavior to the C function: same pseudo-move SET and the
; same emission ORDER (search tie-breaks depend on order).
;
; Built ONLY for the mos-sim 6502 image / c64 image. The C body in movegen.c is
; #ifdef'd out when CREF_ASM_GEN_PSEUDO is defined (the build passes
; -DCREF_ASM_GEN_PSEUDO only on those compiles and adds this .s to the link
; line). The host (clang) build keeps the C body, which is the bit-exact oracle.
;
; ----------------------------------------------------------------------------
; ABI (derived empirically via `mos-sim-clang -Os -S -fno-lto -DCREF_ASM_GEN_PSEUDO
; movegen.c` and reading the gen_legal call site; confirmed against
; MOSCallingConv.td: A/X/Y + RS1..RS9 (=__rc2..__rc19) are caller-saved;
; RS0 (=__rc0/1, soft stack ptr) and RS10..RS15 (=__rc20..__rc31) are callee-
; saved):
;
;   C prototype: int gen_pseudo(const Board *b, Move *list)
;   Move = { uint8 from, to, promo, flags }  (4-byte struct in memory)
;
;   in:  b    ptr -> __rc2 (lo) / __rc3 (hi)   (points at b->sq[0])
;        list ptr -> __rc4 (lo) / __rc5 (hi)   (Move* output array)
;   out: int n (move count, 0..~218) -> A (lo) / X (hi=0)
;
; This function CALLS is_square_attacked (for castling legality). Its ABI:
;   int is_square_attacked(const Board *b, int sq, int by_white)
;        b        ptr -> __rc2 (lo) / __rc3 (hi)
;        sq       i16 -> A (lo) / X (hi)
;        by_white i16 -> __rc4 (lo) / __rc5 (hi)
;   out: int 0/1 -> A.   It preserves __rc2/__rc3 (its (zp),Y base) but may
;   clobber A,X,Y and all caller-saved imaginary regs (__rc4..__rc19).
;
; Because is_square_attacked may clobber every caller-saved reg, the few values
; that must SURVIVE those calls (in the castling block) live in callee-saved
; regs: the output write pointer (__rc20/__rc21) and the move count n (__rc22).
; b stays in __rc2/__rc3, which is_square_attacked preserves. We pha/pla
; __rc20..__rc22 at entry/exit to honor OUR caller's callee-saved contract.
;
; Register plan:
;   CALLEE-SAVED (pushed at entry, popped at exit; survive is_square_attacked):
;     __rc20/__rc21  wp   = &list[n]  (write pointer; += 4 per move emitted)
;     __rc22         n    = move count (byte; max chess pseudo-moves < 256)
;   LOOP INVARIANTS (caller-saved; set once, live for the whole board scan; the
;   board scan makes NO calls so caller-saved is safe there):
;     __rc8   sq            (current 0x88 square, 0..127)
;     __rc9   my_color      (0x80 if white to move, else 0x00)
;     __rc10  push          (pawn push delta byte: $F0=-16 white, $10=+16 black)
;     __rc11  promo_row_hi  (high nibble of pawn promotion target: $00 / $70)
;     __rc12  start_row_hi  (high nibble of pawn start rank: $60 / $10)
;   VOLATILE SCRATCH (caller-saved; reused freely; some clobbered by `emit`):
;     __rc13  emit arg: from   (also general scratch)
;     __rc14  emit arg: promo
;     __rc15  emit arg: flags
;     __rc16  ray/offset delta byte (current direction step)
;     __rc17  direction index (offset-table loop counter)
;     __rc18  t (target square byte) / general scratch
;     __rc19  piece byte / "two" square / noff / general scratch
;   b pointer stays in __rc2/__rc3 (the (zp),Y base for board reads).
;
; `emit` (local subroutine) writes ONE move and advances wp/n:
;   in:  __rc13=from  A=to  __rc14=promo  __rc15=flags
;   out: stores [from,to,promo,flags] at (wp); wp+=4; n+=1.
;        clobbers A,Y. Preserves __rc8..__rc12 and __rc16/__rc17/__rc18/__rc19,
;        so it is safe to call from inside the offset/ray loops.
;
; BRANCH-RANGE NOTE: this function is far larger than the 8-bit conditional
; branch reach (-128..+127). The integrated assembler SILENTLY truncates an
; out-of-range bcc/bcs/beq/bne displacement rather than erroring, corrupting
; control flow. So every conditional branch whose target could be far uses the
; invert-and-JMP idiom (a short branch over a 3-byte absolute jmp); JMP is 16-bit
; and always in range. Short branches are used ONLY for provably-near targets.
;
; Board geometry (board.h):
;   piece byte = type | (0x80 if white); empty = 0; type 1..6 = P,N,B,R,Q,K
;   offboard test: (idx & 0x88) != 0.  All 0x88 byte arithmetic wraps mod 256,
;   which is exactly what the off-board test needs (the C does int arithmetic but
;   only its low byte matters: 0x88 tests only low-byte bits, and indices that
;   stay on-board are 0..119 so their low byte == their value).
;   Board fields (int=16-bit on mos): sq=0  wtm=128  wk=130  bk=132
;   castle=134  ep=136.  ep = -1 ($FFFF) when none, else a 0..119 square (hi=0).
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
	.zeropage	__rc14
	.zeropage	__rc15
	.zeropage	__rc16
	.zeropage	__rc17
	.zeropage	__rc18
	.zeropage	__rc19
	.zeropage	__rc20
	.zeropage	__rc21
	.zeropage	__rc22

	.section	.text.gen_pseudo,"ax",@progbits
	.globl	gen_pseudo
	.type	gen_pseudo,@function

PT_PAWN   = 1
PT_KNIGHT = 2
PT_BISHOP = 3
PT_ROOK   = 4
PT_QUEEN  = 5
PT_KING   = 6

MF_CAPTURE  = 1
MF_DOUBLE   = 2
MF_EP       = 4
MF_CASTLE_K = 8
MF_CASTLE_Q = 16
MF_PROMO    = 32

CASTLE_WK = 1
CASTLE_WQ = 2
CASTLE_BK = 4
CASTLE_BQ = 8

gen_pseudo:
	; --- save callee-saved regs we use ---
	lda	__rc20
	pha
	lda	__rc21
	pha
	lda	__rc22
	pha

	; wp = list (in __rc4/__rc5 incoming) -> __rc20/__rc21 ; n = 0
	lda	__rc4
	sta	__rc20
	lda	__rc5
	sta	__rc21
	lda	#0
	sta	__rc22                ; n = 0

	; --- compute side-to-move invariants from b->wtm (int16 @128) ---
	ldy	#128
	lda	(__rc2),y             ; b->wtm low byte (0 or 1; nonzero => white)
	beq	.Lblack_stm
	; white to move
	lda	#$80
	sta	__rc9                 ; my_color = 0x80
	lda	#$F0
	sta	__rc10                ; push = -16
	lda	#$00
	sta	__rc11                ; promo_row_hi = 0x00
	lda	#$60
	sta	__rc12                ; start_row_hi = 0x60
	jmp	.Lscan_init
.Lblack_stm:
	lda	#$00
	sta	__rc9                 ; my_color = 0x00
	lda	#$10
	sta	__rc10                ; push = +16
	lda	#$70
	sta	__rc11                ; promo_row_hi = 0x70
	lda	#$10
	sta	__rc12                ; start_row_hi = 0x10

.Lscan_init:
	lda	#0
	sta	__rc8                 ; sq = 0

; =====================================================================
; OUTER LOOP over sq = 0..127
; =====================================================================
.Lsq_loop:
	lda	__rc8
	and	#$88
	beq	.Lsq_onboard          ; near
	jmp	.Lsq_next
.Lsq_onboard:
	; pc = b->sq[sq]
	ldy	__rc8
	lda	(__rc2),y
	bne	.Lsq_occupied         ; near
	jmp	.Lsq_next             ; empty
.Lsq_occupied:
	sta	__rc19                ; save pc
	; color check: (IS_WHITE(pc)?0x80:0) != my_color  => skip
	and	#$80
	cmp	__rc9
	beq	.Lsq_mine             ; near
	jmp	.Lsq_next             ; not my color
.Lsq_mine:
	; type = pc & 7  -> dispatch
	lda	__rc19
	and	#7
	cmp	#PT_PAWN
	bne	.Lnot_pawn
	jmp	.Ldo_pawn
.Lnot_pawn:
	cmp	#PT_KNIGHT
	bne	.Lnot_knight
	jmp	.Ldo_knight
.Lnot_knight:
	cmp	#PT_KING
	bne	.Lnot_king
	jmp	.Ldo_king
.Lnot_king:
	cmp	#PT_BISHOP
	bne	.Lnot_bishop
	jmp	.Ldo_bishop
.Lnot_bishop:
	cmp	#PT_ROOK
	bne	.Lnot_rook
	jmp	.Ldo_rook
.Lnot_rook:
	cmp	#PT_QUEEN
	bne	.Lpc_default
	jmp	.Ldo_queen
.Lpc_default:
	jmp	.Lsq_next             ; unknown type: nothing

; ---------------------------------------------------------------------
.Lsq_next:
	inc	__rc8
	lda	__rc8
	cmp	#128
	beq	.Lloop_done           ; near
	jmp	.Lsq_loop
.Lloop_done:
	jmp	.Lcastling

; =====================================================================
; emit: store one move, advance wp/n.
;   in: __rc13=from  A=to  __rc14=promo  __rc15=flags
; =====================================================================
emit:
	ldy	#0
	pha                           ; save to
	lda	__rc13
	sta	(__rc20),y            ; from
	pla                           ; to
	iny
	sta	(__rc20),y            ; to
	lda	__rc14
	iny
	sta	(__rc20),y            ; promo
	lda	__rc15
	iny
	sta	(__rc20),y            ; flags
	; wp += 4
	lda	__rc20
	clc
	adc	#4
	sta	__rc20
	bcc	.Lemit_non
	inc	__rc21
.Lemit_non:
	inc	__rc22                ; n++
	rts

; emit_promos: emit 4 promotions N,B,R,Q with flags = base|MF_PROMO.
;   in: __rc13=from  __rc18=to  __rc15=base_flags
;   uses: __rc14=promo, A.  Preserves __rc8..__rc12,__rc16,__rc17,__rc19.
;   NOTE: 'to' is taken from __rc18 (NOT A) so callers can pass it stably.
emit_promos:
	; flags arg for emit = base | MF_PROMO
	lda	__rc15
	ora	#MF_PROMO
	sta	__rc15
	lda	#PT_KNIGHT
	sta	__rc14
	lda	__rc18
	jsr	emit
	lda	#PT_BISHOP
	sta	__rc14
	lda	__rc18
	jsr	emit
	lda	#PT_ROOK
	sta	__rc14
	lda	__rc18
	jsr	emit
	lda	#PT_QUEEN
	sta	__rc14
	lda	__rc18
	jsr	emit
	rts

; =====================================================================
; PAWN
; =====================================================================
.Ldo_pawn:
	; from = sq for all pawn emits
	lda	__rc8
	sta	__rc13                ; emit from = sq

	; --- single push: one = sq + push ---
	lda	__rc8
	clc
	adc	__rc10                ; A = one
	sta	__rc18                ; t/one
	and	#$88
	beq	.Lpawn_one_on         ; near
	jmp	.Lpawn_caps           ; one off-board -> skip push entirely
.Lpawn_one_on:
	ldy	__rc18
	lda	(__rc2),y
	beq	.Lpawn_one_empty      ; near
	jmp	.Lpawn_caps           ; one occupied -> no push
.Lpawn_one_empty:
	; (one & 0xF0) == promo_row_hi ?
	lda	__rc18
	and	#$F0
	cmp	__rc11
	bne	.Lpawn_one_quiet      ; near -> not promo
	; promotions on single push: base_flags = 0
	lda	#0
	sta	__rc15
	jsr	emit_promos
	jmp	.Lpawn_caps
.Lpawn_one_quiet:
	; quiet single push: promo=0 flags=0
	lda	#0
	sta	__rc14
	lda	#0
	sta	__rc15
	lda	__rc18                ; to = one
	jsr	emit
	; double push if (sq & 0xF0)==start_row_hi
	lda	__rc8
	and	#$F0
	cmp	__rc12
	beq	.Lpawn_try_double     ; near
	jmp	.Lpawn_caps
.Lpawn_try_double:
	; two = one + push
	lda	__rc18                ; one
	clc
	adc	__rc10
	sta	__rc19                ; two
	and	#$88
	beq	.Lpawn_two_on         ; near
	jmp	.Lpawn_caps           ; two off-board
.Lpawn_two_on:
	ldy	__rc19
	lda	(__rc2),y
	beq	.Lpawn_two_empty      ; near
	jmp	.Lpawn_caps           ; two occupied
.Lpawn_two_empty:
	lda	#0
	sta	__rc14                ; promo = 0
	lda	#MF_DOUBLE
	sta	__rc15                ; flags
	lda	__rc19                ; to = two
	jsr	emit
	; fall through to captures

; --- pawn captures: caps[0]=sq+push-1, caps[1]=sq+push+1 ---
.Lpawn_caps:
	; ci = 0 : t = sq + push - 1
	lda	__rc8
	clc
	adc	__rc10
	sec
	sbc	#1                    ; A = sq+push-1
	sta	__rc18                ; t
	jsr	.Lpawn_one_capture
	; ci = 1 : t = sq + push + 1
	lda	__rc8
	clc
	adc	__rc10
	clc
	adc	#1                    ; A = sq+push+1
	sta	__rc18                ; t
	jsr	.Lpawn_one_capture
	jmp	.Lsq_next

; helper: process one pawn capture target in __rc18.  from already in __rc13=sq.
; Mirrors the C: if OFFBOARD skip; else target=b->sq[t]; if target && enemy ->
; promo-cap (promo row) or capture; else if target==0 && ep>=0 && t==ep -> EP.
.Lpawn_one_capture:
	lda	__rc18
	and	#$88
	beq	.Lpc_onboard          ; near
	rts                           ; off-board -> continue
.Lpc_onboard:
	ldy	__rc18
	lda	(__rc2),y             ; target
	bne	.Lpc_target_nonempty  ; near
	; target == 0: en passant?  ep>=0 && t==ep
	; ep int16 @136: lo @136, hi @137.  ep>=0  <=> hi==0 (valid ep has hi 0).
	ldy	#137
	lda	(__rc2),y             ; ep hi
	beq	.Lpc_ep_hi0           ; near
	rts                           ; ep<0 (hi=$FF) -> no ep
.Lpc_ep_hi0:
	ldy	#136
	lda	(__rc2),y             ; ep lo
	cmp	__rc18                ; == t ?
	beq	.Lpc_do_ep            ; near
	rts
.Lpc_do_ep:
	lda	#0
	sta	__rc14                ; promo=0
	lda	#(MF_EP | MF_CAPTURE)
	sta	__rc15                ; flags = 5
	lda	__rc18                ; to = t
	jmp	emit                  ; tail (emit rts == our rts)
.Lpc_target_nonempty:
	sta	__rc19                ; save target byte
	and	#$80
	cmp	__rc9                 ; (IS_WHITE?0x80:0)==my_color ?
	bne	.Lpc_enemy            ; near -> enemy (NOT my color)
	rts                           ; friendly target -> nothing
.Lpc_enemy:
	; (t & 0xF0) == promo_row_hi ?
	lda	__rc18
	and	#$F0
	cmp	__rc11
	beq	.Lpc_promo_cap        ; near
	; plain capture
	lda	#0
	sta	__rc14
	lda	#MF_CAPTURE
	sta	__rc15
	lda	__rc18                ; to = t
	jmp	emit                  ; tail
.Lpc_promo_cap:
	lda	#MF_CAPTURE
	sta	__rc15                ; base_flags = MF_CAPTURE (emit_promos adds PROMO)
	jmp	emit_promos           ; tail (to already in __rc18)

; =====================================================================
; KNIGHT  (offsets in knight_off[8]; empty->quiet, enemy->capture)
; =====================================================================
.Ldo_knight:
	lda	__rc8
	sta	__rc13                ; from = sq
	ldx	#0
.Lkn_loop:
	stx	__rc17                ; save index
	lda	__rc8
	clc
	adc	knight_off,x
	sta	__rc18                ; t
	jsr	.Lstep_target         ; handle empty/enemy at __rc18
	ldx	__rc17
	inx
	cpx	#8
	bne	.Lkn_loop             ; near
	jmp	.Lsq_next

; =====================================================================
; KING  (offsets in king_off[8])
; =====================================================================
.Ldo_king:
	lda	__rc8
	sta	__rc13                ; from = sq
	ldx	#0
.Lkg_loop:
	stx	__rc17
	lda	__rc8
	clc
	adc	king_off,x
	sta	__rc18
	jsr	.Lstep_target
	ldx	__rc17
	inx
	cpx	#8
	bne	.Lkg_loop             ; near
	jmp	.Lsq_next

; helper: knight/king non-sliding target at __rc18 (from=__rc13=sq).
;   if OFFBOARD -> nothing.  target=b->sq[t]; ==0 -> quiet; else enemy -> capture
;   (friendly -> nothing).  Clobbers A,Y; preserves X via caller saving __rc17.
.Lstep_target:
	lda	__rc18
	and	#$88
	beq	.Lst_onboard          ; near
	rts
.Lst_onboard:
	ldy	__rc18
	lda	(__rc2),y
	bne	.Lst_occupied         ; near
	; empty -> quiet
	lda	#0
	sta	__rc14
	lda	#0
	sta	__rc15
	lda	__rc18                ; to = t
	jmp	emit                  ; tail
.Lst_occupied:
	and	#$80
	cmp	__rc9
	bne	.Lst_enemy            ; near (NOT my color)
	rts                           ; friendly -> nothing
.Lst_enemy:
	lda	#0
	sta	__rc14
	lda	#MF_CAPTURE
	sta	__rc15
	lda	__rc18
	jmp	emit                  ; tail

; =====================================================================
; SLIDERS: bishop / rook / queen.  Walk each direction until off-board or a
; piece blocks.  empty->quiet & continue; enemy->capture & STOP; friendly->STOP.
; __rc17 = direction index, __rc18 = noff, __rc16 = current offset, __rc19 = t.
; A small dispatcher loads the table base into the loop; we keep the table as a
; pointer comparison via separate entry labels per piece.
; =====================================================================
.Ldo_bishop:
	lda	__rc8
	sta	__rc13                ; from = sq
	lda	#4
	sta	__rc18                ; noff = 4
	ldx	#0
.Lbi_dir:
	stx	__rc17
	lda	bishop_off,x
	sta	__rc16                ; offset
	jsr	.Lslider_ray
	ldx	__rc17
	inx
	cpx	__rc18
	bne	.Lbi_dir              ; near
	jmp	.Lsq_next

.Ldo_rook:
	lda	__rc8
	sta	__rc13
	lda	#4
	sta	__rc18
	ldx	#0
.Lro_dir:
	stx	__rc17
	lda	rook_off,x
	sta	__rc16
	jsr	.Lslider_ray
	ldx	__rc17
	inx
	cpx	__rc18
	bne	.Lro_dir              ; near
	jmp	.Lsq_next

.Ldo_queen:
	lda	__rc8
	sta	__rc13
	lda	#8
	sta	__rc18                ; noff = 8 (uses king_off table = the 8 ray dirs)
	ldx	#0
.Lqu_dir:
	stx	__rc17
	lda	king_off,x
	sta	__rc16
	jsr	.Lslider_ray
	ldx	__rc17
	inx
	cpx	__rc18
	bne	.Lqu_dir              ; near
	jmp	.Lsq_next

; ray walk for one direction.  offset in __rc16, from=__rc13=sq.
;   t = sq + off; while !OFFBOARD: p=b->sq[t]; if p==0 quiet & step;
;   else { if enemy capture; break }.
; Clobbers A,Y,__rc19.  Preserves __rc16,__rc17,__rc18 (so the dir loop survives;
; emit also preserves them).
.Lslider_ray:
	lda	__rc8
	clc
	adc	__rc16                ; t = sq + off
	sta	__rc19                ; t
.Lsr_walk:
	lda	__rc19
	and	#$88
	beq	.Lsr_on               ; near
	rts                           ; off-board -> end of ray
.Lsr_on:
	ldy	__rc19
	lda	(__rc2),y             ; p
	bne	.Lsr_blocker          ; near
	; empty -> quiet move, then step
	lda	#0
	sta	__rc14
	lda	#0
	sta	__rc15
	lda	__rc19                ; to = t   (emit takes to in A)
	; NOTE: emit clobbers A,Y but preserves __rc16/17/18/19 and invariants.
	jsr	emit
	; t += off
	lda	__rc19
	clc
	adc	__rc16
	sta	__rc19
	jmp	.Lsr_walk
.Lsr_blocker:
	and	#$80
	cmp	__rc9
	bne	.Lsr_enemy            ; near (NOT my color)
	rts                           ; friendly blocker -> stop, no move
.Lsr_enemy:
	lda	#0
	sta	__rc14
	lda	#MF_CAPTURE
	sta	__rc15
	lda	__rc19                ; to = t
	jsr	emit
	rts                           ; capture then STOP

; =====================================================================
; CASTLING (after all piece moves).  opp_white = white ? 0 : 1.
; White: WK (e1=116->g1=118) then WQ (->c1=114).
; Black: BK (e8=4->g8=6) then BQ (->c8=2).
; Each guard: castle bit set, the path squares empty, and king-path squares not
; attacked by opp.  is_square_attacked may clobber caller-saved regs; b stays in
; __rc2/3 (preserved by isa), wp/n in callee-saved __rc20..22.
; =====================================================================
.Lcastling:
	; reload white-to-move (int16 @128 low byte) into __rc13 (0/1), and
	; set __rc14 = opp_white (white?0:1) for is_square_attacked's by_white arg.
	ldy	#128
	lda	(__rc2),y
	sta	__rc13                ; white (0/1)
	bne	.Lcas_white
	; black to move: opp_white = 1
	lda	#1
	sta	__rc14
	jmp	.Lcas_black
.Lcas_white:
	lda	#0
	sta	__rc14                ; opp_white = 0

	; --- WK: (castle & CASTLE_WK) && sq[117]==0 && sq[118]==0 &&
	;          !isa(116) && !isa(117) && !isa(118) -> add 116->118 CASTLE_K
	ldy	#134
	lda	(__rc2),y             ; castle (low byte)
	and	#CASTLE_WK
	bne	.Lwk_bit              ; near
	jmp	.Lwq_check
.Lwk_bit:
	ldy	#117
	lda	(__rc2),y
	beq	.Lwk_f1               ; near
	jmp	.Lwq_check
.Lwk_f1:
	ldy	#118
	lda	(__rc2),y
	beq	.Lwk_g1               ; near
	jmp	.Lwq_check
.Lwk_g1:
	lda	#116
	jsr	.Lisa_path            ; A=sq -> returns Z=1 if NOT attacked
	beq	.Lwk_e1ok             ; near (not attacked)
	jmp	.Lwq_check
.Lwk_e1ok:
	lda	#117
	jsr	.Lisa_path
	beq	.Lwk_f1ok             ; near
	jmp	.Lwq_check
.Lwk_f1ok:
	lda	#118
	jsr	.Lisa_path
	beq	.Lwk_emit             ; near
	jmp	.Lwq_check
.Lwk_emit:
	lda	#116
	sta	__rc13                ; from = 116  (note: __rc13 reused as emit from)
	lda	#0
	sta	__rc14                ; promo = 0  (also was opp_white=0; white-only so ok)
	lda	#MF_CASTLE_K
	sta	__rc15
	lda	#118                  ; to = g1
	jsr	emit
	; opp_white must be restored to 0 for WQ (it already is for white)
.Lwq_check:
	; reload opp_white = 0 (white path)
	lda	#0
	sta	__rc14
	ldy	#134
	lda	(__rc2),y
	and	#CASTLE_WQ
	bne	.Lwq_bit              ; near
	jmp	.Lcas_done
.Lwq_bit:
	ldy	#115
	lda	(__rc2),y
	beq	.Lwq_d1               ; near
	jmp	.Lcas_done
.Lwq_d1:
	ldy	#114
	lda	(__rc2),y
	beq	.Lwq_c1               ; near
	jmp	.Lcas_done
.Lwq_c1:
	ldy	#113
	lda	(__rc2),y
	beq	.Lwq_b1               ; near
	jmp	.Lcas_done
.Lwq_b1:
	lda	#116
	jsr	.Lisa_path
	beq	.Lwq_e1ok             ; near
	jmp	.Lcas_done
.Lwq_e1ok:
	lda	#115
	jsr	.Lisa_path
	beq	.Lwq_d1ok             ; near
	jmp	.Lcas_done
.Lwq_d1ok:
	lda	#114
	jsr	.Lisa_path
	beq	.Lwq_emit             ; near
	jmp	.Lcas_done
.Lwq_emit:
	lda	#116
	sta	__rc13
	lda	#0
	sta	__rc14
	lda	#MF_CASTLE_Q
	sta	__rc15
	lda	#114                  ; to = c1
	jsr	emit
	jmp	.Lcas_done

.Lcas_black:
	; opp_white = 1 (set above). __rc14 holds it ONLY until we reuse it; we keep
	; opp_white in __rc16 (callee-saved? no -- caller-saved, but isa preserves
	; nothing; we re-set it before each isa call from a constant). Use constant 1.
	; --- BK: (castle & CASTLE_BK) && sq[5]==0 && sq[6]==0 &&
	;          !isa(4) && !isa(5) && !isa(6) -> add 4->6 CASTLE_K
	ldy	#134
	lda	(__rc2),y
	and	#CASTLE_BK
	bne	.Lbk_bit              ; near
	jmp	.Lbq_check
.Lbk_bit:
	ldy	#5
	lda	(__rc2),y
	beq	.Lbk_f8               ; near
	jmp	.Lbq_check
.Lbk_f8:
	ldy	#6
	lda	(__rc2),y
	beq	.Lbk_g8               ; near
	jmp	.Lbq_check
.Lbk_g8:
	lda	#1
	sta	__rc14                ; opp_white = 1
	lda	#4
	jsr	.Lisa_path
	beq	.Lbk_e8ok             ; near
	jmp	.Lbq_check
.Lbk_e8ok:
	lda	#1
	sta	__rc14
	lda	#5
	jsr	.Lisa_path
	beq	.Lbk_f8ok             ; near
	jmp	.Lbq_check
.Lbk_f8ok:
	lda	#1
	sta	__rc14
	lda	#6
	jsr	.Lisa_path
	beq	.Lbk_emit             ; near
	jmp	.Lbq_check
.Lbk_emit:
	lda	#4
	sta	__rc13
	lda	#0
	sta	__rc14                ; promo = 0
	lda	#MF_CASTLE_K
	sta	__rc15
	lda	#6                    ; to = g8
	jsr	emit
.Lbq_check:
	ldy	#134
	lda	(__rc2),y
	and	#CASTLE_BQ
	bne	.Lbq_bit              ; near
	jmp	.Lcas_done
.Lbq_bit:
	ldy	#3
	lda	(__rc2),y
	beq	.Lbq_d8               ; near
	jmp	.Lcas_done
.Lbq_d8:
	ldy	#2
	lda	(__rc2),y
	beq	.Lbq_c8               ; near
	jmp	.Lcas_done
.Lbq_c8:
	ldy	#1
	lda	(__rc2),y
	beq	.Lbq_b8               ; near
	jmp	.Lcas_done
.Lbq_b8:
	lda	#1
	sta	__rc14
	lda	#4
	jsr	.Lisa_path
	beq	.Lbq_e8ok             ; near
	jmp	.Lcas_done
.Lbq_e8ok:
	lda	#1
	sta	__rc14
	lda	#3
	jsr	.Lisa_path
	beq	.Lbq_d8ok             ; near
	jmp	.Lcas_done
.Lbq_d8ok:
	lda	#1
	sta	__rc14
	lda	#2
	jsr	.Lisa_path
	beq	.Lbq_emit             ; near
	jmp	.Lcas_done
.Lbq_emit:
	lda	#4
	sta	__rc13
	lda	#0
	sta	__rc14
	lda	#MF_CASTLE_Q
	sta	__rc15
	lda	#2                    ; to = c8
	jsr	emit
	; fall through

.Lcas_done:
	; return n in A (lo) / X (hi=0)
	lda	__rc22                ; n
	; restore callee-saved
	tax                           ; stash n in X temporarily (n<256)
	pla
	sta	__rc22
	pla
	sta	__rc21
	pla
	sta	__rc20
	txa                           ; A = n
	ldx	#0                    ; hi byte of return = 0
	rts

; ---------------------------------------------------------------------
; .Lisa_path: call is_square_attacked(b, A, opp_white) and set Z per result.
;   in:  A = square (0..118), __rc14 = opp_white (0/1)
;   out: Z=1 (BEQ taken) if NOT attacked (isa returned 0); Z=0 if attacked.
;   Sets up isa's ABI: b already in __rc2/3; sq in A(lo)/X(hi=0);
;   by_white in __rc4(lo)/__rc5(hi=0).  isa clobbers caller-saved regs, but our
;   live state (wp/n callee-saved, b preserved) survives; __rc13..__rc19 are
;   re-established by each castling step before use.
; ---------------------------------------------------------------------
.Lisa_path:
	pha                           ; (A=sq) -- not strictly needed but clear
	lda	__rc14
	sta	__rc4                 ; by_white lo
	lda	#0
	sta	__rc5                 ; by_white hi
	pla
	ldx	#0                    ; sq hi = 0
	jsr	is_square_attacked    ; A = 0/1
	cmp	#0                    ; set Z: Z=1 iff A==0 (not attacked)
	rts

.Lfunc_end_gp:
	.size	gen_pseudo, .Lfunc_end_gp-gen_pseudo

; =====================================================================
; offset tables (signed deltas as single bytes; index arithmetic wraps mod 256)
; =====================================================================
	.section	.rodata.gen_pseudo,"a",@progbits
knight_off:
	.byte	256-33, 256-31, 256-18, 256-14, 14, 18, 31, 33   ; -33,-31,-18,-14,14,18,31,33
king_off:
	.byte	256-17, 256-16, 256-15, 256-1, 1, 15, 16, 17     ; -17,-16,-15,-1,1,15,16,17
bishop_off:
	.byte	256-17, 256-15, 15, 17                            ; -17,-15,15,17
rook_off:
	.byte	256-16, 16, 256-1, 1                              ; -16,16,-1,1
