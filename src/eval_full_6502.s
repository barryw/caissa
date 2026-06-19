; ============================================================================
; eval_full_6502.s  --  hand-written 6502 (llvm-mos / mos-sim) eval_full().
;
; PHASE-2 COMPLETE for the wholesale eval_full hand-asm project
; (docs/eval-asm-scope.md). This file implements the ENTIRE eval_full as a
; MONOLITH in asm -- the 0x88 board walk, every per-piece COUNTER, every
; positional term, the endgame flag/branch, the tapered-blend guard, the A/B
; terms, the tempo term, and the final 16-bit wrap. ***ZERO jsr to any eval.c
; term helper*** (the only external jsr's are libgcc __mulhi3/__divhi3, used by
; the tapered blend and the A/B quadratic/linear weights -- NOT eval.c terms).
;
; TERM HELPER STATUS (ALL positional terms INLINE; monolith complete; bit-exact
; 22157/22157 vs texel_eval, and the A/B bodies verified asm==C-reference over
; the full corpus with non-zero weights -- see DELIVERABLE notes):
;   INLINE asm (groups a + b + c + d + e + f):
;     advanced_pawn, pawn_pressure, knight_outpost, queen_pressure,
;     minor_pressure   (+ their inlined probes: check_white/black_pawn_at,
;     is_pawn_attacked, is_knight_attacked, is_bishop_attacked, is_queen_attacked),
;     mobility (+ inlined count_knight_mobility, count_sliding_mobility),
;     seventh_rank,
;     pawn_structure  (group c: doubled, isolated, passed-pawn bonus,
;       connected/protected/blockaded passer, rook-behind-passer, rook open/
;       semi-open file; + inlined helpers white/black_passed, white/black_
;       connected, white/black_protected, white/black_blockaded, white/black_
;       rook_behind),
;     king_pins  (group d: pins_from_king pin ray-scan + pinned_attack_pressure,
;       reusing is_pawn_attacked / is_knight_attacked),
;     king_safety (group d: single_king_safety SIGNED-BYTE accumulation then x10;
;       + inlined add8s/sub8s/byte_x10, king_zone_pressure, white/black_file_
;       exposure, penalize_white/black_file),
;     bishop_pair (eval.c 609-612),
;     endgame (group e: endgame_king_activity + endgame_rook_activity, eval.c
;       847-884; the endgame branch of the tail),
;     king_attack_escalation / pawn_storm / queen_attacks_minor (group f: the A/B
;       terms, eval.c 1084-1166; + inlined count_king_zone_attackers; each guarded
;       by its weight==0 -- the SHIPPED config has all three at 0, so their bodies
;       are corpus-cold (only the guard returns are validated by the corpus), but
;       the bodies are bit-exact to the C and were verified asm==C with non-zero
;       weights over all 22157 positions).
;   still jsr-to-C (eval.c term helpers):  NONE -- monolith complete.
; The validator stays 22157/22157 the whole way and any divergence bisects to
; exactly the one term just converted.
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
;   EvalWeights g_w -- sizeof = 110 (offsets = 2*field_index, int = 16-bit;
;   ALL confirmed via offsetof probe, mos-clang -fno-lto -Os -S):
;     +36   int doubled_pawn         (field 18)
;     +38   int isolated_pawn        (field 19)
;     +44   int rook_behind_passer   (field 22)
;     +46   int connected_passer     (field 23)
;     +48   int protected_passer     (field 24)
;     +50   int blockaded_passer     (field 25)
;     +54   int rook_open_file       (field 27)
;     +56   int rook_semi_open_file  (field 28)
;     +58   int heavy_seventh_rank   (field 29)
;     +60   int endgame_nonpawn_limit
;     +68   int passed_pawn_bonus[8] (field 34; entry = base + row*2, full 16-bit)
;     +34   int pinned_attacked      (field 17; used by pinned_attack_pressure)
;     +84   int castled              (field 42)  -- king_safety (group d)
;     +86   int pawn_shield          (field 43)
;     +88   int open_file_penalty    (field 44)
;     +90   int semi_open_file_penalty (field 45)
;     +92   int king_center          (field 46)
;     +94   int king_march_base      (field 47)  -- march pen = (advanced<<3)+base
;     +96   int king_march_step      (field 48)  -- NOT USED (march uses literal <<3)
;     +98   int king_zone_attack     (field 49)  -- king_zone_pressure penalty
;     +100  int tempo
;     +102  int trapped_penalty      (field 51)
;   ET_PINNED int[7] (externalized via EVAL_DATA): read live as
;     ET_PINNED + candidate_type*2 (full 16-bit) by pins_from_king.
;
;   ASSEMBLER QUIRK (llvm-mos integrated as): `#<(-N)` mis-assembles to `#N`
;   (the negation is dropped: <(-0x10) -> 0x10, NOT 0xF0). Pre-existing group-(a)
;   lines using it (is_pawn_attacked white / knight_outpost black) are harmless
;   ONLY because those weights default to 0. Group (c) here uses EXPLICIT byte
;   literals for negative add8 offsets (e.g. add8(sq,-0x10) -> `adc #0xF0`).
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
	.globl	ET_PINNED          ; int[7]; read live as ET_PINNED + candidate_type*2

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
W_DOUBLED_PAWN          = 36      ; field 18 (confirmed via offsetof probe)
W_ISOLATED_PAWN         = 38      ; field 19
W_ADVANCED_PAWN         = 40
W_DEEP_ADVANCED_PAWN    = 42
W_ROOK_BEHIND_PASSER    = 44      ; field 22
W_CONNECTED_PASSER      = 46      ; field 23
W_PROTECTED_PASSER      = 48      ; field 24
W_BLOCKADED_PASSER      = 50      ; field 25
W_ROOK_OPEN_FILE        = 54      ; field 27
W_ROOK_SEMI_OPEN_FILE   = 56      ; field 28
W_HEAVY_SEVENTH_RANK    = 58
W_ENDGAME_NONPAWN_LIMIT = 60
W_BISHOP_PAIR           = 52      ; field 26 (confirmed via offsetof probe)
W_ENDGAME_KING_ACTIVITY = 62      ; field 30 (confirmed via offsetof probe)
W_ENDGAME_ROOK_OPEN_FILE= 64      ; field 31
W_ENDGAME_ROOK_KING_CUTOFF = 66   ; field 32
W_KING_ATTACK_ESCALATION= 104     ; field 52 (confirmed via offsetof probe)
W_PAWN_STORM            = 106     ; field 53
W_QUEEN_ATTACKS_MINOR   = 108     ; field 54
W_PASSED_PAWN_BONUS     = 68      ; int[8] base (field 34); entry = base + row*2
W_PINNED_ATTACKED       = 34      ; field 17 (confirmed via offsetof probe)
W_CASTLED               = 84      ; field 42
W_PAWN_SHIELD           = 86      ; field 43
W_OPEN_FILE_PENALTY     = 88      ; field 44
W_SEMI_OPEN_FILE_PENALTY= 90      ; field 45
W_KING_CENTER           = 92      ; field 46
W_KING_MARCH_BASE       = 94      ; field 47 (king_march_step@96 is NOT used)
W_KING_ZONE_ATTACK      = 98      ; field 49
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
WHITE_ROOK    = 0x84
BLACK_ROOK    = 0x04
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
; PIN_SLIDER_TYPES[8] (eval.c 147): BISHOP_T(3) for diagonal dirs {0,2,5,7},
; ROOK_T(4) for orthogonal dirs {1,3,4,6}. Index matches ALLDIR_OFFS.
PINSLIDE:      .byte 3,4,3,4,4,3,4,3                            ; PIN_SLIDER_TYPES[8]

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
WALKX:    .zero  1           ; 0x88 loop index x (0..127, low byte; <128 so 1 byte)
CURPT:    .zero  1           ; current square's ptype  (survives helper clobbers)
CURCOL:   .zero  1           ; current square's color  (survives helper clobbers)
MDTMP:    .zero  2           ; scratch (mul/div blend hi-byte staging)
; ---- pawn_structure inline scratch (term group c) --------------------------
PSF:      .zero  1           ; doubled/isolated file loop index f (0..7)
PSX:      .zero  1           ; pawn_structure board-walk index x (0..127)
PSFILE:   .zero  1           ; current pawn's file (x & 7)
PSROW:    .zero  1           ; current pawn's row  (x >> 4, 0..7)
; ---- king_pins / king_safety inline scratch (term group d) -----------------
KP_KSQ:   .zero  1           ; pins_from_king: king_sq (low byte; idx)
KP_KCOL:  .zero  1           ; pins_from_king: king_color (0 or 0x80)
KP_D:     .zero  1           ; pins_from_king: direction index d (0..7)
KP_RAY:   .zero  1           ; pins_from_king: ray index (low byte)
KP_CSQ:   .zero  1           ; pins_from_king: candidate_sq
KP_CTYPE: .zero  1           ; pins_from_king: candidate_type (0 = none yet)
KS_S:     .zero  1           ; single_king_safety: signed-byte accumulator s
KS_KSQ:   .zero  1           ; single_king_safety: king_sq
KS_FILE:  .zero  1           ; single_king_safety: file (king_sq & 7)
KS_ROW:   .zero  1           ; single_king_safety: row  (king_sq >> 4)
KS_ACOL:  .zero  1           ; king_zone_pressure: attacker_color
KS_KZK:   .zero  1           ; king_zone_pressure: king_sq (separate from KS_KSQ)
KS_D:     .zero  1           ; king_zone_pressure: direction index d
KS_RAY:   .zero  1           ; king_zone_pressure: ray index
KS_I:     .zero  1           ; king_zone_pressure: knight offset index i
EXF:      .zero  1           ; file_exposure: file argument f to penalize_*_file
; ---- A/B terms inline scratch (king_attack_escalation/pawn_storm/queen_attacks_minor)
AB_X:     .zero  1           ; A/B board-walk index x (0..127)
AB_D:     .zero  1           ; A/B ray/knight direction index d (0..7)
AB_RAY:   .zero  1           ; A/B ray index (low byte)
AB_KSQ:   .zero  1           ; count_king_zone_attackers: king_sq
AB_ACOL:  .zero  1           ; count_king_zone_attackers: attacker_color
AB_CNT:   .zero  1           ; count_king_zone_attackers: counter c
AB_KFILE: .zero  1           ; pawn_storm: enemy-king file (bk_file or wk_file)
AB_QCOL:  .zero  1           ; queen_attacks_minor: queen color

	.section	.text.eval_full,"ax",@progbits
	.type	eval_full,@function

; ============================================================================
eval_full:
; ---- save Board* (board ptr arrives in __rc2/3) ----------------------------
	lda	__rc2
	sta	BPTR
	lda	__rc3
	sta	BPTR+1

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

; Establish __rc2/3 = BPTR ONCE. The per-square term helpers clobber __rc2/3,
; so they are RE-established only on the occupied-square path (just before
; .Lwalk_next). Empty squares never call a helper, so __rc2/3 survives intact
; across the loop backedge -- no per-iteration reload needed for them.
	lda	BPTR
	sta	__rc2
	lda	BPTR+1
	sta	__rc3

.Lwalk:
; ---- load piece = b[x]; if EMPTY continue ----------------------------------
	ldy	WALKX
	lda	(__rc2),y          ; A = b[x]  (__rc2/3 == BPTR, held across loop)
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
; ALL SIX are INLINE (.Ls_* local subroutines; no jsr to C).
; __rc2/3 is ALREADY == BPTR here: it is held across the loop (set once before
; .Lwalk, re-established on the occupied path before .Lwalk_next), and the path
; from .Lwalk to here (counters + advanced_pawn->.Ls_score_addAX) clobbers
; neither __rc2 nor __rc3. So no reload is needed -- the inline probes below can
; do (zp),Y board reads directly.

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
	; occupied-square term helpers clobbered __rc2/3 -> re-establish BPTR for
	; the next square's (__rc2),y load. (Empty squares skip straight to
	; .Lwalk_next with __rc2/3 still == BPTR, so this is only paid when needed.)
	lda	BPTR
	sta	__rc2
	lda	BPTR+1
	sta	__rc3
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
; bishop_pair(&e)   [INLINE, eval.c 609-612]
	jsr	.Ls_bishop_pair
; if (e.pawns != 0) pawn_structure(&e)   [INLINE, term group (c)]
	lda	E_BUF + E_PAWNS
	ora	E_BUF + E_PAWNS + 1
	bne	.Lps_enter
	jmp	.Ltail_nopawnstruct
.Lps_enter:
	jsr	.Ls_pawn_structure
.Ltail_nopawnstruct:
; if (e.endgame) endgame(&e); else { king_pins; king_safety }
	lda	E_BUF + E_ENDGAME
	ora	E_BUF + E_ENDGAME + 1
	beq	.Ltail_notend
	jsr	.Ls_endgame        ; [INLINE, eval.c 880-884]
	jmp	.Ltail_done
.Ltail_notend:
; king_pins(&e); king_safety(&e)  [INLINE, term group (d)]
	jsr	.Ls_king_pins
	jsr	.Ls_king_safety
.Ltail_done:

; ============================================================================
; A/B TERMS (eval.c 1400-1402): king_attack_escalation, pawn_storm,
; queen_attacks_minor -- each (&e).
; ============================================================================
	jsr	.Ls_king_attack_escalation   ; [INLINE, eval.c 1084-1093]
	jsr	.Ls_pawn_storm               ; [INLINE, eval.c 1101-1130]
	jsr	.Ls_queen_attacks_minor      ; [INLINE, eval.c 1134-1166]

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
; (.Lcall_term_args and .Lset_e_ptr removed: the monolith is complete -- ALL
;  positional terms are inlined, so there is no jsr-to-C term helper left that
;  needs the arg1 (&e) pointer staged. e.score and every Eval field are accessed
;  ABSOLUTELY at E_BUF; the only ZP indirect is __rc2/3 = BPTR for board reads.)
; ============================================================================

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

; ============================================================================
; .Ls_bishop_pair -- bishop_pair(e). eval.c 609-612. INLINE (no jsr to C).
;   if (e.wbishops >= 2) e.score += g_w.bishop_pair;
;   if (e.bbishops >= 2) e.score -= g_w.bishop_pair;
;   wbishops/bbishops are 16-bit ints, counts >= 0 (hi byte always 0). Faithful
;   16-bit >= 2 compare via lo cmp #2 / hi sbc #0 -> carry set => >= 2.
; ============================================================================
.Ls_bishop_pair:
; e.wbishops >= 2 ?
	lda	E_BUF + E_WBISH
	cmp	#2
	lda	E_BUF + E_WBISH + 1
	sbc	#0
	bcc	.Lbp_chk_black     ; wbishops < 2 -> skip white add
; e.score += g_w.bishop_pair
	lda	g_w + W_BISHOP_PAIR
	ldx	g_w + W_BISHOP_PAIR + 1
	jsr	.Ls_score_addAX
.Lbp_chk_black:
; e.bbishops >= 2 ?
	lda	E_BUF + E_BBISH
	cmp	#2
	lda	E_BUF + E_BBISH + 1
	sbc	#0
	bcc	.Lbp_ret           ; bbishops < 2 -> done
; e.score -= g_w.bishop_pair
	lda	g_w + W_BISHOP_PAIR
	ldx	g_w + W_BISHOP_PAIR + 1
	jmp	.Ls_score_subAX    ; tail-call (rts)
.Lbp_ret:
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
	adc	#0xF1              ; +0xF1 == sq-0x0F (mod 256). NOT #<(-0x0F): the
	                           ; llvm-mos as drops the negation (see header quirk).
	jsr	.Ls_chk_bp
	bne	.Ls_pa_yes
	lda	WALKX
	clc
	adc	#0xEF              ; +0xEF == sq-0x11 (literal; #<(-0x11) mis-assembles)
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
	adc	#0xF1              ; sq - 0x0F (literal; #<(-0x0F) mis-assembles to #0x0F)
	jsr	.Ls_chk_bp
	bne	.Lko_b_sub
	lda	WALKX
	clc
	adc	#0xEF              ; sq - 0x11 (literal; #<(-0x11) mis-assembles to #0x11)
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

; ============================================================================
; .Ls_pawn_structure -- pawn_structure(e). eval.c 718-785. TERM GROUP (c).
;   Fully INLINE: makes NO jsr to C. Sets __rc2/3 = BPTR at entry and at the
;   top of the main board walk (its passed/connected/protected helpers do
;   (zp),Y board reads off __rc2/3). wpf[]/bpf[] are already populated by the
;   main board pass. e.score is the live uint16 accumulator at E_BUF+E_SCORE.
;   Reads g_w doubled/isolated/passed_pawn_bonus[]/connected/protected/
;   blockaded/rook_behind/rook_open/rook_semi weights.
; Scratch: A/X/Y, __rc8..__rc15, PSF/PSX/PSFILE/PSROW (.bss).
; ----------------------------------------------------------------------------
.Ls_pawn_structure:
; __rc2/3 = BPTR (board base for (zp),Y reads throughout).
	lda	BPTR
	sta	__rc2
	lda	BPTR+1
	sta	__rc3

; ---- (1) DOUBLED (eval.c 725-728) ------------------------------------------
; for f=0..7: if wpf[f]>=2 score-=doubled; if bpf[f]>=2 score+=doubled.
; wpf/bpf are 16-bit ints (counts 0..8, hi byte always 0). Use 16-bit unsigned
; >=2 compare to be faithful.
	lda	#0
	sta	PSF
.Lps_dbl_loop:
	lda	PSF
	asl	a                  ; f*2 (int array index)
	tax
; wpf[f] >= 2 ?  (16-bit unsigned: lo cmp #2 then hi sbc #0 -> carry set => >=)
	lda	E_BUF + E_WPF, x
	cmp	#2
	lda	E_BUF + E_WPF + 1, x
	sbc	#0
	bcc	.Lps_dbl_w_no      ; wpf[f] < 2
; score -= g_w.doubled_pawn
	lda	g_w + W_DOUBLED_PAWN
	ldx	g_w + W_DOUBLED_PAWN + 1
	jsr	.Ls_score_subAX
.Lps_dbl_w_no:
	lda	PSF
	asl	a
	tax
; bpf[f] >= 2 ?
	lda	E_BUF + E_BPF, x
	cmp	#2
	lda	E_BUF + E_BPF + 1, x
	sbc	#0
	bcc	.Lps_dbl_b_no      ; bpf[f] < 2
; score += g_w.doubled_pawn
	lda	g_w + W_DOUBLED_PAWN
	ldx	g_w + W_DOUBLED_PAWN + 1
	jsr	.Ls_score_addAX
.Lps_dbl_b_no:
	inc	PSF
	lda	PSF
	cmp	#8
	bcs	.Lps_dbl_done
	jmp	.Lps_dbl_loop
.Lps_dbl_done:

; ---- (2) ISOLATED (eval.c 731-742) -----------------------------------------
; for f=0..7:
;   if wpf[f]!=0 { left=(f>0)?wpf[f-1]:0; right=(f<7)?wpf[f+1]:0;
;                  if left==0 && right==0 score-=isolated; }
;   same for bpf with += .
; Implemented via a shared "isolated check on array base in __rc10/11" helper:
;   __rc10/11 = &E_BUF+E_WPF (white) or &E_BUF+E_BPF (black); on isolated,
;   __rc8 = 1 (add) for black, 0 (sub) for white (sign of the score delta).
	lda	#0
	sta	PSF
.Lps_iso_loop:
; white: base = E_BUF+E_WPF, sign = subtract
	lda	#<(E_BUF + E_WPF)
	sta	__rc10
	lda	#>(E_BUF + E_WPF)
	sta	__rc11
	lda	#0                 ; sign flag: 0 -> subtract isolated
	sta	__rc8
	jsr	.Lps_iso_one
; black: base = E_BUF+E_BPF, sign = add
	lda	#<(E_BUF + E_BPF)
	sta	__rc10
	lda	#>(E_BUF + E_BPF)
	sta	__rc11
	lda	#1                 ; sign flag: !=0 -> add isolated
	sta	__rc8
	jsr	.Lps_iso_one
	inc	PSF
	lda	PSF
	cmp	#8
	bcs	.Lps_iso_done
	jmp	.Lps_iso_loop
.Lps_iso_done:
	jmp	.Lps_walk_init

; .Lps_iso_one -- one isolated test for file PSF over the int[8] array at
;   __rc10/11. __rc8 sign flag (0=sub, else=add). Uses A/X/Y, __rc9 (scratch).
;   pf[f] != 0 ? (16-bit OR) ; if so, left/right neighbours both 0 -> apply.
.Lps_iso_one:
	lda	PSF
	asl	a
	tay                       ; Y = f*2
	lda	(__rc10),y         ; pf[f] lo
	iny
	ora	(__rc10),y         ; | pf[f] hi
	bne	.Lps_iso_present
	rts                       ; pf[f] == 0 -> nothing
.Lps_iso_present:
; left = (f>0)?pf[f-1]:0  -> if f==0 left is 0 (treated as absent).
	lda	PSF
	beq	.Lps_iso_left0     ; f==0 -> left=0
; pf[f-1] != 0 ?  index = (f-1)*2
	sec
	sbc	#1
	asl	a
	tay
	lda	(__rc10),y
	iny
	ora	(__rc10),y
	beq	.Lps_iso_left0     ; left == 0
	rts                       ; left != 0 -> not isolated
.Lps_iso_left0:
; right = (f<7)?pf[f+1]:0 -> if f==7 right is 0.
	lda	PSF
	cmp	#7
	beq	.Lps_iso_apply     ; f==7 -> right=0 -> isolated
; pf[f+1] != 0 ?  index = (f+1)*2
	clc
	adc	#1
	asl	a
	tay
	lda	(__rc10),y
	iny
	ora	(__rc10),y
	beq	.Lps_iso_apply     ; right == 0 -> isolated
	rts                       ; right != 0 -> not isolated
.Lps_iso_apply:
; left==0 && right==0 -> apply g_w.isolated_pawn by sign flag __rc8.
	lda	g_w + W_ISOLATED_PAWN
	ldx	g_w + W_ISOLATED_PAWN + 1
	ldy	__rc8
	beq	.Lps_iso_sub       ; sign flag 0 -> subtract (white)
	jmp	.Ls_score_addAX    ; black -> add (tail-call rts)
.Lps_iso_sub:
	jmp	.Ls_score_subAX    ; white -> subtract (tail-call rts)

; ---- (3) MAIN 0x88 WALK (eval.c 749-784) -----------------------------------
; for x=0; x<128; x++, (x&8)?x+=8:0 : process rook-file & passed-pawn terms.
.Lps_walk_init:
	lda	#0
	sta	PSX
.Lps_walk:
; ensure __rc2/3 = BPTR (sub-helpers below may have left it; they always keep
; it, but the score helpers don't touch it -- keep this defensive reload cheap
; by doing it once per piece only when needed; here BPTR is intact, so we read
; b[x] directly).
	ldy	PSX
	lda	(__rc2),y          ; p = b[x]
	sta	__rc9              ; __rc9 = p (piece byte; survives until needed)
; if ((p & 0x07) != PAWN_T) -> rook-file branch + continue.
	and	#0x07
	cmp	#PT_PAWN
	beq	.Lps_is_pawn
	jmp	.Lps_not_pawn
.Lps_is_pawn:

; --- it's a pawn: file = x&7; row = x>>4 ---
	lda	PSX
	and	#0x07
	sta	PSFILE
	lda	PSX
	lsr	a
	lsr	a
	lsr	a
	lsr	a                  ; row = x >> 4 (0..7)
	sta	PSROW
; if (p & WHITE_COLOR) white-pawn branch else black-pawn branch.
	lda	__rc9
	and	#WHITE_COLOR
	bne	.Lps_white_pawn
	jmp	.Lps_black_pawn

; ===== WHITE PAWN (eval.c 767-774) =====
.Lps_white_pawn:
	jsr	.Ls_white_passed   ; A=1 if passed
	bne	.Lps_wp_passed
	jmp	.Lps_walk_next     ; not passed -> continue
.Lps_wp_passed:
; score += g_w.passed_pawn_bonus[row]   (16-bit int at base + row*2)
	lda	PSROW
	asl	a
	tax
	lda	g_w + W_PASSED_PAWN_BONUS, x
	pha
	lda	g_w + W_PASSED_PAWN_BONUS + 1, x
	tax
	pla                       ; A=lo, X=hi
	jsr	.Ls_score_addAX
; if (white_connected(x,file)) score += g_w.connected_passer
	jsr	.Ls_white_connected
	beq	.Lps_wp_noconn
	lda	g_w + W_CONNECTED_PASSER
	ldx	g_w + W_CONNECTED_PASSER + 1
	jsr	.Ls_score_addAX
.Lps_wp_noconn:
; if (white_protected(x)) score += g_w.protected_passer
	jsr	.Ls_white_protected
	beq	.Lps_wp_noprot
	lda	g_w + W_PROTECTED_PASSER
	ldx	g_w + W_PROTECTED_PASSER + 1
	jsr	.Ls_score_addAX
.Lps_wp_noprot:
; if (white_blockaded(x)) score -= g_w.blockaded_passer
	jsr	.Ls_white_blockaded
	beq	.Lps_wp_noblk
	lda	g_w + W_BLOCKADED_PASSER
	ldx	g_w + W_BLOCKADED_PASSER + 1
	jsr	.Ls_score_subAX
.Lps_wp_noblk:
; if (e.endgame && white_rook_behind(file,row)) score += g_w.rook_behind_passer
	lda	E_BUF + E_ENDGAME
	ora	E_BUF + E_ENDGAME + 1
	beq	.Lps_wp_norb
	jsr	.Ls_white_rook_behind
	beq	.Lps_wp_norb
	lda	g_w + W_ROOK_BEHIND_PASSER
	ldx	g_w + W_ROOK_BEHIND_PASSER + 1
	jsr	.Ls_score_addAX
.Lps_wp_norb:
	jmp	.Lps_walk_next

; ===== BLACK PAWN (eval.c 775-783) =====
.Lps_black_pawn:
	jsr	.Ls_black_passed   ; A=1 if passed
	bne	.Lps_bp_passed
	jmp	.Lps_walk_next     ; not passed -> continue
.Lps_bp_passed:
; score -= g_w.passed_pawn_bonus[7 - row]
	lda	#7
	sec
	sbc	PSROW              ; 7 - row
	asl	a
	tax
	lda	g_w + W_PASSED_PAWN_BONUS, x
	pha
	lda	g_w + W_PASSED_PAWN_BONUS + 1, x
	tax
	pla                       ; A=lo, X=hi
	jsr	.Ls_score_subAX
; if (black_connected(x,file)) score -= g_w.connected_passer
	jsr	.Ls_black_connected
	beq	.Lps_bp_noconn
	lda	g_w + W_CONNECTED_PASSER
	ldx	g_w + W_CONNECTED_PASSER + 1
	jsr	.Ls_score_subAX
.Lps_bp_noconn:
; if (black_protected(x)) score -= g_w.protected_passer
	jsr	.Ls_black_protected
	beq	.Lps_bp_noprot
	lda	g_w + W_PROTECTED_PASSER
	ldx	g_w + W_PROTECTED_PASSER + 1
	jsr	.Ls_score_subAX
.Lps_bp_noprot:
; if (black_blockaded(x)) score += g_w.blockaded_passer
	jsr	.Ls_black_blockaded
	beq	.Lps_bp_noblk
	lda	g_w + W_BLOCKADED_PASSER
	ldx	g_w + W_BLOCKADED_PASSER + 1
	jsr	.Ls_score_addAX
.Lps_bp_noblk:
; if (e.endgame && black_rook_behind(file,row)) score -= g_w.rook_behind_passer
	lda	E_BUF + E_ENDGAME
	ora	E_BUF + E_ENDGAME + 1
	beq	.Lps_bp_norb
	jsr	.Ls_black_rook_behind
	beq	.Lps_bp_norb
	lda	g_w + W_ROOK_BEHIND_PASSER
	ldx	g_w + W_ROOK_BEHIND_PASSER + 1
	jsr	.Ls_score_subAX
.Lps_bp_norb:
	jmp	.Lps_walk_next

; ===== NON-PAWN: rook open/semi-open file (eval.c 752-763) =====
.Lps_not_pawn:
; if (!e.endgame) { ... }  -- middlegame only.
	lda	E_BUF + E_ENDGAME
	ora	E_BUF + E_ENDGAME + 1
	beq	.Lps_np_mid
	jmp	.Lps_walk_next     ; endgame -> skip; continue
.Lps_np_mid:
; rf = x & 7
	lda	PSX
	and	#0x07
	sta	PSFILE             ; rf (reuse PSFILE for the file index)
; if (p == WHITE_ROOK && wpf[rf]==0) score += (bpf[rf] ? semi : open)
	lda	__rc9
	cmp	#WHITE_ROOK
	bne	.Lps_np_chk_black
; wpf[rf] == 0 ?
	lda	PSFILE
	asl	a
	tax
	lda	E_BUF + E_WPF, x
	ora	E_BUF + E_WPF + 1, x
	beq	.Lps_np_w_open     ; wpf[rf]==0 -> apply
	jmp	.Lps_walk_next     ; wpf[rf]!=0 -> nothing; continue
.Lps_np_w_open:
; weight = bpf[rf] ? rook_semi_open_file : rook_open_file
	lda	PSFILE
	asl	a
	tax
	lda	E_BUF + E_BPF, x
	ora	E_BUF + E_BPF + 1, x
	bne	.Lps_np_w_semi     ; bpf[rf]!=0 -> semi-open
	lda	g_w + W_ROOK_OPEN_FILE
	ldx	g_w + W_ROOK_OPEN_FILE + 1
	jsr	.Ls_score_addAX
	jmp	.Lps_walk_next
.Lps_np_w_semi:
	lda	g_w + W_ROOK_SEMI_OPEN_FILE
	ldx	g_w + W_ROOK_SEMI_OPEN_FILE + 1
	jsr	.Ls_score_addAX
	jmp	.Lps_walk_next
.Lps_np_chk_black:
; else if (p == BLACK_ROOK && bpf[rf]==0) score -= (wpf[rf] ? semi : open)
	lda	__rc9
	cmp	#BLACK_ROOK
	beq	.Lps_np_is_brook
	jmp	.Lps_walk_next     ; neither rook -> continue
.Lps_np_is_brook:
; bpf[rf] == 0 ?
	lda	PSFILE
	asl	a
	tax
	lda	E_BUF + E_BPF, x
	ora	E_BUF + E_BPF + 1, x
	beq	.Lps_np_b_open     ; bpf[rf]==0 -> apply
	jmp	.Lps_walk_next     ; bpf[rf]!=0 -> nothing
.Lps_np_b_open:
; weight = wpf[rf] ? rook_semi_open_file : rook_open_file
	lda	PSFILE
	asl	a
	tax
	lda	E_BUF + E_WPF, x
	ora	E_BUF + E_WPF + 1, x
	bne	.Lps_np_b_semi     ; wpf[rf]!=0 -> semi-open
	lda	g_w + W_ROOK_OPEN_FILE
	ldx	g_w + W_ROOK_OPEN_FILE + 1
	jsr	.Ls_score_subAX
	jmp	.Lps_walk_next
.Lps_np_b_semi:
	lda	g_w + W_ROOK_SEMI_OPEN_FILE
	ldx	g_w + W_ROOK_SEMI_OPEN_FILE + 1
	jsr	.Ls_score_subAX
	; fall through to walk_next

; ---- loop increment: x++; if (x & 8) x += 8; while (x < 128) --------------
.Lps_walk_next:
	inc	PSX
	lda	PSX
	and	#0x08
	beq	.Lps_walk_test
	lda	PSX
	clc
	adc	#8
	sta	PSX
.Lps_walk_test:
	lda	PSX
	cmp	#BOARD_SIZE
	bcs	.Lps_walk_done
	jmp	.Lps_walk
.Lps_walk_done:
	rts

; ============================================================================
; pawn_structure helper subroutines (eval.c 614-716). All take state from
; .bss (PSX/PSFILE/PSROW); require __rc2/3 = BPTR. Return A=1/0 (Z set when 0).
; They make NO jsr to C and PRESERVE __rc2/3.
; ============================================================================

; .Ls_white_passed -- white_passed(e, PSFILE, PSROW). eval.c 614-632.
;   r=row; loop{ r--; if r<0 return 1; y=(r<<4)|file;
;     if (b[y]&7)==PAWN_T && !(b[y]&0x80) return 0;   (enemy=black pawn)
;     if file!=0 { yl=y-1; if (b[yl]&7)==PAWN_T && !(b[yl]&0x80) return 0; }
;     if file!=7 { yr=y+1; if (b[yr]&7)==PAWN_T && !(b[yr]&0x80) return 0; } }
;   Scratch: A/X/Y, __rc12 (r as signed-ish 0..7 then below 0), __rc13 (y).
.Ls_white_passed:
	lda	PSROW
	sta	__rc12             ; r = row
.Lwp_loop:
	dec	__rc12             ; r--
	lda	__rc12
	bmi	.Lwp_yes           ; r < 0 -> return 1 (passed)
; y = (r<<4)|file
	asl	a
	asl	a
	asl	a
	asl	a                  ; r<<4
	ora	PSFILE
	sta	__rc13             ; y
; centre file: enemy black pawn at y ?
	tay
	jsr	.Lps_is_black_pawn_y
	bne	.Lwp_no            ; black pawn -> not passed
; if file!=0: yl = y-1
	lda	PSFILE
	beq	.Lwp_skip_left
	ldy	__rc13
	dey                       ; y-1
	jsr	.Lps_is_black_pawn_y
	bne	.Lwp_no
.Lwp_skip_left:
; if file!=7: yr = y+1
	lda	PSFILE
	cmp	#7
	beq	.Lwp_loop          ; file==7 -> skip right, next r
	ldy	__rc13
	iny                       ; y+1
	jsr	.Lps_is_black_pawn_y
	bne	.Lwp_no
	jmp	.Lwp_loop
.Lwp_yes:
	lda	#1
	rts
.Lwp_no:
	lda	#0
	rts

; .Ls_black_passed -- black_passed(e, PSFILE, PSROW). eval.c 634-652.
;   r=row; loop{ r++; if r==8 return 1; y=(r<<4)|file;
;     if (b[y]&7)==PAWN_T && (b[y]&0x80) return 0;   (enemy=white pawn)
;     ... y-1 / y+1 white-pawn neighbours ... }
.Ls_black_passed:
	lda	PSROW
	sta	__rc12             ; r = row
.Lbp_loop:
	inc	__rc12             ; r++
	lda	__rc12
	cmp	#8
	beq	.Lbp_yes           ; r == 8 -> return 1
; y = (r<<4)|file
	asl	a
	asl	a
	asl	a
	asl	a
	ora	PSFILE
	sta	__rc13             ; y
	tay
	jsr	.Lps_is_white_pawn_y
	bne	.Lbp_no
	lda	PSFILE
	beq	.Lbp_skip_left
	ldy	__rc13
	dey
	jsr	.Lps_is_white_pawn_y
	bne	.Lbp_no
.Lbp_skip_left:
	lda	PSFILE
	cmp	#7
	beq	.Lbp_loop
	ldy	__rc13
	iny
	jsr	.Lps_is_white_pawn_y
	bne	.Lbp_no
	jmp	.Lbp_loop
.Lbp_yes:
	lda	#1
	rts
.Lbp_no:
	lda	#0
	rts

; .Lps_is_black_pawn_y -- given Y = index, return A=1 (Z clear) if
;   (b[Y]&7)==PAWN_T && !(b[Y]&0x80), i.e. a BLACK pawn; else A=0 (Z set).
;   NB: the C tests ptype+color separately (NOT ==BLACK_PAWN), so a black pawn
;   byte is exactly 0x01 here, but a value like (PAWN_T without color, any high
;   bits) -> only 0x01 qualifies in practice; replicate the EXACT C test.
;   Requires __rc2/3 = BPTR. Preserves __rc12/13. Uses A.
.Lps_is_black_pawn_y:
	lda	(__rc2),y          ; b[Y]
	pha
	and	#0x07
	cmp	#PT_PAWN
	bne	.Lpbp_no_pull      ; (b&7)!=PAWN_T
	pla                       ; b[Y]
	and	#WHITE_COLOR
	bne	.Lpbp_no           ; (b&0x80)!=0 -> white pawn, not black
	lda	#1
	rts
.Lpbp_no_pull:
	pla
.Lpbp_no:
	lda	#0
	rts

; .Lps_is_white_pawn_y -- A=1 if (b[Y]&7)==PAWN_T && (b[Y]&0x80) (WHITE pawn).
.Lps_is_white_pawn_y:
	lda	(__rc2),y
	pha
	and	#0x07
	cmp	#PT_PAWN
	bne	.Lpwp_no_pull
	pla
	and	#WHITE_COLOR
	beq	.Lpwp_no           ; (b&0x80)==0 -> black pawn, not white
	lda	#1
	rts
.Lpwp_no_pull:
	pla
.Lpwp_no:
	lda	#0
	rts

; .Ls_white_connected -- white_connected(e, sq=PSX, file=PSFILE). eval.c 654-658.
;   if file!=0 && b[sq-1]==WHITE_PAWN return 1;
;   if file!=7 && b[sq+1]==WHITE_PAWN return 1; return 0.
;   sq-1 / sq+1 are raw +-1 on the index, guarded by file. Requires __rc2/3=BPTR.
.Ls_white_connected:
	lda	PSFILE
	beq	.Lwc_skip_left     ; file==0 -> skip left
	ldy	PSX
	dey                       ; sq-1
	lda	(__rc2),y
	cmp	#WHITE_PAWN
	beq	.Lwc_yes
.Lwc_skip_left:
	lda	PSFILE
	cmp	#7
	beq	.Lwc_no            ; file==7 -> skip right
	ldy	PSX
	iny                       ; sq+1
	lda	(__rc2),y
	cmp	#WHITE_PAWN
	beq	.Lwc_yes
.Lwc_no:
	lda	#0
	rts
.Lwc_yes:
	lda	#1
	rts

; .Ls_black_connected -- black_connected. eval.c 660-665. Same shape, BLACK_PAWN.
.Ls_black_connected:
	lda	PSFILE
	beq	.Lbc_skip_left
	ldy	PSX
	dey
	lda	(__rc2),y
	cmp	#BLACK_PAWN
	beq	.Lbc_yes
.Lbc_skip_left:
	lda	PSFILE
	cmp	#7
	beq	.Lbc_no
	ldy	PSX
	iny
	lda	(__rc2),y
	cmp	#BLACK_PAWN
	beq	.Lbc_yes
.Lbc_no:
	lda	#0
	rts
.Lbc_yes:
	lda	#1
	rts

; .Ls_white_protected -- white_protected(e, sq=PSX). eval.c 667-674.
;   a=add8(sq,0x0F); if !(a&0x88) && b[a]==WHITE_PAWN return 1;
;   a=add8(sq,0x11); if !(a&0x88) && b[a]==WHITE_PAWN return 1; return 0.
;   Requires __rc2/3 = BPTR.
.Ls_white_protected:
	lda	PSX
	clc
	adc	#0x0F
	tay
	and	#OFFBOARD_MASK
	bne	.Lwpr_try11        ; offboard -> try second
	lda	(__rc2),y
	cmp	#WHITE_PAWN
	beq	.Lwpr_yes
.Lwpr_try11:
	lda	PSX
	clc
	adc	#0x11
	tay
	and	#OFFBOARD_MASK
	bne	.Lwpr_no
	lda	(__rc2),y
	cmp	#WHITE_PAWN
	beq	.Lwpr_yes
.Lwpr_no:
	lda	#0
	rts
.Lwpr_yes:
	lda	#1
	rts

; .Ls_black_protected -- black_protected(e, sq=PSX). eval.c 675-682.
;   a=add8(sq,-0x0F)=add8(sq,0xF1); ... ; a=add8(sq,-0x11)=add8(sq,0xEF); BLACK_PAWN.
.Ls_black_protected:
	lda	PSX
	clc
	adc	#0xF1              ; add8(sq,-0x0F): sq+0xF1 (mod 256)
	tay
	and	#OFFBOARD_MASK
	bne	.Lbpr_try11
	lda	(__rc2),y
	cmp	#BLACK_PAWN
	beq	.Lbpr_yes
.Lbpr_try11:
	lda	PSX
	clc
	adc	#0xEF              ; add8(sq,-0x11): sq+0xEF (mod 256)
	tay
	and	#OFFBOARD_MASK
	bne	.Lbpr_no
	lda	(__rc2),y
	cmp	#BLACK_PAWN
	beq	.Lbpr_yes
.Lbpr_no:
	lda	#0
	rts
.Lbpr_yes:
	lda	#1
	rts

; .Ls_white_blockaded -- white_blockaded(e, sq=PSX). eval.c 684-688.
;   a=add8(sq,-0x10)=add8(sq,0xF0); if a&0x88 return 0; return b[a]!=EMPTY.
;   Requires __rc2/3 = BPTR.
.Ls_white_blockaded:
	lda	PSX
	clc
	adc	#0xF0              ; add8(sq,-0x10): sq+0xF0 (mod 256)
	tay
	and	#OFFBOARD_MASK
	bne	.Lwbl_no           ; offboard -> 0
	lda	(__rc2),y          ; b[a]
	bne	.Lwbl_yes          ; != EMPTY -> 1
	lda	#0
	rts
.Lwbl_yes:
	lda	#1
	rts
.Lwbl_no:
	lda	#0
	rts

; .Ls_black_blockaded -- black_blockaded(e, sq=PSX). eval.c 689-693.
;   a=add8(sq,0x10); if a&0x88 return 0; return b[a]!=EMPTY.
.Ls_black_blockaded:
	lda	PSX
	clc
	adc	#0x10
	tay
	and	#OFFBOARD_MASK
	bne	.Lbbl_no
	lda	(__rc2),y
	bne	.Lbbl_yes
	lda	#0
	rts
.Lbbl_yes:
	lda	#1
	rts
.Lbbl_no:
	lda	#0
	rts

; .Ls_white_rook_behind -- white_rook_behind(e, PSFILE, PSROW). eval.c 695-705.
;   r=row; loop{ r++; if r==8 return 0; y=(r<<4)|file; if b[y]==WHITE_ROOK ret 1; }
;   Requires __rc2/3 = BPTR. Scratch __rc12 (r).
.Ls_white_rook_behind:
	lda	PSROW
	sta	__rc12
.Lwrb_loop:
	inc	__rc12
	lda	__rc12
	cmp	#8
	beq	.Lwrb_no           ; r==8 -> 0
	asl	a
	asl	a
	asl	a
	asl	a                  ; r<<4
	ora	PSFILE
	tay
	lda	(__rc2),y
	cmp	#WHITE_ROOK
	beq	.Lwrb_yes
	jmp	.Lwrb_loop
.Lwrb_yes:
	lda	#1
	rts
.Lwrb_no:
	lda	#0
	rts

; .Ls_black_rook_behind -- black_rook_behind(e, PSFILE, PSROW). eval.c 706-716.
;   r=row; loop{ r--; if r<0 return 0; y=(r<<4)|file; if b[y]==BLACK_ROOK ret 1; }
.Ls_black_rook_behind:
	lda	PSROW
	sta	__rc12
.Lbrb_loop:
	dec	__rc12
	lda	__rc12
	bmi	.Lbrb_no           ; r<0 -> 0
	asl	a
	asl	a
	asl	a
	asl	a
	ora	PSFILE
	tay
	lda	(__rc2),y
	cmp	#BLACK_ROOK
	beq	.Lbrb_yes
	jmp	.Lbrb_loop
.Lbrb_yes:
	lda	#1
	rts
.Lbrb_no:
	lda	#0
	rts

; ============================================================================
; .Ls_endgame -- endgame(e). eval.c 880-884. INLINE (no jsr to C).
;   e.score += endgame_king_activity(e.wk);
;   e.score -= endgame_king_activity(e.bk);
;   if (e.pawns != 0 && e.nonpawn != 0) endgame_rook_activity(e);
; Reached only when e.endgame != 0 (the tail's else branch). Reads e.wk/e.bk
; (low byte = king index, hi=0). endgame_king_activity returns a 16-bit acc.
; ============================================================================
.Ls_endgame:
; acc_w = endgame_king_activity(e.wk); e.score += acc_w
	lda	E_BUF + E_WK
	jsr	.Ls_eg_king_activity   ; -> A=lo / X=hi
	jsr	.Ls_score_addAX
; acc_b = endgame_king_activity(e.bk); e.score -= acc_b
	lda	E_BUF + E_BK
	jsr	.Ls_eg_king_activity
	jsr	.Ls_score_subAX
; if (e.pawns != 0 && e.nonpawn != 0) endgame_rook_activity()
	lda	E_BUF + E_PAWNS
	ora	E_BUF + E_PAWNS + 1
	beq	.Leg_ret               ; pawns == 0 -> skip
	lda	E_BUF + E_NONPAWN
	ora	E_BUF + E_NONPAWN + 1
	beq	.Leg_ret               ; nonpawn == 0 -> skip
	jmp	.Ls_eg_rook_activity   ; tail-call (rts)
.Leg_ret:
	rts

; ----------------------------------------------------------------------------
; .Ls_eg_king_activity -- endgame_king_activity(ksq). eval.c 847-854.
;   acc=0; file=ksq&7; row=ksq>>4;
;   if (file>=2 && file<6) acc += g_w.endgame_king_activity;
;   if (row>=2 && row<6)   acc += g_w.endgame_king_activity;
;   return acc.  ksq low byte in A on entry (king on-board, hi=0). Returns the
;   16-bit acc in A=lo / X=hi. acc accumulated in __rc8/9.
; ----------------------------------------------------------------------------
.Ls_eg_king_activity:
	sta	__rc10                 ; __rc10 = ksq (low byte)
	lda	#0
	sta	__rc8                  ; acc lo
	sta	__rc9                  ; acc hi
; file = ksq & 7; if (file>=2 && file<6) acc += W
	lda	__rc10
	and	#0x07
	cmp	#2
	bcc	.Leka_chk_row          ; file < 2
	cmp	#6
	bcs	.Leka_chk_row          ; file >= 6
	jsr	.Leka_addW
.Leka_chk_row:
; row = ksq >> 4; if (row>=2 && row<6) acc += W
	lda	__rc10
	lsr	a
	lsr	a
	lsr	a
	lsr	a
	cmp	#2
	bcc	.Leka_done             ; row < 2
	cmp	#6
	bcs	.Leka_done             ; row >= 6
	jsr	.Leka_addW
.Leka_done:
	lda	__rc8                  ; A = acc lo
	ldx	__rc9                  ; X = acc hi
	rts
; acc (__rc8/9) += g_w.endgame_king_activity (16-bit). Preserves __rc10.
.Leka_addW:
	clc
	lda	__rc8
	adc	g_w + W_ENDGAME_KING_ACTIVITY
	sta	__rc8
	lda	__rc9
	adc	g_w + W_ENDGAME_KING_ACTIVITY + 1
	sta	__rc9
	rts

; ----------------------------------------------------------------------------
; .Ls_eg_rook_activity -- endgame_rook_activity(e). eval.c 856-877.
;   0x88 walk; per square p=b[x]:
;     WHITE_ROOK: f=x&7; if wpf[f]!=0 continue; score += endgame_rook_open_file;
;        dist=|(e.bk&7)-f|; if dist<2 score += endgame_rook_king_cutoff;
;     BLACK_ROOK: f=x&7; if bpf[f]!=0 continue; score -= endgame_rook_open_file;
;        dist=|(e.wk&7)-f|; if dist<2 score -= endgame_rook_king_cutoff;
;   Requires __rc2/3 = BPTR. Scratch A/X/Y, __rc8 (piece), PSX (walk idx),
;   PSFILE (f). Reuses .bss PSX/PSFILE (dead post-pawn_structure).
; ----------------------------------------------------------------------------
.Ls_eg_rook_activity:
	lda	BPTR
	sta	__rc2
	lda	BPTR+1
	sta	__rc3
	lda	#0
	sta	PSX
.Lera_walk:
	ldy	PSX
	lda	(__rc2),y              ; p = b[x]
	cmp	#WHITE_ROOK
	beq	.Lera_wrook
	cmp	#BLACK_ROOK
	beq	.Lera_brook
	jmp	.Lera_next
; ---- WHITE_ROOK ----
.Lera_wrook:
	lda	PSX
	and	#0x07
	sta	PSFILE                 ; f
	asl	a
	tax                           ; x = f*2
	lda	E_BUF + E_WPF, x
	ora	E_BUF + E_WPF + 1, x
	beq	.Lera_w_open           ; wpf[f]==0 -> open file
	jmp	.Lera_next             ; wpf[f]!=0 -> continue
.Lera_w_open:
; score += endgame_rook_open_file
	lda	g_w + W_ENDGAME_ROOK_OPEN_FILE
	ldx	g_w + W_ENDGAME_ROOK_OPEN_FILE + 1
	jsr	.Ls_score_addAX
; dist = |(e.bk & 7) - f|
	lda	E_BUF + E_BK
	and	#0x07
	sec
	sbc	PSFILE                 ; (bk&7) - f, signed (-7..7) in A
	bpl	.Lera_w_pos
	eor	#0xFF
	clc
	adc	#1                     ; A = -A (abs)
.Lera_w_pos:
; if (dist < 2) score += endgame_rook_king_cutoff
	cmp	#2
	bcs	.Lera_next             ; dist >= 2 -> no cutoff
	lda	g_w + W_ENDGAME_ROOK_KING_CUTOFF
	ldx	g_w + W_ENDGAME_ROOK_KING_CUTOFF + 1
	jsr	.Ls_score_addAX
	jmp	.Lera_next
; ---- BLACK_ROOK ----
.Lera_brook:
	lda	PSX
	and	#0x07
	sta	PSFILE
	asl	a
	tax
	lda	E_BUF + E_BPF, x
	ora	E_BUF + E_BPF + 1, x
	beq	.Lera_b_open           ; bpf[f]==0 -> open file
	jmp	.Lera_next
.Lera_b_open:
; score -= endgame_rook_open_file
	lda	g_w + W_ENDGAME_ROOK_OPEN_FILE
	ldx	g_w + W_ENDGAME_ROOK_OPEN_FILE + 1
	jsr	.Ls_score_subAX
; dist = |(e.wk & 7) - f|
	lda	E_BUF + E_WK
	and	#0x07
	sec
	sbc	PSFILE
	bpl	.Lera_b_pos
	eor	#0xFF
	clc
	adc	#1
.Lera_b_pos:
	cmp	#2
	bcs	.Lera_next             ; dist >= 2 -> no cutoff
	lda	g_w + W_ENDGAME_ROOK_KING_CUTOFF
	ldx	g_w + W_ENDGAME_ROOK_KING_CUTOFF + 1
	jsr	.Ls_score_subAX
; ---- loop increment: x++; if (x & 8) x += 8; while (x < 128) ----
.Lera_next:
	inc	PSX
	lda	PSX
	and	#0x08
	beq	.Lera_test
	lda	PSX
	clc
	adc	#8
	sta	PSX
.Lera_test:
	lda	PSX
	cmp	#BOARD_SIZE
	bcs	.Lera_done
	jmp	.Lera_walk
.Lera_done:
	rts

; ============================================================================
; TERM GROUP (d): king_pins + king_safety (eval.c 790-1035). Fully INLINE.
;   king_pins -> pins_from_king (pin ray-scan, 16-bit score +/-).
;   king_safety -> single_king_safety (SIGNED-BYTE accumulator) -> byte_x10.
; All take state from .bss; require __rc2/3 = BPTR for board reads. They reuse
; .Ls_pawn_attacked / .Ls_knight_attacked (which read WALKX/CURCOL/CURPT and
; need __rc2/3 = BPTR) by staging args into WALKX/CURCOL/CURPT (all dead now,
; post-walk). e.score is the live uint16 accumulator at E_BUF+E_SCORE.
; ============================================================================

; ----------------------------------------------------------------------------
; .Ls_king_pins -- king_pins(e). eval.c 839-842.
;   pins_from_king(e, e.wk, WHITE_COLOR); pins_from_king(e, e.bk, 0).
;   e.wk / e.bk are 16-bit ints but king squares are 0..119 so the low byte is
;   the index (the C add8/board-index path only uses the low byte). Set KP_KSQ /
;   KP_KCOL and call .Ls_pins_from_king.
; ----------------------------------------------------------------------------
.Ls_king_pins:
; pins_from_king(e, e.wk, WHITE_COLOR)
	lda	E_BUF + E_WK
	sta	KP_KSQ
	lda	#WHITE_COLOR
	sta	KP_KCOL
	jsr	.Ls_pins_from_king
; pins_from_king(e, e.bk, 0)
	lda	E_BUF + E_BK
	sta	KP_KSQ
	lda	#0
	sta	KP_KCOL
	jmp	.Ls_pins_from_king   ; tail-call (rts)

; ----------------------------------------------------------------------------
; .Ls_pins_from_king -- pins_from_king(e, KP_KSQ, KP_KCOL). eval.c 797-837.
;   for d=0..7: delta=ALLDIR_OFFS[d]; ray=king_sq; candidate_type=0; candidate_sq=0;
;     ray-step loop (add8, offboard break, EMPTY continue):
;       first occupied (candidate_type==0): must be friendly non-king ->
;         set candidate_sq, candidate_type=t; t==KING_T -> break (no candidate);
;         (p&0x80)!=king_color -> break.
;       second occupied: must be enemy aligned slider:
;         (p&0x80)==king_color -> break; t=p&7;
;         if t!=QUEEN_T && PIN_SLIDER_TYPES[d]!=t -> break;
;         pen=ET_PINNED[candidate_type]; if pen==0 break;
;         king_color ? score-=pen : score+=pen;
;         pinned_attack_pressure(king_color, candidate_type, candidate_sq);
;         break.
;   Requires __rc2/3 = BPTR. Uses A/X/Y, __rc8 (delta), KP_* scratch.
; ----------------------------------------------------------------------------
.Ls_pins_from_king:
; __rc2/3 = BPTR (board base for (zp),Y reads).
	lda	BPTR
	sta	__rc2
	lda	BPTR+1
	sta	__rc3
	lda	#0
	sta	KP_D                 ; d = 0
.Lpfk_dir:
; ray = king_sq; candidate_type = 0; candidate_sq = 0 (csq need not be init: only
; read after candidate_type set, but match C: leave it -- we always set it before
; the second-occupied branch reads it).
	lda	KP_KSQ
	sta	KP_RAY
	lda	#0
	sta	KP_CTYPE
.Lpfk_step:
; ray = add8(ray, delta);  delta = ALLDIR_OFFS[d] (re-read each step: cheap, and
; survives any clobber from pinned_attack_pressure on the apply path).
	ldx	KP_D
	lda	ALLDIR_OFFS, x
	clc
	adc	KP_RAY
	sta	KP_RAY               ; ray (low byte)
; if (ray & 0x88) break;
	and	#OFFBOARD_MASK
	beq	.Lpfk_onboard
	jmp	.Lpfk_dir_done       ; offboard -> break this direction
.Lpfk_onboard:
; piece = b[ray]; if (piece == EMPTY) continue;
	ldy	KP_RAY
	lda	(__rc2),y            ; A = piece
	bne	.Lpfk_occ
	jmp	.Lpfk_step           ; EMPTY -> continue ray
.Lpfk_occ:
; A = piece. branch on candidate_type==0 (first occupied) vs else (second).
	sta	__rc8                ; __rc8 = piece (preserve across compares)
	lda	KP_CTYPE
	bne	.Lpfk_second         ; candidate_type != 0 -> second-occupied branch
; ---- first occupied: must be friendly non-king ----
; if ((piece & WHITE_COLOR) != king_color) break;
	lda	__rc8
	and	#WHITE_COLOR
	cmp	KP_KCOL
	beq	.Lpfk_first_friendly
	jmp	.Lpfk_dir_done       ; enemy first -> break (no pin this direction)
.Lpfk_first_friendly:
; candidate_sq = ray; t = piece & 7; if (t == KING_T) break; candidate_type = t; continue;
	lda	KP_RAY
	sta	KP_CSQ
	lda	__rc8
	and	#0x07
	cmp	#PT_KING
	bne	.Lpfk_first_setcand
	jmp	.Lpfk_dir_done       ; first occupied is the king itself -> break
.Lpfk_first_setcand:
	sta	KP_CTYPE             ; candidate_type = t (1..5)
	jmp	.Lpfk_step           ; continue ray scan
; ---- second occupied: enemy aligned slider? ----
.Lpfk_second:
; if ((piece & WHITE_COLOR) == king_color) break;
	lda	__rc8
	and	#WHITE_COLOR
	cmp	KP_KCOL
	bne	.Lpfk_second_enemy
	jmp	.Lpfk_dir_done       ; friendly blocker -> break
.Lpfk_second_enemy:
; t = piece & 7;
	lda	__rc8
	and	#0x07
	tax                          ; X = t (preserve t for slider-type compare)
	cpx	#PT_QUEEN
	beq	.Lpfk_aligned        ; t == QUEEN_T -> always aligned
; if (PIN_SLIDER_TYPES[d] != t) break;
	ldy	KP_D
	lda	PINSLIDE, y
	stx	__rc9                ; __rc9 = t
	cmp	__rc9
	beq	.Lpfk_aligned
	jmp	.Lpfk_dir_done       ; wrong slider type for this direction -> break
.Lpfk_aligned:
; pen = ET_PINNED[candidate_type] (16-bit); if (pen == 0) break;
	lda	KP_CTYPE
	asl	a                    ; candidate_type * 2
	tay
	lda	ET_PINNED, y         ; pen lo
	sta	__rc10
	iny
	lda	ET_PINNED, y         ; pen hi
	sta	__rc11
	lda	__rc10
	ora	__rc11
	bne	.Lpfk_pen_nz
	jmp	.Lpfk_dir_done       ; pen == 0 -> break
.Lpfk_pen_nz:
; if (king_color) e.score -= pen; else e.score += pen.
	lda	__rc10               ; A = pen lo
	ldx	__rc11               ; X = pen hi
	ldy	KP_KCOL
	beq	.Lpfk_score_add      ; king_color == 0 -> add
	jsr	.Ls_score_subAX      ; king_color != 0 -> subtract
	jmp	.Lpfk_pressure
.Lpfk_score_add:
	jsr	.Ls_score_addAX
.Lpfk_pressure:
; pinned_attack_pressure(e, king_color, candidate_type, candidate_sq).
	jsr	.Ls_pinned_attack_pressure
	jmp	.Lpfk_dir_done       ; break after applying

.Lpfk_dir_done:
; d++; while (d < 8)
	inc	KP_D
	lda	KP_D
	cmp	#8
	bcs	.Lpfk_ret
	jmp	.Lpfk_dir
.Lpfk_ret:
	rts

; ----------------------------------------------------------------------------
; .Ls_pinned_attack_pressure -- pinned_attack_pressure(e, pinned_color=KP_KCOL,
;   ptype=KP_CTYPE, sq=KP_CSQ). eval.c 790-795.
;   if (is_pawn_attacked(sq,pinned_color,ptype) || is_knight_attacked(sq,pinned_color)):
;       if (pinned_color) e.score -= g_w.pinned_attacked; else += .
;   REUSES .Ls_pawn_attacked / .Ls_knight_attacked, which read sq from WALKX,
;   color from CURCOL, ptype from CURPT, and need __rc2/3 = BPTR. We stage those
;   .bss slots (all dead post-walk) and restore __rc2/3 = BPTR (the score helpers
;   above don't touch it, but be defensive).
;   Requires __rc2/3 = BPTR on entry (caller keeps it). Uses A/X/Y, __rc8/9.
; ----------------------------------------------------------------------------
.Ls_pinned_attack_pressure:
; stage probe args: WALKX=sq, CURCOL=pinned_color, CURPT=ptype.
	lda	KP_CSQ
	sta	WALKX
	lda	KP_KCOL
	sta	CURCOL
	lda	KP_CTYPE
	sta	CURPT
; __rc2/3 = BPTR (probes do (zp),Y board reads).
	lda	BPTR
	sta	__rc2
	lda	BPTR+1
	sta	__rc3
; if (is_pawn_attacked(...)) -> apply
	jsr	.Ls_pawn_attacked
	bne	.Lpap_apply
; else if (is_knight_attacked(...)) -> apply  (note: re-set __rc2/3 unchanged;
; .Ls_pawn_attacked preserves __rc2/3, so still BPTR.)
	jsr	.Ls_knight_attacked
	bne	.Lpap_apply
	rts                          ; neither -> nothing
.Lpap_apply:
; if (pinned_color) e.score -= g_w.pinned_attacked; else += .
	lda	g_w + W_PINNED_ATTACKED
	ldx	g_w + W_PINNED_ATTACKED + 1
	ldy	KP_KCOL              ; pinned_color (== king_color)
	beq	.Lpap_add            ; pinned_color == 0 -> add
	jmp	.Ls_score_subAX      ; pinned_color != 0 -> subtract (tail rts)
.Lpap_add:
	jmp	.Ls_score_addAX      ; tail-call (rts)

; ----------------------------------------------------------------------------
; SIGNED-BYTE accumulator helpers for king_safety. KS_S is a RAW BYTE holding
; the two's-complement of the signed accumulator s. eval.c add8s/sub8s (384-391)
; compute r=(s+/-v)&0xFF then re-range to [-128,127]; the BYTE REPRESENTATION of
; that re-ranged value is exactly ((s +/- v) & 0xFF), and because mod-256 add/sub
; only depends on the low byte of v, we add/subtract just the LOW byte of the
; (16-bit) weight. Bit-exact. A holds v_low on entry; clobbers A (and __rc8 sub).
; ----------------------------------------------------------------------------
.Ls_s_add:
	clc
	adc	KS_S
	sta	KS_S
	rts
.Ls_s_sub:
	sta	__rc8                ; v_low
	lda	KS_S
	sec
	sbc	__rc8
	sta	KS_S
	rts

; ----------------------------------------------------------------------------
; .Ls_byte_x10 -- byte_x10(KS_S). eval.c 392.
;   x = (signed) KS_S sign-extended to 16-bit; result = x*10 = (x<<1)+(x<<3),
;   16-bit two's-complement (wraps mod 2^16). Returns A=lo, X=hi.
;   Scratch: __rc8/9 (x16 / t2), __rc10/11 (t8). Uses A/X/Y.
; ----------------------------------------------------------------------------
.Ls_byte_x10:
; x16 -> __rc8 (lo) / __rc9 (hi = sign extension).
; CRITICAL: branch on the N flag from `lda KS_S` BEFORE any flag-clobbering
; instruction. `sta` preserves flags but `ldx #imm` sets N from the immediate,
; so we must take the sign branch immediately after the load.
	lda	KS_S
	sta	__rc8
	bpl	.Lbx_pos             ; KS_S bit7 clear -> non-negative -> hi = 0
	lda	#0xFF
	sta	__rc9                ; negative -> hi = 0xFF
	jmp	.Lbx_have_hi
.Lbx_pos:
	lda	#0
	sta	__rc9                ; hi = 0
.Lbx_have_hi:
; t8 = x16 << 3 -> __rc10/11
	lda	__rc8
	sta	__rc10
	lda	__rc9
	sta	__rc11
	asl	__rc10
	rol	__rc11               ; x2
	asl	__rc10
	rol	__rc11               ; x4
	asl	__rc10
	rol	__rc11               ; x8
; t2 = x16 << 1 -> __rc8/9 (in place)
	asl	__rc8
	rol	__rc9                ; x2
; result = t2 + t8 -> A(lo)/X(hi)
	clc
	lda	__rc8
	adc	__rc10
	tay                          ; lo stashed in Y
	lda	__rc9
	adc	__rc11
	tax                          ; X = hi
	tya                          ; A = lo
	rts

; ----------------------------------------------------------------------------
; .Ls_king_safety -- king_safety(e). eval.c 1029-1035.
;   wb = single_king_safety(e.wk); e.score += byte_x10(wb);
;   bb = single_king_safety(e.bk); e.score -= byte_x10(bb).
; ----------------------------------------------------------------------------
.Ls_king_safety:
; wb = single_king_safety(e.wk)
	lda	E_BUF + E_WK
	sta	KS_KSQ
	jsr	.Ls_single_king_safety   ; KS_S = wb (signed byte)
	jsr	.Ls_byte_x10             ; A/X = byte_x10(wb)
	jsr	.Ls_score_addAX          ; e.score += byte_x10(wb)
; bb = single_king_safety(e.bk)
	lda	E_BUF + E_BK
	sta	KS_KSQ
	jsr	.Ls_single_king_safety   ; KS_S = bb
	jsr	.Ls_byte_x10
	jmp	.Ls_score_subAX          ; e.score -= byte_x10(bb) (tail rts)

; ----------------------------------------------------------------------------
; .Ls_single_king_safety -- single_king_safety(e, KS_KSQ). eval.c 957-1027.
;   Returns the signed-byte accumulator in KS_S. is_white = (KS_KSQ == e.wk).
;   Requires __rc2/3 = BPTR (set at entry; sub-helpers preserve / re-set it).
; ----------------------------------------------------------------------------
.Ls_single_king_safety:
; __rc2/3 = BPTR for board reads.
	lda	BPTR
	sta	__rc2
	lda	BPTR+1
	sta	__rc3
; file = ksq & 7; row = ksq >> 4; s = 0.
	lda	KS_KSQ
	and	#0x07
	sta	KS_FILE
	lda	KS_KSQ
	lsr	a
	lsr	a
	lsr	a
	lsr	a
	sta	KS_ROW
	lda	#0
	sta	KS_S
; is_white = (KS_KSQ == e.wk low byte). Kings are on-board (0..119, hi=0).
	lda	KS_KSQ
	cmp	E_BUF + E_WK
	beq	.Lsks_white
	jmp	.Lsks_black

; ===== WHITE KING (eval.c 965-994) =====
.Lsks_white:
; castled = (row == 7 && (file == 6 || file == 2))
	lda	KS_ROW
	cmp	#7
	bne	.Lsks_w_notcastled
	lda	KS_FILE
	cmp	#6
	beq	.Lsks_w_castled
	cmp	#2
	beq	.Lsks_w_castled
.Lsks_w_notcastled:
; not castled: if (file==3 || file==4) s = sub8s(s, king_center)
	lda	KS_FILE
	cmp	#3
	beq	.Lsks_w_center
	cmp	#4
	beq	.Lsks_w_center
	jmp	.Lsks_w_march
.Lsks_w_center:
	lda	g_w + W_KING_CENTER
	jsr	.Ls_s_sub
	jmp	.Lsks_w_march
.Lsks_w_castled:
; s = add8s(s, castled)
	lda	g_w + W_CASTLED
	jsr	.Ls_s_add
; shield idxs: file==6 -> {0x65,0x66,0x67}, else -> {0x60,0x61,0x62}
	lda	KS_FILE
	cmp	#6
	bne	.Lsks_w_qshield
; kingside f2,g2,h2
	lda	#0x65
	jsr	.Lsks_w_shield1
	lda	#0x66
	jsr	.Lsks_w_shield1
	lda	#0x67
	jsr	.Lsks_w_shield1
	jmp	.Lsks_w_march
.Lsks_w_qshield:
; queenside a2,b2,c2
	lda	#0x60
	jsr	.Lsks_w_shield1
	lda	#0x61
	jsr	.Lsks_w_shield1
	lda	#0x62
	jsr	.Lsks_w_shield1
.Lsks_w_march:
; if (row < 6): advanced = 6-row; pen = ((advanced<<3)+king_march_base)&0xFF;
;   s = sub8s(s, pen)
	lda	KS_ROW
	cmp	#6
	bcs	.Lsks_w_filex        ; row >= 6 -> no march
; advanced = 6 - row
	lda	#6
	sec
	sbc	KS_ROW               ; A = advanced (1..6)
	asl	a
	asl	a
	asl	a                    ; advanced << 3 (fits a byte: max 6<<3=48)
	clc
	adc	g_w + W_KING_MARCH_BASE  ; + king_march_base (low byte); & 0xFF implicit
	jsr	.Ls_s_sub            ; s = sub8s(s, pen)
.Lsks_w_filex:
; s = white_file_exposure(s, file)
	lda	#0                   ; 0 -> white exposure tables (sub on wpf/bpf)
	jsr	.Ls_file_exposure
; s = king_zone_pressure(s, ksq, attacker_color=0)  [black attackers]
	lda	KS_KSQ
	sta	KS_KZK
	lda	#0
	sta	KS_ACOL
	jsr	.Ls_king_zone_pressure
	lda	KS_S
	rts

; .Lsks_w_shield1 -- one white shield-pawn test at idx in A.
;   if ((b[idx]&7)==PAWN_T && (b[idx]&0x80)) s = add8s(s, pawn_shield).
;   Requires __rc2/3 = BPTR. Uses A/Y, __rc8 (via .Ls_s_add).
.Lsks_w_shield1:
	tay
	lda	(__rc2),y            ; b[idx]
	pha
	and	#0x07
	cmp	#PT_PAWN
	bne	.Lsks_w_sh_no
	pla
	and	#WHITE_COLOR
	beq	.Lsks_w_sh_no2       ; (b&0x80)==0 -> not white pawn
	lda	g_w + W_PAWN_SHIELD
	jmp	.Ls_s_add            ; s = add8s(s, pawn_shield) (tail rts)
.Lsks_w_sh_no:
	pla
.Lsks_w_sh_no2:
	rts

; ===== BLACK KING (eval.c 995-1024) =====
.Lsks_black:
; castled = (row == 0 && (file == 6 || file == 2))
	lda	KS_ROW
	cmp	#0
	bne	.Lsks_b_notcastled
	lda	KS_FILE
	cmp	#6
	beq	.Lsks_b_castled
	cmp	#2
	beq	.Lsks_b_castled
.Lsks_b_notcastled:
	lda	KS_FILE
	cmp	#3
	beq	.Lsks_b_center
	cmp	#4
	beq	.Lsks_b_center
	jmp	.Lsks_b_march
.Lsks_b_center:
	lda	g_w + W_KING_CENTER
	jsr	.Ls_s_sub
	jmp	.Lsks_b_march
.Lsks_b_castled:
	lda	g_w + W_CASTLED
	jsr	.Ls_s_add
	lda	KS_FILE
	cmp	#6
	bne	.Lsks_b_qshield
; kingside f7,g7,h7 = 0x15,0x16,0x17
	lda	#0x15
	jsr	.Lsks_b_shield1
	lda	#0x16
	jsr	.Lsks_b_shield1
	lda	#0x17
	jsr	.Lsks_b_shield1
	jmp	.Lsks_b_march
.Lsks_b_qshield:
; queenside a7,b7,c7 = 0x10,0x11,0x12
	lda	#0x10
	jsr	.Lsks_b_shield1
	lda	#0x11
	jsr	.Lsks_b_shield1
	lda	#0x12
	jsr	.Lsks_b_shield1
.Lsks_b_march:
; if (row >= 2): advanced = row-1; pen = ((advanced<<3)+king_march_base)&0xFF;
;   s = sub8s(s, pen)
	lda	KS_ROW
	cmp	#2
	bcc	.Lsks_b_filex        ; row < 2 -> no march
	lda	KS_ROW
	sec
	sbc	#1                   ; advanced = row - 1 (1..6)
	asl	a
	asl	a
	asl	a                    ; advanced << 3
	clc
	adc	g_w + W_KING_MARCH_BASE
	jsr	.Ls_s_sub
.Lsks_b_filex:
; s = black_file_exposure(s, file)
	lda	#1                   ; 1 -> black exposure tables
	jsr	.Ls_file_exposure
; s = king_zone_pressure(s, ksq, attacker_color=WHITE_COLOR)  [white attackers]
	lda	KS_KSQ
	sta	KS_KZK
	lda	#WHITE_COLOR
	sta	KS_ACOL
	jsr	.Ls_king_zone_pressure
	lda	KS_S
	rts

; .Lsks_b_shield1 -- one black shield-pawn test at idx in A.
;   if ((b[idx]&7)==PAWN_T && !(b[idx]&0x80)) s = add8s(s, pawn_shield).
.Lsks_b_shield1:
	tay
	lda	(__rc2),y
	pha
	and	#0x07
	cmp	#PT_PAWN
	bne	.Lsks_b_sh_no
	pla
	and	#WHITE_COLOR
	bne	.Lsks_b_sh_no2       ; (b&0x80)!=0 -> white pawn, not black
	lda	g_w + W_PAWN_SHIELD
	jmp	.Ls_s_add            ; tail rts
.Lsks_b_sh_no:
	pla
.Lsks_b_sh_no2:
	rts

; ----------------------------------------------------------------------------
; .Ls_file_exposure -- white/black_file_exposure(e, s, file=KS_FILE). eval.c
;   900-913. A on entry: 0 = white tables (penalize_white_file), nonzero = black.
;   if (e.pawns==0) return; if file!=0 pen(file-1); pen(file); if file!=7 pen(file+1).
;   Stores the white/black flag in __rc12 (survives the penalize calls).
;   Operates on KS_S. Requires __rc2/3 = BPTR (not needed for reads here -- only
;   wpf/bpf absolute -- but kept consistent). Uses A/X/Y, EXF, __rc12.
; ----------------------------------------------------------------------------
.Ls_file_exposure:
	sta	__rc12               ; __rc12 = 0 (white) / !=0 (black)
; if (e.pawns == 0) return
	lda	E_BUF + E_PAWNS
	ora	E_BUF + E_PAWNS + 1
	bne	.Lfx_havepawns
	rts
.Lfx_havepawns:
; if (file != 0) penalize(file-1)
	lda	KS_FILE
	beq	.Lfx_center
	sec
	sbc	#1
	sta	EXF
	jsr	.Ls_penalize_file
.Lfx_center:
; penalize(file)
	lda	KS_FILE
	sta	EXF
	jsr	.Ls_penalize_file
; if (file != 7) penalize(file+1)
	lda	KS_FILE
	cmp	#7
	beq	.Lfx_done
	clc
	adc	#1
	sta	EXF
	jsr	.Ls_penalize_file
.Lfx_done:
	rts

; .Ls_penalize_file -- penalize_white_file / penalize_black_file (eval.c 889-898)
;   for file EXF, white/black per __rc12. Operates on KS_S.
;   white: if wpf[f]!=0 return; if bpf[f]!=0 sub(semi); else sub(open).
;   black: if bpf[f]!=0 return; if wpf[f]!=0 sub(semi); else sub(open).
;   "own pawns on file -> no penalty; enemy-only -> semi-open; empty -> open."
;   Uses A/X/Y. Reads wpf/bpf (absolute). EXF = f, __rc12 = side flag.
.Ls_penalize_file:
	lda	EXF
	asl	a
	tax                          ; X = f*2 (int array index)
	lda	__rc12
	bne	.Lpf_black_side
; ---- white: own = wpf, enemy = bpf ----
	lda	E_BUF + E_WPF, x
	ora	E_BUF + E_WPF + 1, x
	beq	.Lpf_w_noown         ; wpf[f] == 0 -> no own pawn -> penalize
	rts                          ; wpf[f] != 0 -> return s unchanged
.Lpf_w_noown:
	lda	E_BUF + E_BPF, x
	ora	E_BUF + E_BPF + 1, x
	bne	.Lpf_w_semi          ; bpf[f] != 0 -> semi-open
	lda	g_w + W_OPEN_FILE_PENALTY
	jmp	.Ls_s_sub            ; sub8s(s, open) (tail rts)
.Lpf_w_semi:
	lda	g_w + W_SEMI_OPEN_FILE_PENALTY
	jmp	.Ls_s_sub
.Lpf_black_side:
; ---- black: own = bpf, enemy = wpf ----
	lda	E_BUF + E_BPF, x
	ora	E_BUF + E_BPF + 1, x
	beq	.Lpf_b_noown
	rts
.Lpf_b_noown:
	lda	E_BUF + E_WPF, x
	ora	E_BUF + E_WPF + 1, x
	bne	.Lpf_b_semi
	lda	g_w + W_OPEN_FILE_PENALTY
	jmp	.Ls_s_sub
.Lpf_b_semi:
	lda	g_w + W_SEMI_OPEN_FILE_PENALTY
	jmp	.Ls_s_sub

; ----------------------------------------------------------------------------
; .Ls_king_zone_pressure -- king_zone_pressure(e, s, KS_KZK, KS_ACOL). eval.c
;   915-955. Operates on KS_S. Requires __rc2/3 = BPTR.
;   8 slider rays: per ray scan; first non-empty: if (p&0x80)!=attacker_color
;     break; t=p&7; QUEEN -> sub(zone),break; dirs {1,3,4,6}: ROOK -> sub,break;
;     else BISHOP -> sub,break.
;   8 knight offsets: dest on-board, non-empty, attacker color, t==KNIGHT_T ->
;     sub(zone).  Each sub subtracts g_w.king_zone_attack (low byte).
;   Uses A/X/Y, KS_D (dir idx), KS_RAY (ray), KS_I (knight idx), __rc8 (via sub).
; ----------------------------------------------------------------------------
.Ls_king_zone_pressure:
	lda	#0
	sta	KS_D
.Lkzp_dir:
; ray = king_sq
	lda	KS_KZK
	sta	KS_RAY
.Lkzp_step:
; ray = add8(ray, ALLDIR_OFFS[d])
	ldx	KS_D
	lda	ALLDIR_OFFS, x
	clc
	adc	KS_RAY
	sta	KS_RAY
; if (ray & 0x88) break
	and	#OFFBOARD_MASK
	bne	.Lkzp_dir_done
; piece = b[ray]; if EMPTY continue
	ldy	KS_RAY
	lda	(__rc2),y
	bne	.Lkzp_occ
	jmp	.Lkzp_step
.Lkzp_occ:
	sta	__rc8                ; piece
; if ((piece & 0x80) != attacker_color) break
	and	#WHITE_COLOR
	cmp	KS_ACOL
	beq	.Lkzp_samecol
	jmp	.Lkzp_dir_done       ; not attacker color -> break
.Lkzp_samecol:
; t = piece & 7
	lda	__rc8
	and	#0x07
	tax                          ; X = t
	cpx	#PT_QUEEN
	bne	.Lkzp_notqueen
; QUEEN -> sub(zone); break
	lda	g_w + W_KING_ZONE_ATTACK
	jsr	.Ls_s_sub
	jmp	.Lkzp_dir_done
.Lkzp_notqueen:
; orthogonal directions: d == 1,3,4,6 ?
	lda	KS_D
	cmp	#1
	beq	.Lkzp_ortho
	cmp	#3
	beq	.Lkzp_ortho
	cmp	#4
	beq	.Lkzp_ortho
	cmp	#6
	beq	.Lkzp_ortho
; diagonal direction: if (t == BISHOP_T) sub; break
	cpx	#PT_BISHOP
	bne	.Lkzp_dir_done
	lda	g_w + W_KING_ZONE_ATTACK
	jsr	.Ls_s_sub
	jmp	.Lkzp_dir_done
.Lkzp_ortho:
; if (t == ROOK_T) sub; break
	cpx	#PT_ROOK
	bne	.Lkzp_dir_done
	lda	g_w + W_KING_ZONE_ATTACK
	jsr	.Ls_s_sub
.Lkzp_dir_done:
	inc	KS_D
	lda	KS_D
	cmp	#8
	bcs	.Lkzp_knights
	jmp	.Lkzp_dir
.Lkzp_knights:
; knight attackers: for i=0..7
	lda	#0
	sta	KS_I
.Lkzp_kloop:
	ldx	KS_I
	lda	KS_KZK
	clc
	adc	KNIGHT_OFFS, x       ; dest = add8(king_sq, KNIGHT_OFFSETS[i])
	tay
	and	#OFFBOARD_MASK
	bne	.Lkzp_knext          ; offboard -> continue
	lda	(__rc2),y            ; piece = b[dest]
	beq	.Lkzp_knext          ; EMPTY -> continue
	sta	__rc8
	and	#WHITE_COLOR
	cmp	KS_ACOL
	bne	.Lkzp_knext          ; not attacker color -> continue
	lda	__rc8
	and	#0x07
	cmp	#PT_KNIGHT
	bne	.Lkzp_knext          ; not a knight -> continue
	lda	g_w + W_KING_ZONE_ATTACK
	jsr	.Ls_s_sub
.Lkzp_knext:
	inc	KS_I
	lda	KS_I
	cmp	#8
	bcc	.Lkzp_kloop
	rts

; ============================================================================
; A/B TERMS (eval.c 1084-1166). Fully INLINE (no jsr to eval.c sub-terms; the
; 16-bit int multiplies use libgcc __mulhi3, which is NOT an eval.c term helper
; -- per the no-jsr-to-C rule, libgcc is allowed). All three GUARD on a weight
; == 0 (the SHIPPED config has all three at 0, so the bodies are corpus-cold; the
; guard return is what the corpus validates). Bodies are faithful to the C.
; ============================================================================

; ----------------------------------------------------------------------------
; .Ls_king_attack_escalation -- king_attack_escalation(e). eval.c 1084-1093.
;   if (g_w.king_attack_escalation == 0) return;
;   cw = count_king_zone_attackers(e, e.wk, 0);
;   if (cw >= 2) e.score -= W*(cw-1)*(cw-1);
;   cb = count_king_zone_attackers(e, e.bk, WHITE_COLOR);
;   if (cb >= 2) e.score += W*(cb-1)*(cb-1).
;   count returns BEFORE the multiply, so __rc2/3 may be clobbered by __mulhi3.
; ----------------------------------------------------------------------------
.Ls_king_attack_escalation:
; guard: W == 0 ?
	lda	g_w + W_KING_ATTACK_ESCALATION
	ora	g_w + W_KING_ATTACK_ESCALATION + 1
	bne	.Lkae_go
	rts
.Lkae_go:
; cw = count_king_zone_attackers(e.wk, attacker_color=0)
	lda	E_BUF + E_WK
	sta	AB_KSQ
	lda	#0
	sta	AB_ACOL
	jsr	.Ls_count_kza          ; A = cw (byte count)
; if (cw >= 2) e.score -= W*(cw-1)*(cw-1)
	cmp	#2
	bcc	.Lkae_black            ; cw < 2 -> skip
	jsr	.Ls_kae_term           ; A/X = W*(cw-1)^2 (A held cw on entry)
	jsr	.Ls_score_subAX
.Lkae_black:
; cb = count_king_zone_attackers(e.bk, attacker_color=WHITE_COLOR)
	lda	E_BUF + E_BK
	sta	AB_KSQ
	lda	#WHITE_COLOR
	sta	AB_ACOL
	jsr	.Ls_count_kza          ; A = cb
	cmp	#2
	bcc	.Lkae_ret              ; cb < 2 -> skip
	jsr	.Ls_kae_term           ; A/X = W*(cb-1)^2
	jsr	.Ls_score_addAX
.Lkae_ret:
	rts

; .Ls_kae_term -- given count c in A (c>=2), return W*(c-1)*(c-1) in A=lo/X=hi.
;   m = (c-1)*(c-1) (a byte; c<=~8 -> m<=49). product = g_w.kae * m (16-bit).
.Ls_kae_term:
	sec
	sbc	#1                     ; c-1
	sta	__rc8                  ; __rc8 = (c-1)
; m = (c-1)*(c-1): small, compute via repeated add (c-1 <= ~7).
	lda	#0
	sta	__rc9                  ; m accumulator
	ldx	__rc8
	beq	.Lkaet_haveM           ; (c-1)==0 -> m=0 (won't happen for c>=2)
.Lkaet_mloop:
	clc
	lda	__rc9
	adc	__rc8
	sta	__rc9
	dex
	bne	.Lkaet_mloop
.Lkaet_haveM:
; product = g_w.kae (16-bit) * m (16-bit, hi=0). __mulhi3: arg1 __rc2/3, arg2 A/X.
	lda	__rc9                  ; m (lo)
	sta	__rc2
	lda	#0
	sta	__rc3                  ; m (hi) = 0
	lda	g_w + W_KING_ATTACK_ESCALATION
	ldx	g_w + W_KING_ATTACK_ESCALATION + 1
	jsr	__mulhi3               ; -> A=lo / X=hi
	rts

; ----------------------------------------------------------------------------
; .Ls_count_kza -- count_king_zone_attackers(e, AB_KSQ, AB_ACOL). eval.c 1046-1082.
;   Returns the count c in A (byte). Mirrors king_zone_pressure detection but
;   COUNTS instead of sub8s. Requires __rc2/3 = BPTR (set at entry). Scratch:
;   A/X/Y, __rc8 (piece), AB_D (dir/knight idx), AB_RAY (ray), AB_CNT (count c).
; ----------------------------------------------------------------------------
.Ls_count_kza:
	lda	BPTR
	sta	__rc2
	lda	BPTR+1
	sta	__rc3
	lda	#0
	sta	AB_CNT                 ; c = 0
	sta	AB_D                   ; d = 0
.Lckza_dir:
	lda	AB_KSQ
	sta	AB_RAY                 ; ray = king_sq
.Lckza_step:
	ldx	AB_D
	lda	ALLDIR_OFFS, x
	clc
	adc	AB_RAY
	sta	AB_RAY                 ; ray = add8(ray, delta)
	and	#OFFBOARD_MASK
	bne	.Lckza_dir_done        ; offboard -> break
	ldy	AB_RAY
	lda	(__rc2),y              ; piece = b[ray]
	bne	.Lckza_occ
	jmp	.Lckza_step            ; EMPTY -> continue
.Lckza_occ:
	sta	__rc8                  ; piece
; if ((piece & 0x80) != attacker_color) break
	and	#WHITE_COLOR
	cmp	AB_ACOL
	beq	.Lckza_samecol
	jmp	.Lckza_dir_done
.Lckza_samecol:
; t = piece & 7
	lda	__rc8
	and	#0x07
	tax                           ; X = t
	cpx	#PT_QUEEN
	bne	.Lckza_notqueen
; QUEEN -> c++; break
	inc	AB_CNT
	jmp	.Lckza_dir_done
.Lckza_notqueen:
; orthogonal directions d == 1,3,4,6 ?
	lda	AB_D
	cmp	#1
	beq	.Lckza_ortho
	cmp	#3
	beq	.Lckza_ortho
	cmp	#4
	beq	.Lckza_ortho
	cmp	#6
	beq	.Lckza_ortho
; diagonal: if (t == BISHOP_T) c++; break
	cpx	#PT_BISHOP
	bne	.Lckza_dir_done
	inc	AB_CNT
	jmp	.Lckza_dir_done
.Lckza_ortho:
; if (t == ROOK_T) c++; break
	cpx	#PT_ROOK
	bne	.Lckza_dir_done
	inc	AB_CNT
.Lckza_dir_done:
	inc	AB_D
	lda	AB_D
	cmp	#8
	bcs	.Lckza_knights
	jmp	.Lckza_dir
.Lckza_knights:
; knight attackers: for i=0..7
	lda	#0
	sta	AB_D                   ; reuse AB_D as knight index i
.Lckza_kloop:
	ldx	AB_D
	lda	AB_KSQ
	clc
	adc	KNIGHT_OFFS, x         ; dest = add8(king_sq, KNIGHT_OFFSETS[i])
	tay
	and	#OFFBOARD_MASK
	bne	.Lckza_knext           ; offboard -> continue
	lda	(__rc2),y              ; piece = b[dest]
	beq	.Lckza_knext           ; EMPTY -> continue
	sta	__rc8
	and	#WHITE_COLOR
	cmp	AB_ACOL
	bne	.Lckza_knext           ; not attacker color -> continue
	lda	__rc8
	and	#0x07
	cmp	#PT_KNIGHT
	bne	.Lckza_knext           ; not a knight -> continue
	inc	AB_CNT
.Lckza_knext:
	inc	AB_D
	lda	AB_D
	cmp	#8
	bcc	.Lckza_kloop
	lda	AB_CNT                 ; A = c
	rts

; ----------------------------------------------------------------------------
; .Ls_pawn_storm -- pawn_storm(e). eval.c 1101-1130.
;   if (g_w.pawn_storm == 0) return;
;   bk_file = e.bk & 7; wk_file = e.wk & 7;
;   walk x: piece=b[x]; if ((piece&7)!=PAWN_T) continue; file=x&7; row=x>>4;
;     white (piece&0x80): df=|file-bk_file|; if df>1 continue; rank=8-row;
;        if (rank>=4 && rank<=7) score += W*(rank-3);
;     black: df=|file-wk_file|; if df>1 continue; rank=8-row;
;        if (rank>=2 && rank<=5) score -= W*(6-rank).
;   Requires __rc2/3 = BPTR for b[x] reads -- but __mulhi3 clobbers __rc2/3, so
;   reload BPTR at the top of each iteration. Scratch: AB_X (x), AB_KFILE (enemy
;   king file), PSROW (row), __rc8/9 (piece / scratch).
; ----------------------------------------------------------------------------
.Ls_pawn_storm:
	lda	g_w + W_PAWN_STORM
	ora	g_w + W_PAWN_STORM + 1
	bne	.Lpst_go
	rts
.Lpst_go:
	lda	#0
	sta	AB_X
.Lpst_walk:
; reload __rc2/3 = BPTR (a prior __mulhi3 may have clobbered it)
	lda	BPTR
	sta	__rc2
	lda	BPTR+1
	sta	__rc3
	ldy	AB_X
	lda	(__rc2),y              ; piece = b[x]
	sta	__rc8                  ; __rc8 = piece
	and	#0x07
	cmp	#PT_PAWN
	beq	.Lpst_ispawn
	jmp	.Lpst_next             ; (piece&7)!=PAWN_T -> continue
.Lpst_ispawn:
; file = x & 7; row = x >> 4
	lda	AB_X
	and	#0x07
	sta	__rc9                  ; __rc9 = file
	lda	AB_X
	lsr	a
	lsr	a
	lsr	a
	lsr	a
	sta	PSROW                  ; row
	lda	__rc8
	and	#WHITE_COLOR
	bne	.Lpst_white
	jmp	.Lpst_black
; ===== WHITE PAWN =====
.Lpst_white:
; bk_file = e.bk & 7
	lda	E_BUF + E_BK
	and	#0x07
	sta	AB_KFILE
; df = |file - bk_file|
	lda	__rc9
	sec
	sbc	AB_KFILE
	bpl	.Lpst_w_pos
	eor	#0xFF
	clc
	adc	#1
.Lpst_w_pos:
	cmp	#2
	bcc	.Lpst_w_close          ; df <= 1
	jmp	.Lpst_next             ; df > 1 -> continue
.Lpst_w_close:
; rank = 8 - row; if (rank>=4 && rank<=7) score += W*(rank-3)
	lda	#8
	sec
	sbc	PSROW                  ; rank (1..8)
	sta	__rc9                  ; __rc9 = rank
	cmp	#4
	bcc	.Lpst_next             ; rank < 4
	cmp	#8
	bcs	.Lpst_next             ; rank > 7 (>= 8)
; mult = rank - 3
	lda	__rc9
	sec
	sbc	#3                     ; (rank-3), small (1..4)
	jsr	.Ls_pst_mul            ; A/X = W * (rank-3)
	jsr	.Ls_score_addAX
	jmp	.Lpst_next
; ===== BLACK PAWN =====
.Lpst_black:
; wk_file = e.wk & 7
	lda	E_BUF + E_WK
	and	#0x07
	sta	AB_KFILE
; df = |file - wk_file|
	lda	__rc9
	sec
	sbc	AB_KFILE
	bpl	.Lpst_b_pos
	eor	#0xFF
	clc
	adc	#1
.Lpst_b_pos:
	cmp	#2
	bcc	.Lpst_b_close
	jmp	.Lpst_next
.Lpst_b_close:
; rank = 8 - row; if (rank>=2 && rank<=5) score -= W*(6-rank)
	lda	#8
	sec
	sbc	PSROW
	sta	__rc9                  ; rank
	cmp	#2
	bcc	.Lpst_next             ; rank < 2
	cmp	#6
	bcs	.Lpst_next             ; rank > 5 (>= 6)
; mult = 6 - rank
	lda	#6
	sec
	sbc	__rc9                  ; (6-rank), small (1..4)
	jsr	.Ls_pst_mul            ; A/X = W * (6-rank)
	jsr	.Ls_score_subAX
.Lpst_next:
	inc	AB_X
	lda	AB_X
	and	#0x08
	beq	.Lpst_test
	lda	AB_X
	clc
	adc	#8
	sta	AB_X
.Lpst_test:
	lda	AB_X
	cmp	#BOARD_SIZE
	bcs	.Lpst_ret
	jmp	.Lpst_walk
.Lpst_ret:
	rts

; .Ls_pst_mul -- return g_w.pawn_storm * (A) in A=lo/X=hi (A = small multiplier).
;   Uses __mulhi3 (clobbers __rc2/3; caller reloads BPTR next iteration).
.Ls_pst_mul:
	sta	__rc2                  ; multiplier (lo)
	lda	#0
	sta	__rc3                  ; multiplier (hi) = 0
	lda	g_w + W_PAWN_STORM
	ldx	g_w + W_PAWN_STORM + 1
	jmp	__mulhi3               ; tail-call -> A/X (rts)

; ----------------------------------------------------------------------------
; .Ls_queen_attacks_minor -- queen_attacks_minor(e). eval.c 1134-1166.
;   if (g_w.queen_attacks_minor == 0) return;
;   walk x: piece=b[x]; if ((piece&7)!=QUEEN_T) continue; qcolor=piece&0x80;
;     for d=0..7: ray=x; scan: ray=add8(ray,off); if(ray&0x88)break;
;        hit=b[ray]; if(hit==EMPTY)continue; (first piece hit)
;        if ((hit&0x80)!=qcolor){ t=hit&7; if(t==KNIGHT_T||t==BISHOP_T){
;           if(hit&0x80) score-=W else score+=W; } } break;
;   No multiply -> __rc2/3 = BPTR stays valid throughout. Scratch: AB_X (x),
;   AB_D (dir), AB_RAY (ray), AB_QCOL (qcolor), __rc8 (piece/hit).
; ----------------------------------------------------------------------------
.Ls_queen_attacks_minor:
	lda	g_w + W_QUEEN_ATTACKS_MINOR
	ora	g_w + W_QUEEN_ATTACKS_MINOR + 1
	bne	.Lqam_go
	rts
.Lqam_go:
	lda	BPTR
	sta	__rc2
	lda	BPTR+1
	sta	__rc3
	lda	#0
	sta	AB_X
.Lqam_walk:
	ldy	AB_X
	lda	(__rc2),y              ; piece = b[x]
	and	#0x07
	cmp	#PT_QUEEN
	beq	.Lqam_isqueen
	jmp	.Lqam_next             ; not a queen -> continue
.Lqam_isqueen:
; qcolor = piece & 0x80
	ldy	AB_X
	lda	(__rc2),y
	and	#WHITE_COLOR
	sta	AB_QCOL
	lda	#0
	sta	AB_D                   ; d = 0
.Lqam_dir:
	lda	AB_X
	sta	AB_RAY                 ; ray = x
.Lqam_step:
	ldx	AB_D
	lda	ALLDIR_OFFS, x
	clc
	adc	AB_RAY
	sta	AB_RAY                 ; ray = add8(ray, off)
	and	#OFFBOARD_MASK
	bne	.Lqam_dir_done         ; offboard -> break this dir
	ldy	AB_RAY
	lda	(__rc2),y              ; hit = b[ray]
	bne	.Lqam_hit
	jmp	.Lqam_step             ; EMPTY -> continue scanning ray
.Lqam_hit:
	sta	__rc8                  ; hit (first piece on the ray)
; if ((hit & 0x80) != qcolor) -> enemy: check minor
	and	#WHITE_COLOR
	cmp	AB_QCOL
	beq	.Lqam_dir_done         ; same color -> break (no penalty)
; t = hit & 7; if (t==KNIGHT_T || t==BISHOP_T) apply
	lda	__rc8
	and	#0x07
	cmp	#PT_KNIGHT
	beq	.Lqam_minor
	cmp	#PT_BISHOP
	beq	.Lqam_minor
	jmp	.Lqam_dir_done         ; enemy non-minor -> break
.Lqam_minor:
; if (hit & 0x80) score -= W else score += W
	lda	__rc8
	and	#WHITE_COLOR
	beq	.Lqam_add              ; black minor -> score += W
	lda	g_w + W_QUEEN_ATTACKS_MINOR
	ldx	g_w + W_QUEEN_ATTACKS_MINOR + 1
	jsr	.Ls_score_subAX        ; white minor -> score -= W
	jmp	.Lqam_dir_done
.Lqam_add:
	lda	g_w + W_QUEEN_ATTACKS_MINOR
	ldx	g_w + W_QUEEN_ATTACKS_MINOR + 1
	jsr	.Ls_score_addAX
.Lqam_dir_done:
	inc	AB_D
	lda	AB_D
	cmp	#8
	bcs	.Lqam_next
	jmp	.Lqam_dir
.Lqam_next:
	inc	AB_X
	lda	AB_X
	and	#0x08
	beq	.Lqam_test
	lda	AB_X
	clc
	adc	#8
	sta	AB_X
.Lqam_test:
	lda	AB_X
	cmp	#BOARD_SIZE
	bcs	.Lqam_ret
	jmp	.Lqam_walk
.Lqam_ret:
	rts

.Lfunc_end_eval_full:
	.size	eval_full, .Lfunc_end_eval_full-eval_full
