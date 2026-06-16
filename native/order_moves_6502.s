; ============================================================================
; order_moves_6502.s
;
; Hand-written 6502 assembly replacement for native/search.c's order_moves(),
; compiled by llvm-mos (mos-sim) and linked INSTEAD of the C body for the 6502
; image. BIT-IDENTICAL behavior to the C function.
;
; Built ONLY for the mos-sim 6502 image. The C body in search.c is #ifdef'd out
; when CREF_ASM_ORDER_MOVES is defined (the build passes -DCREF_ASM_ORDER_MOVES
; only on the mos-sim compile and adds this .s to the link line). The host
; (clang) build keeps the C body, which is the bit-exact oracle the gate checks
; against.
;
; order_moves is SELF-CONTAINED -- it calls no other function (mvv_lva and
; is_killer are inlined here). No jsr, so no callee-save bookkeeping: we touch
; ONLY caller-saved scratch (__rc2..__rc19) and the incoming argument regs, never
; the callee-saved __rc20+ band.
;
; ----------------------------------------------------------------------------
; ABI (derived empirically from `mos-sim-clang -Os -S -fno-lto search.c`, and
; confirmed against MOSCallingConv.td: A/X/Y + RS1..RS9 (=__rc2..__rc19) are
; caller-saved; RS0 (=__rc0/1, the soft stack ptr) and RS10.. are callee-saved):
;
;   C prototype:
;     void order_moves(const Board *b, Move *list, int n, Move tt_move, int ply)
;   Move = { uint8 from, to, promo, flags }  (4-byte struct, BY VALUE, in regs)
;
;   in:  b          ptr -> __rc2 (lo) / __rc3 (hi)   (points at b->sq[0])
;        list       ptr -> __rc4 (lo) / __rc5 (hi)   (Move array; read+write)
;        n          i16 -> A (lo) / X (hi)
;        tt_move.from  u8 -> __rc6
;        tt_move.to    u8 -> __rc7
;        tt_move.promo u8 -> __rc8
;        tt_move.flags u8 -> __rc9   (UNUSED by the logic)
;        ply        i16 -> __rc10 (lo) / __rc11 (hi)
;   out: void
;
;   The C reads b->wtm only for `stm`, used ONLY by the (dead) history branch.
;   The bare-6502 profile runs g_sc.history == 0, so we never touch b->wtm or
;   g_history. n is compared as a signed 16-bit int (the C loop bound); ply only
;   as `ply < 7`.
;
; Externals referenced:
;   g_score  -- int g_score[256] (i16 each, LE) scratch score array
;   g_killer -- Move g_killer[7][2] (4 bytes each): g_killer[ply][0] at
;               g_killer + ply*8, [1] at + ply*8 + 4; .from at +0, .to at +1.
;   g_sc     -- SearchConfig; g_sc.killers is the FIRST field (offset 0, i16).
;   Board    -- b->sq[] at offset 0 (only field read).
;
; LOGIC -- mirrors search.c order_moves (see that file for the canonical C):
;   have_tt = (tt.from != tt.to)
;   if have_tt && m.from==tt.from && m.to==tt.to && m.promo==tt.promo: 30000
;   elif m.flags & (MF_CAPTURE|MF_EP|MF_PROMO): 10000 + mvv_lva(b,m)
;   else (quiet): s=0; if (killers_on && ply<7 && (k=is_killer(ply,m)))
;                        s = (k==1)?9000:8900;     [history branch dead -> 0]
;   mvv_lva: victim=PT(b->sq[m.to]); if (flags&MF_EP) victim=PT_PAWN;
;            attacker=PT(b->sq[m.from]); s=MVV[victim]*16 - MVV[attacker];
;            if (flags&MF_PROMO) s += MVV[m.promo].
;     MVV[7] = {0,100,320,330,500,900,20000};  *16 == <<4 (16-bit).
;   is_killer: [0].from==m.from && [0].to==m.to -> 1;
;              elif [1].from==m.from && [1].to==m.to -> 2; else 0.
;   PT(p)=p&7.
;   Selection sort: for i: best=i; for j=i+1..n: if score[j]>score[best] (SIGNED
;     16-bit) best=j; if best!=i swap score[i]<->score[best] AND the 4-byte
;     list[i]<->list[best] in lockstep.
;
; BRANCH-RANGE NOTE: this function exceeds the 8-bit conditional-branch reach
; (-128..+127). The integrated assembler SILENTLY truncates an out-of-range
; bcc/bcs/beq/bne rather than erroring, corrupting control flow. So every
; conditional branch whose target could be far uses invert-and-JMP (a short
; branch over a 3-byte absolute jmp). Short branches only for provably-near
; targets (tight backedges, adjacent fall-throughs inside one block).
;
; ----------------------------------------------------------------------------
; ZERO-PAGE PLAN (all caller-saved RS regs; clobber freely)
; SCORING PASS:
;   __rc2/3   b ptr             (incoming; (zp),Y base for b->sq[])
;   __rc4/5   killbase=&g_killer[ply]   (valid only when killers_ok)
;   __rc6/7/8 tt.from/to/promo  (incoming)
;   __rc9     have_tt (0/1)
;   __rc10    ply low ; __rc11 killers_ok (0/1)
;   __rc12/13 n
;   __rc14/15 move cursor (advances by 4; (zp),Y base for the current Move)
;             -> reused at .Lstore_score as the g_score[i] write pointer
;   __rc16/17 m.from / m.to ; then the 16-bit score accumulator
;   __rc18/19 i (16-bit index)
; SORT PASS (args dead; full reuse):
;   __rc12/13 n
;   __rc2/3   PA (zp ptr) ; __rc4/5 PB (zp ptr) ; __rc6/7 PJ (zp ptr)
;   __rc8/9   SJ (score[j] staged 16-bit value)
;   __rc14/15 j ; __rc16/17 i ; __rc18/19 best
;   MLIST (bss) = list base ; TMP (bss) = byte temp
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

	.section	.text.order_moves,"ax",@progbits
	.globl	order_moves
	.type	order_moves,@function

PT_PAWN    = 1
MF_EP      = 4
MF_PROMO   = 32
MF_CAPMASK = 37            ; MF_CAPTURE|MF_EP|MF_PROMO = 1|4|32

order_moves:
	; save n ; stash list base (the sort needs it after the cursor is consumed)
	sta	__rc12
	stx	__rc13
	lda	__rc4
	sta	MLIST
	lda	__rc5
	sta	MLIST+1

	; have_tt = (tt.from != tt.to) -> __rc9 (0/1)
	lda	__rc6
	cmp	__rc7
	beq	.Lno_tt
	lda	#1
	sta	__rc9
	jmp	.Lhave_tt_done
.Lno_tt:
	lda	#0
	sta	__rc9
.Lhave_tt_done:

	; killers_ok = (g_sc.killers != 0 && ply < 7) -> __rc11 (0/1)
	lda	g_sc                  ; g_sc.killers lo (first field, 16-bit)
	ora	g_sc+1                ; | hi
	beq	.Lkill_off
	; signed ply < 7
	lda	__rc10
	cmp	#7
	lda	__rc11
	sbc	#0
	bvc	.Lkill_novf
	eor	#$80
.Lkill_novf:
	bmi	.Lkill_on             ; ply<7
.Lkill_off:
	lda	#0
	sta	__rc11
	jmp	.Lkill_done
.Lkill_on:
	lda	#1
	sta	__rc11
	; killbase = g_killer + ply*8  (ply<7 -> ply*8 <= 48 fits a byte)
	lda	__rc10
	asl	a
	asl	a
	asl	a
	clc
	adc	#mos16lo(g_killer)
	sta	__rc4
	lda	#mos16hi(g_killer)
	adc	#0
	sta	__rc5
.Lkill_done:

	; ---- scoring pass ----
	lda	#0
	sta	__rc18                ; i lo
	sta	__rc19                ; i hi
	lda	MLIST
	sta	__rc14                ; cursor = list base
	lda	MLIST+1
	sta	__rc15
.Lscore_loop:
	; i < n ? (signed 16-bit)
	lda	__rc18
	cmp	__rc12
	lda	__rc19
	sbc	__rc13
	bvc	.Lsc_novf
	eor	#$80
.Lsc_novf:
	bmi	.Lscore_body
	jmp	.Lsort
.Lscore_body:
	ldy	#0
	lda	(__rc14),y
	sta	__rc16                ; m.from
	iny
	lda	(__rc14),y
	sta	__rc17                ; m.to

	; ---- TT check ----
	lda	__rc9                 ; have_tt?
	beq	.Lnot_tt_move
	lda	__rc16
	cmp	__rc6
	bne	.Lnot_tt_move
	lda	__rc17
	cmp	__rc7
	bne	.Lnot_tt_move
	ldy	#2
	lda	(__rc14),y            ; m.promo
	cmp	__rc8
	bne	.Lnot_tt_move
	lda	#$30                  ; 30000 = 0x7530
	ldx	#$75
	jmp	.Lstore_score
.Lnot_tt_move:

	; ---- capture/promo class? (flags & 37) ----
	ldy	#3
	lda	(__rc14),y            ; m.flags
	tax                           ; keep flags in X
	and	#MF_CAPMASK
	bne	.Lcapture_move
	jmp	.Lquiet_move

.Lcapture_move:
	; victim = PT(b->sq[m.to]); if (flags&MF_EP) victim=PT_PAWN   (flags in X)
	txa
	and	#MF_EP
	bne	.Lvic_pawn
	ldy	__rc17                ; m.to
	lda	(__rc2),y             ; b->sq[m.to]
	and	#7
	jmp	.Lvic_have
.Lvic_pawn:
	lda	#PT_PAWN
.Lvic_have:
	asl	a                     ; victim*2
	tay
	lda	MVV,y
	sta	__rc16                ; s lo
	lda	MVV+1,y
	sta	__rc17                ; s hi
	ldy	#4
.Lvic_shl:
	asl	__rc16
	rol	__rc17                ; s <<= 4
	dey
	bne	.Lvic_shl
	; attacker = PT(b->sq[m.from])
	ldy	#0
	lda	(__rc14),y            ; m.from
	tay
	lda	(__rc2),y             ; b->sq[m.from]
	and	#7
	asl	a                     ; attacker*2
	tay
	lda	__rc16
	sec
	sbc	MVV,y
	sta	__rc16
	lda	__rc17
	sbc	MVV+1,y
	sta	__rc17
	; if (flags & MF_PROMO) s += MVV[m.promo]   (flags in X)
	txa
	and	#MF_PROMO
	beq	.Lcap_add_base
	ldy	#2
	lda	(__rc14),y            ; m.promo
	asl	a
	tay
	lda	__rc16
	clc
	adc	MVV,y
	sta	__rc16
	lda	__rc17
	adc	MVV+1,y
	sta	__rc17
.Lcap_add_base:
	; s += 10000 = 0x2710
	lda	__rc16
	clc
	adc	#$10
	sta	__rc16
	lda	__rc17
	adc	#$27
	tax                           ; X = score hi
	lda	__rc16                ; A = score lo
	jmp	.Lstore_score

.Lquiet_move:
	lda	__rc11                ; killers_ok?
	bne	.Lqk_check
	jmp	.Lquiet_zero
.Lqk_check:
	; [0].from==m.from && [0].to==m.to -> 1   (killbase = __rc4/5)
	ldy	#0
	lda	(__rc4),y
	cmp	__rc16
	bne	.Lk_try1
	ldy	#1
	lda	(__rc4),y
	cmp	__rc17
	bne	.Lk_try1
	lda	#$28                  ; 9000 = 0x2328
	ldx	#$23
	jmp	.Lstore_score
.Lk_try1:
	ldy	#4
	lda	(__rc4),y
	cmp	__rc16
	bne	.Lquiet_zero
	ldy	#5
	lda	(__rc4),y
	cmp	__rc17
	bne	.Lquiet_zero
	lda	#$C4                  ; 8900 = 0x22C4
	ldx	#$22
	jmp	.Lstore_score
.Lquiet_zero:
	lda	#0
	tax                           ; A=lo=0, X=hi=0

.Lstore_score:
	; g_score[i] = (A=lo, X=hi). Build ptr = g_score + i*2 in __rc14/15 (cursor
	; is about to be re-derived from i+1 anyway -- but we still need to advance
	; it, so save the cursor first into TMP pair? No: recompute cursor from i.
	; Simpler: reuse __rc16/17 (m.from/to are consumed) as the write pointer.
	sta	SLO
	stx	SHI
	lda	__rc18
	asl	a
	sta	TMP                   ; (i*2) lo
	lda	__rc19
	rol	a                     ; (i*2) hi
	clc
	adc	#mos16hi(g_score)
	sta	__rc17                ; ptr hi
	lda	#mos16lo(g_score)
	clc
	adc	TMP
	sta	__rc16                ; ptr lo
	bcc	.Lss_noc
	inc	__rc17
.Lss_noc:
	ldy	#0
	lda	SLO
	sta	(__rc16),y
	iny
	lda	SHI
	sta	(__rc16),y

	; cursor += 4 ; i += 1
	lda	__rc14
	clc
	adc	#4
	sta	__rc14
	lda	__rc15
	adc	#0
	sta	__rc15
	inc	__rc18
	bne	.Lscore_back          ; near: hop to the absolute jmp
	inc	__rc19
.Lscore_back:
	jmp	.Lscore_loop          ; absolute: .Lscore_loop is far

; ============================================================================
; SELECTION SORT.  args are dead; reuse __rc2..__rc9 for the zp pointers/value.
;   i -> __rc16/17 ; best -> __rc18/19 ; j -> __rc14/15
;   PJ -> __rc6/7  RUNNING pointer = &score[j] (+=2 per inner step)
;   SB -> __rc8/9  CACHED value score[best] (refreshed only when best advances)
;   PA -> __rc2/3 ; PB -> __rc4/5  (rebuilt only on the rare swap path)
;   list base = MLIST (bss)
; The inner loop is the O(n^2) hot path, so it avoids the per-iteration pointer
; multiply/rebuild: it walks PJ by 2 and compares against the cached SB.
; ============================================================================
.Lsort:
	lda	#0
	sta	__rc16                ; i lo
	sta	__rc17                ; i hi
.Louter:
	lda	__rc16
	cmp	__rc12
	lda	__rc17
	sbc	__rc13
	bvc	.Lo_novf
	eor	#$80
.Lo_novf:
	bmi	.Louter_body
	jmp	.Ldone
.Louter_body:
	; best = i
	lda	__rc16
	sta	__rc18
	lda	__rc17
	sta	__rc19
	; j = i + 1
	lda	__rc16
	clc
	adc	#1
	sta	__rc14
	lda	__rc17
	adc	#0
	sta	__rc15
	; PJ = &score[j] = &score[i+1] = g_score + (i+1)*2   (running pointer; +=2/iter)
	lda	__rc14
	asl	a
	sta	TMP
	lda	__rc15
	rol	a
	clc
	adc	#mos16hi(g_score)
	sta	__rc7                 ; PJ hi
	lda	#mos16lo(g_score)
	clc
	adc	TMP
	sta	__rc6                 ; PJ lo
	bcc	.Lpj0_noc
	inc	__rc7
.Lpj0_noc:
	; SB = score[best] = score[i]   (value cache; refreshed only when best moves)
	lda	__rc6                 ; &score[i+1] - 2 = &score[i]
	sec
	sbc	#2
	sta	__rc4                 ; PB lo (temp, points at score[i])
	lda	__rc7
	sbc	#0
	sta	__rc5                 ; PB hi
	ldy	#0
	lda	(__rc4),y
	sta	__rc8                 ; SB lo
	iny
	lda	(__rc4),y
	sta	__rc9                 ; SB hi
.Linner:
	; j < n ?
	lda	__rc14
	cmp	__rc12
	lda	__rc15
	sbc	__rc13
	bvc	.Li_novf
	eor	#$80
.Li_novf:
	bmi	.Linner_body
	jmp	.Linner_done
.Linner_body:
	; signed: score[j] > score[best] <=> SB - score[j] < 0   (PJ = &score[j])
	ldy	#0
	lda	__rc8                 ; SB lo
	sec
	sbc	(__rc6),y             ; - score[j] lo
	iny
	lda	__rc9                 ; SB hi
	sbc	(__rc6),y             ; - score[j] hi
	bvc	.Lcmp_novf
	eor	#$80
.Lcmp_novf:
	bpl	.Lno_newbest          ; >=0 -> keep best
	; score[j] > score[best] -> best = j ; SB = score[j]
	lda	__rc14
	sta	__rc18
	lda	__rc15
	sta	__rc19
	ldy	#0
	lda	(__rc6),y
	sta	__rc8                 ; SB lo = score[j]
	iny
	lda	(__rc6),y
	sta	__rc9                 ; SB hi
.Lno_newbest:
	; j++ ; PJ += 2
	inc	__rc14
	bne	.Lpj_inc
	inc	__rc15
.Lpj_inc:
	lda	__rc6
	clc
	adc	#2
	sta	__rc6
	bcc	.Linner_back          ; near
	inc	__rc7
.Linner_back:
	jmp	.Linner               ; absolute: .Linner is far
.Linner_done:
	; if (best != i) swap
	lda	__rc18
	cmp	__rc16
	bne	.Ldo_swap
	lda	__rc19
	cmp	__rc17
	bne	.Ldo_swap
	jmp	.Lnext_i
.Ldo_swap:
	; PA = &score[i]
	lda	__rc16
	asl	a
	sta	TMP
	lda	__rc17
	rol	a
	clc
	adc	#mos16hi(g_score)
	sta	__rc3                 ; PA hi
	lda	#mos16lo(g_score)
	clc
	adc	TMP
	sta	__rc2                 ; PA lo
	bcc	.Lpa_noc
	inc	__rc3
.Lpa_noc:
	; PB = &score[best]
	lda	__rc18
	asl	a
	sta	TMP
	lda	__rc19
	rol	a
	clc
	adc	#mos16hi(g_score)
	sta	__rc5
	lda	#mos16lo(g_score)
	clc
	adc	TMP
	sta	__rc4
	bcc	.Lpb2_noc
	inc	__rc5
.Lpb2_noc:
	ldy	#0
	lda	(__rc2),y
	pha
	lda	(__rc4),y
	sta	(__rc2),y
	pla
	sta	(__rc4),y
	iny
	lda	(__rc2),y
	pha
	lda	(__rc4),y
	sta	(__rc2),y
	pla
	sta	(__rc4),y

	; swap list[i] <-> list[best]  (4 bytes)
	; PA = MLIST + i*4
	lda	__rc16
	asl	a                     ; i*2 lo
	sta	TMP
	lda	__rc17
	rol	a                     ; i*2 hi
	asl	TMP
	rol	a                     ; i*4 (hi in A, lo in TMP)
	clc
	adc	MLIST+1
	sta	__rc3
	lda	TMP
	clc
	adc	MLIST
	sta	__rc2
	bcc	.Lpa2_noc
	inc	__rc3
.Lpa2_noc:
	; PB = MLIST + best*4
	lda	__rc18
	asl	a
	sta	TMP
	lda	__rc19
	rol	a
	asl	TMP
	rol	a
	clc
	adc	MLIST+1
	sta	__rc5
	lda	TMP
	clc
	adc	MLIST
	sta	__rc4
	bcc	.Lpb3_noc
	inc	__rc5
.Lpb3_noc:
	ldy	#0
.Lswap4:
	lda	(__rc2),y
	pha
	lda	(__rc4),y
	sta	(__rc2),y
	pla
	sta	(__rc4),y
	iny
	cpy	#4
	bne	.Lswap4

.Lnext_i:
	inc	__rc16
	bne	.Louter_back          ; near: hop to the absolute jmp
	inc	__rc17
.Louter_back:
	jmp	.Louter               ; absolute: .Louter is far

.Ldone:
	rts

.Lfunc_end_om:
	.size	order_moves, .Lfunc_end_om-order_moves

; ============================================================================
; MVV-LVA piece values (inlined; matches search.c MVV[7], little-endian shorts).
; index 0..6 = {0,P,N,B,R,Q,K} = {0,100,320,330,500,900,20000}.
; ============================================================================
	.section	.rodata.order_moves,"a",@progbits
MVV:
	.short	0
	.short	100
	.short	320
	.short	330
	.short	500
	.short	900
	.short	20000

; ============================================================================
; Plain byte temps (not used as (zp),Y bases -> may live in BSS).
; ============================================================================
	.section	.bss.order_moves,"aw",@nobits
TMP:   .byte 0
SLO:   .byte 0
SHI:   .byte 0
MLIST: .byte 0,0
