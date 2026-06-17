; ============================================================================
; gen_legal_6502.s
;
; Hand-written 6502 assembly replacement for native/movegen.c's gen_legal(),
; compiled by llvm-mos (mos-sim) and linked INSTEAD of the C body for the 6502
; image. BIT-IDENTICAL behavior to the C function: same LEGAL-move SET and the
; same emission ORDER (search tie-breaks depend on order).
;
; Built ONLY for the mos-sim 6502 image / c64 image. The C body in movegen.c is
; #ifdef'd out when CREF_ASM_GEN_LEGAL is defined (the build passes
; -DCREF_ASM_GEN_LEGAL only on those compiles and adds this .s to the link
; line). The host (clang) build keeps the C body, which is the bit-exact oracle.
;
; ----------------------------------------------------------------------------
; ABI (gen_legal has the SAME C prototype as gen_pseudo, and a tail-call probe
; `int probe(...) { return gen_legal(b,list); }` compiles to a bare `jmp
; gen_legal` with NO register shuffle -> identical incoming ABI; confirmed
; against MOSCallingConv.td: A/X/Y + RS1..RS9 (=__rc2..__rc19) caller-saved;
; RS0 (=__rc0/1) and RS10..RS15 (=__rc20..__rc31) callee-saved):
;
;   C prototype: int gen_legal(const Board *b, Move *list)
;   Move = { uint8 from, to, promo, flags }  (4-byte struct in memory)
;
;   in:  b    ptr -> __rc2 (lo) / __rc3 (hi)   (points at b->sq[0])
;        list ptr -> __rc4 (lo) / __rc5 (hi)   (Move* output array)
;   out: int n (legal move count) -> A (lo) / X (hi=0)
;
; This function CALLS four helpers that are themselves hand-asm in this repo.
; ALL of them clobber every caller-saved imaginary reg (__rc2..__rc19) and A/X/Y;
; they preserve only the callee-saved regs (__rc20..__rc31, __rc0/1).  Note in
; particular that make_move/unmake_move do NOT preserve __rc2/__rc3 contractually
; (they happen to leave them put, but we do not rely on it): we keep the canonical
; `b` pointer in callee-saved storage and RELOAD __rc2/__rc3 before every call.
;
;   int gen_pseudo(const Board *b, Move *list)
;        b -> __rc2/3   list -> __rc4/5     -> A=n (count)
;   int is_square_attacked(const Board *b, int sq, int by_white)
;        b -> __rc2/3   sq -> A(lo)/X(hi)   by_white -> __rc4(lo)/__rc5(hi)
;        -> A = 0/1
;   void make_move(Board *b, Move m, Undo *u)
;        b -> __rc2/3   m.from -> A   m.to -> X   m.promo -> __rc4
;        m.flags -> __rc5   u -> __rc6(lo)/__rc7(hi)
;   void unmake_move(Board *b, Move m, const Undo *u)   -- same Move/Undo shape.
;
; Because every helper trashes the caller-saved scratch, ALL state that must live
; across the move loop is held in callee-saved regs (__rc22..__rc31).  We pha/pla
; them at entry/exit to honor OUR caller's callee-saved contract.  The pseudo
; buffer, the scratch Undo, and the pin flag array are static .bss (gen_legal is
; non-recursive, exactly as the C uses file-scope g_pseudo/g_pinned).
;
; Persistent register plan (CALLEE-SAVED; pushed at entry, popped at exit):
;   __rc22/__rc23  bptr     = b (reload into __rc2/3 before each helper call)
;   __rc24/__rc25  outptr   = &list[n] (write pointer; += 4 per legal move kept)
;   __rc26/__rc27  rdptr    = &PSEUDO[i] (read pointer; += 4 per pseudo move)
;   __rc28         left     = pseudo moves still to process (decrement to 0)
;   __rc29         stmflags = bit0 white(0/1), bit1 in_chk(0/1)
;   __rc30         ksq      = side-to-move king square (low byte 0..119)
;   __rc31         n        = legal move count (byte; chess legal moves < 256)
;
; Volatile scratch (caller-saved; only used in stretches with NO helper call):
;   __rc8..__rc19  pin-scan temporaries, current-move bytes, etc.
;
; BRANCH-RANGE NOTE: this function far exceeds the 8-bit conditional-branch reach
; (-128..+127). The integrated assembler SILENTLY truncates an out-of-range
; bcc/bcs/beq/bne displacement rather than erroring, corrupting control flow. So
; every conditional branch whose target could be far uses the invert-and-JMP
; idiom (a short branch over a 3-byte absolute jmp); JMP is 16-bit and always in
; range. Short branches are used ONLY for provably-near targets.
;
; Board geometry (board.h): piece byte = type | (0x80 if white); empty = 0;
;   type 1..6 = P,N,B,R,Q,K; offboard test (idx & 0x88)!=0; index 0..119 on-board.
;   Board fields (int=16-bit on mos): sq=0  wtm=128  wk=130  bk=132.
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
	.zeropage	__rc22
	.zeropage	__rc23
	.zeropage	__rc24
	.zeropage	__rc25
	.zeropage	__rc26
	.zeropage	__rc27
	.zeropage	__rc28
	.zeropage	__rc29
	.zeropage	__rc30
	.zeropage	__rc31

	.section	.text.gen_legal,"ax",@progbits
	.globl	gen_legal
	.type	gen_legal,@function

PT_PAWN   = 1
PT_KNIGHT = 2
PT_BISHOP = 3
PT_ROOK   = 4
PT_QUEEN  = 5
PT_KING   = 6

MF_EP       = 4

WHITE_FLAG  = 0x80

B_WTM = 128
B_WK  = 130
B_BK  = 132

; stmflags bit masks
SF_WHITE  = 1
SF_INCHK  = 2

gen_legal:
	; --- save callee-saved regs we use (honor OUR caller's contract) ---
	lda	__rc22
	pha
	lda	__rc23
	pha
	lda	__rc24
	pha
	lda	__rc25
	pha
	lda	__rc26
	pha
	lda	__rc27
	pha
	lda	__rc28
	pha
	lda	__rc29
	pha
	lda	__rc30
	pha
	lda	__rc31
	pha

	; --- stash incoming args into callee-saved storage ---
	; bptr = b  (__rc2/3) ; outptr = list (__rc4/5)
	lda	__rc2
	sta	__rc22                ; bptr lo
	lda	__rc3
	sta	__rc23                ; bptr hi
	lda	__rc4
	sta	__rc24                ; outptr lo (= list)
	lda	__rc5
	sta	__rc25                ; outptr hi

	; n = 0
	lda	#0
	sta	__rc31

	; --- np = gen_pseudo(b, PSEUDO) ---
	; b already in __rc2/3 (entry) ; list arg = PSEUDO buffer.
	lda	#mos16lo(g_legal_pseudo)
	sta	__rc4
	lda	#mos16hi(g_legal_pseudo)
	sta	__rc5
	jsr	gen_pseudo            ; A = np (0..~218), X = 0
	sta	__rc28                ; left = np

	; rdptr = PSEUDO
	lda	#mos16lo(g_legal_pseudo)
	sta	__rc26
	lda	#mos16hi(g_legal_pseudo)
	sta	__rc27

	; --- white = b->wtm ; stmflags bit0 ; ksq = white ? wk : bk ---
	; reload b into __rc2/3 (gen_pseudo clobbered caller-saved)
	lda	__rc22
	sta	__rc2
	lda	__rc23
	sta	__rc3
	ldy	#B_WTM
	lda	(__rc2),y             ; b->wtm low (0/1)
	bne	.Lwhite
	; black to move
	lda	#0
	sta	__rc29                ; stmflags = 0 (white=0, in_chk cleared later)
	ldy	#B_BK
	lda	(__rc2),y             ; ksq = b->bk
	sta	__rc30
	jmp	.Lhave_ksq
.Lwhite:
	lda	#SF_WHITE
	sta	__rc29                ; stmflags = 1 (white)
	ldy	#B_WK
	lda	(__rc2),y             ; ksq = b->wk
	sta	__rc30
.Lhave_ksq:

	; --- in_chk = is_square_attacked(b, ksq, opp_white) ---
	; opp_white = white ? 0 : 1.
	lda	__rc29
	and	#SF_WHITE
	eor	#1                    ; opp_white (1 if black-to-move, 0 if white)
	sta	__rc4                 ; by_white lo
	lda	#0
	sta	__rc5                 ; by_white hi
	; b already in __rc2/3
	lda	__rc30                ; sq = ksq
	ldx	#0                    ; sq hi = 0
	jsr	is_square_attacked    ; A = 0/1
	cmp	#0                    ; set Z from A: isa leaves Z stale (its tail `ldx #0`
	                              ; forces Z=1), so branch on A explicitly.
	beq	.Lnot_in_chk          ; near
	lda	__rc29
	ora	#SF_INCHK
	sta	__rc29                ; set in_chk bit
.Lnot_in_chk:

; ===========================================================================
; PIN SCAN.  Compute the absolutely-pinned set in ONE pass of the 8 slider rays
; from the king.  Along each ray: the first occupied square must hold a friendly
; piece to be a pin candidate (an enemy first piece -> no pin, ray ends); then
; the next occupied square, if it is an enemy slider aligned with the ray
; (queen always, else diagonal->bishop / orthogonal->rook), pins the candidate.
;
; PIN_RAY[8] = { -16,16,-1,1, -17,-15,15,17 } : idx 0..3 orthogonal, 4..7
; diagonal.  diagonal = (d >= 4).
;
; Pinned flags are stored in g_pinned[128] (1 = pinned).  We CLEAR only the
; squares set last call (recorded in g_pin_list[0..g_pin_n)) -- exactly the
; C's sparse-clear -- so this stays O(pins) not O(128) per call.
;
; my_color = white ? 0x80 : 0.  This block makes NO calls, so __rc8..__rc19 are
; free scratch:
;   __rc8  = my_color (0x80/0x00)
;   __rc9  = d (ray direction index 0..7)
;   __rc10 = delta (signed ray step byte)
;   __rc11 = diagonal flag (0 ortho, nonzero diag)
;   __rc12 = cand (friendly candidate square; $FF = none yet)
;   __rc13 = t (current ray square)
;   __rc14 = piece scratch
;   b stays in __rc2/3.
; ===========================================================================
	; clear prior pinned set: for (i=0;i<g_pin_n;i++) g_pinned[g_pin_list[i]]=0
	ldx	g_pin_n
	beq	.Lpin_cleared         ; near (nothing to clear)
.Lpin_clear_loop:
	dex
	ldy	g_pin_list,x
	lda	#0
	sta	g_pinned,y
	cpx	#0
	bne	.Lpin_clear_loop
.Lpin_cleared:
	lda	#0
	sta	g_pin_n               ; g_pin_n = 0

	; my_color = white ? 0x80 : 0
	lda	__rc29
	and	#SF_WHITE
	beq	.Lpin_mc_black
	lda	#WHITE_FLAG
	sta	__rc8
	jmp	.Lpin_dir_init
.Lpin_mc_black:
	lda	#0
	sta	__rc8
.Lpin_dir_init:
	ldx	#0                    ; d = 0
.Lpin_dir_loop:
	stx	__rc9                 ; save d
	lda	pin_ray,x
	sta	__rc10                ; delta
	; diagonal = (d >= 4)
	cpx	#4
	bcc	.Lpin_ortho
	lda	#1
	sta	__rc11                ; diagonal = 1
	jmp	.Lpin_set_diag
.Lpin_ortho:
	lda	#0
	sta	__rc11                ; diagonal = 0
.Lpin_set_diag:
	; cand = -1 ; t = ksq + delta
	lda	#$FF
	sta	__rc12                ; cand = none
	lda	__rc30                ; ksq
	clc
	adc	__rc10                ; t = ksq + delta
	sta	__rc13
.Lpin_walk:
	lda	__rc13
	and	#$88
	bne	.Lpin_dir_next        ; off-board -> end of this ray (near? -> guard)
	ldy	__rc13
	lda	(__rc2),y             ; p = b->sq[t]
	bne	.Lpin_piece           ; occupied
	; empty -> step
	lda	__rc13
	clc
	adc	__rc10
	sta	__rc13
	jmp	.Lpin_walk
.Lpin_piece:
	sta	__rc14                ; save p
	; is this the FIRST piece on the ray? cand<0 ?
	lda	__rc12
	cmp	#$FF
	bne	.Lpin_second          ; cand already set -> this is the 2nd piece
	; first piece: friendly? (IS_WHITE(p)?0x80:0) == my_color
	lda	__rc14
	and	#WHITE_FLAG
	cmp	__rc8
	beq	.Lpin_first_friendly  ; near
	jmp	.Lpin_dir_next        ; enemy first piece -> no pin, ray ends
.Lpin_first_friendly:
	lda	__rc13
	sta	__rc12                ; cand = t
	; step to next square
	lda	__rc13
	clc
	adc	__rc10
	sta	__rc13
	jmp	.Lpin_walk
.Lpin_second:
	; second piece on the ray: enemy slider aligned with the ray pins cand.
	; enemy ? (IS_WHITE(p)?0x80:0) != my_color
	lda	__rc14
	and	#WHITE_FLAG
	cmp	__rc8
	bne	.Lpin_second_enemy    ; near (NOT my color -> enemy)
	jmp	.Lpin_dir_next        ; friendly 2nd piece blocks -> no pin, ray ends
.Lpin_second_enemy:
	; pt = PT(p). QUEEN always pins; else diagonal->BISHOP, orthogonal->ROOK.
	lda	__rc14
	and	#7
	cmp	#PT_QUEEN
	beq	.Lpin_mark            ; queen aligns with every ray
	; not a queen: need (diagonal ? BISHOP : ROOK)
	ldx	__rc11                ; diagonal flag
	beq	.Lpin_need_rook
	; diagonal: need bishop
	cmp	#PT_BISHOP
	beq	.Lpin_mark
	jmp	.Lpin_dir_next        ; aligned enemy non-slider -> blocks, no pin
.Lpin_need_rook:
	cmp	#PT_ROOK
	beq	.Lpin_mark
	jmp	.Lpin_dir_next
.Lpin_mark:
	; g_pinned[cand] = 1 ; g_pin_list[g_pin_n++] = cand
	ldy	__rc12                ; cand
	lda	#1
	sta	g_pinned,y
	ldx	g_pin_n
	tya
	sta	g_pin_list,x
	inx
	stx	g_pin_n
	; ray ends after the second piece either way -> fall through to dir_next
.Lpin_dir_next:
	ldx	__rc9                 ; restore d
	inx
	cpx	#8
	beq	.Lpin_done            ; near
	jmp	.Lpin_dir_loop
.Lpin_done:

; ===========================================================================
; MAIN LOOP over pseudo moves: for (i=0;i<np;i++).
;   m = PSEUDO[i]  (from@0,to@1,promo@2,flags@3 via rdptr)
;   needs_test = in_chk || m.from==ksq || g_pinned[m.from] || (m.flags & MF_EP)
;   if !needs_test: copy m to list[n++] directly.
;   else: make_move(b,m,&U); kq = white?wk:bk (re-read); if !isa(b,kq,opp_white)
;         copy m to list[n++]; unmake_move(b,m,&U).
;
; rdptr/outptr/left/n/stmflags/ksq are callee-saved and survive all calls.
; b is reloaded into __rc2/3 from bptr before each call.
; ===========================================================================
.Lmove_loop:
	lda	__rc28                ; left
	bne	.Lmove_body           ; near
	jmp	.Lreturn              ; left==0 -> done
.Lmove_body:
	; --- needs_test? ---
	; (1) in_chk
	lda	__rc29
	and	#SF_INCHK
	bne	.Lneeds_test          ; near
	; (2) m.from == ksq ?  (m.from = PSEUDO[i][0] via rdptr)
	ldy	#0
	lda	(__rc26),y            ; m.from
	cmp	__rc30                ; ksq
	beq	.Lneeds_test          ; near
	; (3) g_pinned[m.from] ?
	tay                           ; Y = m.from
	lda	g_pinned,y
	bne	.Lneeds_test          ; near
	; (4) m.flags & MF_EP ?
	ldy	#3
	lda	(__rc26),y            ; m.flags
	and	#MF_EP
	bne	.Lneeds_test          ; near
	; --- not needed: copy m to list[n++] directly ---
	jsr	.Lcopy_move           ; copies PSEUDO[i] -> *outptr, advances outptr, n++
	jmp	.Lmove_advance

.Lneeds_test:
	; --- make_move(b, m, &U) ; king-safety probe ; unmake_move ---
	; Set up make_move ABI from PSEUDO[i] via rdptr:
	;   A=m.from  X=m.to  __rc4=m.promo  __rc5=m.flags  __rc6/7=&U  b=__rc2/3
	ldy	#2
	lda	(__rc26),y            ; m.promo
	sta	__rc4
	ldy	#3
	lda	(__rc26),y            ; m.flags
	sta	__rc5
	lda	#mos16lo(g_legal_undo)
	sta	__rc6
	lda	#mos16hi(g_legal_undo)
	sta	__rc7
	; reload b into __rc2/3
	lda	__rc22
	sta	__rc2
	lda	__rc23
	sta	__rc3
	ldy	#1
	lda	(__rc26),y            ; m.to -> X
	tax
	ldy	#0
	lda	(__rc26),y            ; m.from -> A   (last; nothing clobbers A/X now)
	jsr	make_move

	; kq = white ? bb->wk : bb->bk  (RE-READ after make_move: king may have moved)
	lda	__rc22
	sta	__rc2
	lda	__rc23
	sta	__rc3
	lda	__rc29
	and	#SF_WHITE
	beq	.Lkq_black
	ldy	#B_WK
	jmp	.Lkq_read
.Lkq_black:
	ldy	#B_BK
.Lkq_read:
	lda	(__rc2),y             ; kq (low byte; king square 0..119)
	pha                           ; save kq across arg setup
	; is_square_attacked(b, kq, opp_white)
	lda	__rc29
	and	#SF_WHITE
	eor	#1                    ; opp_white
	sta	__rc4
	lda	#0
	sta	__rc5
	pla                           ; A = kq
	ldx	#0
	jsr	is_square_attacked    ; A = 0/1
	cmp	#0                    ; set Z from A: isa leaves Z stale (its tail `ldx #0`
	                              ; forces Z=1), so branch on A explicitly.
	; if (!attacked) copy m to list[n++]
	bne	.Lprobe_illegal       ; near (attacked -> illegal, skip copy)
	jsr	.Lcopy_move
.Lprobe_illegal:
	; --- unmake_move(b, m, &U) ---  (exact round-trip restores *b)
	ldy	#2
	lda	(__rc26),y            ; m.promo (unused by unmake, but ABI slot)
	sta	__rc4
	ldy	#3
	lda	(__rc26),y            ; m.flags
	sta	__rc5
	lda	#mos16lo(g_legal_undo)
	sta	__rc6
	lda	#mos16hi(g_legal_undo)
	sta	__rc7
	lda	__rc22
	sta	__rc2
	lda	__rc23
	sta	__rc3
	ldy	#1
	lda	(__rc26),y            ; m.to -> X
	tax
	ldy	#0
	lda	(__rc26),y            ; m.from -> A
	jsr	unmake_move
	; fall through

.Lmove_advance:
	; rdptr += 4 ; left--
	lda	__rc26
	clc
	adc	#4
	sta	__rc26
	bcc	.Lmadv_nohi
	inc	__rc27
.Lmadv_nohi:
	dec	__rc28                ; left--
	jmp	.Lmove_loop

; ---------------------------------------------------------------------------
; .Lreturn: n in A (lo) / X (hi=0); restore callee-saved regs.
; ---------------------------------------------------------------------------
.Lreturn:
	lda	__rc31                ; n
	tax                           ; stash n in X (n < 256)
	; pop callee-saved in REVERSE push order
	pla
	sta	__rc31
	pla
	sta	__rc30
	pla
	sta	__rc29
	pla
	sta	__rc28
	pla
	sta	__rc27
	pla
	sta	__rc26
	pla
	sta	__rc25
	pla
	sta	__rc24
	pla
	sta	__rc23
	pla
	sta	__rc22
	txa                           ; A = n
	ldx	#0                    ; return hi = 0
	rts

; ---------------------------------------------------------------------------
; helper: .Lcopy_move
;   Copy the 4-byte Move at rdptr (__rc26/27 = &PSEUDO[i]) to the output at
;   outptr (__rc24/25 = &list[n]); advance outptr += 4; n++.
;   Clobbers A,Y.  Preserves X and all other regs (rdptr, left, etc.).
; ---------------------------------------------------------------------------
.Lcopy_move:
	ldy	#0
	lda	(__rc26),y
	sta	(__rc24),y            ; from
	iny
	lda	(__rc26),y
	sta	(__rc24),y            ; to
	iny
	lda	(__rc26),y
	sta	(__rc24),y            ; promo
	iny
	lda	(__rc26),y
	sta	(__rc24),y            ; flags
	; outptr += 4
	lda	__rc24
	clc
	adc	#4
	sta	__rc24
	bcc	.Lcm_nohi
	inc	__rc25
.Lcm_nohi:
	inc	__rc31                ; n++
	rts

.Lfunc_end_gl:
	.size	gen_legal, .Lfunc_end_gl-gen_legal

; ===========================================================================
; PIN_RAY direction table (signed deltas as single bytes; index arithmetic
; wraps mod 256).  idx 0..3 orthogonal, 4..7 diagonal.
; ===========================================================================
	.section	.rodata.gen_legal,"a",@progbits
pin_ray:
	.byte	256-16, 16, 256-1, 1, 256-17, 256-15, 15, 17   ; -16,16,-1,1,-17,-15,15,17

; ===========================================================================
; asm-internal static storage (gen_legal is non-recursive, so file-scope is safe,
; exactly as the C uses static g_pseudo / g_pinned).  The C statics are stripped
; in this build (-static), so we allocate our OWN here.
;   g_legal_pseudo : 256 Move entries * 4 bytes = 1024-byte pseudo buffer
;   g_legal_undo   : one OPAQUE Undo scratch (make/unmake own its layout); the
;                    C Undo is 24 bytes here -- reserve 32 for headroom.
;   g_pinned       : 128-byte per-0x88-square pin flag array (1 = pinned)
;   g_pin_list     : the <=8 squares set this call (for sparse clear next call)
;   g_pin_n        : count of valid entries in g_pin_list
; ===========================================================================
	.section	.bss.gen_legal,"aw",@nobits
	.p2align	1
g_legal_pseudo:
	.zero	1024
g_legal_undo:
	.zero	32
g_pinned:
	.zero	128
g_pin_list:
	.zero	8
g_pin_n:
	.zero	1
