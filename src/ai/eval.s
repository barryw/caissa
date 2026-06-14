; Generated ca65 port from Chess/ai/eval.asm.
; Keep source changes in this repository in ca65 syntax.

; import-once was handled by the ca65 include topology

; Position Evaluation
; Returns centipawn score (positive = white advantage)

.segment "CODE"

EvalWorkSquare = $f0
EvalWorkColor = $f1
EvalWorkType = $f2

;
; Piece Values (scaled: pawn = 10)
; Values chosen to fit in single byte operations while preserving
; relative values: P=1, N=3.2, B=3.3, R=5, Q=9
;
PAWN_VALUE = 100
KNIGHT_VALUE = 320
BISHOP_VALUE = 330
ROOK_VALUE = 500
QUEEN_VALUE = 900
KING_VALUE = 0; Kings not counted in material

;
; Tactical pressure constants
; Penalize pieces currently attacked by enemy pawns. A pawn fork/threat is
; cheap to detect and catches many otherwise invisible one-ply tactics.
;
; Part B centipawn rescale: every eval term constant below is x10 of its
; pre-rescale value (pawn = 100 = literal centipawns). This is a pure
; resolution change; no move decision is intended to differ.
PAWN_ATTACK_MINOR_PENALTY = 600
PAWN_ATTACK_ROOK_PENALTY = 600
PAWN_ATTACK_QUEEN_PENALTY = 850
QUEEN_ATTACK_MINOR_PENALTY = 750
MINOR_ATTACK_ROOK_PENALTY = 280
MINOR_ATTACK_QUEEN_PENALTY = 350
KNIGHT_OUTPOST_BONUS = 250
PINNED_PAWN_PENALTY = 120
PINNED_MINOR_PENALTY = 250
PINNED_ROOK_PENALTY = 350
PINNED_QUEEN_PENALTY = 450
PINNED_ATTACKED_PENALTY = 200

;
; Pawn Structure Evaluation Constants
;
DOUBLED_PAWN_PENALTY = 150
ISOLATED_PAWN_PENALTY = 200
PASSED_PAWN_BONUS_BASE = 200
ADVANCED_PAWN_BONUS = 80
DEEP_ADVANCED_PAWN_BONUS = 160
ROOK_BEHIND_PASSER_BONUS = 200
CONNECTED_PASSER_BONUS = 120
PROTECTED_PASSER_BONUS = 80
BLOCKADED_PASSER_PENALTY = 100
BISHOP_PAIR_BONUS = 200
ROOK_OPEN_FILE_BONUS = 250
ROOK_SEMI_OPEN_FILE_BONUS = 120
HEAVY_SEVENTH_RANK_BONUS = 180
ENDGAME_NONPAWN_LIMIT = 1; K+P and single-piece endings (a COUNT, not eval units)
ENDGAME_KING_ACTIVITY_BONUS = 300
ENDGAME_ROOK_OPEN_FILE_BONUS = 600
ENDGAME_ROOK_KING_CUTOFF_BONUS = 250

;
; King Safety Evaluation Constants
; Part B: these stay at the PRE-rescale (x1) magnitude. EvaluateSingleKingSafety
; is kept byte-for-byte identical to the pre-rescale code (signed *byte*
; accumulator, including the wraparound when a king's raw safety exceeds +/-127).
; EvaluateKingSafety then multiplies that signed byte by 10, so the contribution
; is exactly (old signed byte) x 10 and the baseline is reproduced move-identically
; (overflow artifact included).
;
CASTLED_BONUS = 30; Bonus for being on castled squares
PAWN_SHIELD_BONUS = 10; Bonus per pawn in shield
OPEN_FILE_PENALTY = 25; Penalty for open file near king
SEMI_OPEN_FILE_PENALTY = 12; Penalty for half-open file near king
KING_CENTER_PENALTY = 30; Penalty for king in center in middlegame
KING_MARCH_BASE = 8; Flat middlegame penalty once the king leaves ranks 1-2
KING_MARCH_STEP = 8; Extra penalty per rank the king has marched forward
KING_ZONE_ATTACK_PENALTY = 5; Penalty per attacked square around the king

; Passed pawn bonus by rank (row 0 = rank 8, row 7 = rank 1)
; White pawns advance toward row 0, black toward row 7
; Part B centipawn rescale: 16-bit (x10) since rank-8 entry (400) exceeds a byte.
PassedPawnBonus_Lo:
  .byte <400, <300, <250, <200, <150, <100, <0, <0
PassedPawnBonus_Hi:
  .byte >400, >300, >250, >200, >150, >100, >0, >0

;
; Piece value lookup table
; Indexed by (piece & $07) - piece type
; Index 0 = empty, 1-6 = pawn through king
; Part B centipawn rescale: 16-bit (x10). PAWN=100 .. QUEEN=900 exceed a byte.
;
PieceValues_Lo:
  .byte <0; 0: empty/invalid
  .byte <PAWN_VALUE; 1: pawn
  .byte <KNIGHT_VALUE; 2: knight
  .byte <BISHOP_VALUE; 3: bishop
  .byte <ROOK_VALUE; 4: rook
  .byte <QUEEN_VALUE; 5: queen
  .byte <KING_VALUE; 6: king
PieceValues_Hi:
  .byte >0
  .byte >PAWN_VALUE
  .byte >KNIGHT_VALUE
  .byte >BISHOP_VALUE
  .byte >ROOK_VALUE
  .byte >QUEEN_VALUE
  .byte >KING_VALUE

; Part B: penalty lookup tables are 16-bit (x10 values exceed a byte). Each is
; a parallel _Lo/_Hi pair indexed by piece type; consumers load the pair into
; A (lo) / X (hi) and call AddEval16 / SubEval16.
PawnAttackPenalty_Lo:
  .byte <0; 0: empty/invalid
  .byte <0; 1: pawn
  .byte <PAWN_ATTACK_MINOR_PENALTY; 2: knight
  .byte <PAWN_ATTACK_MINOR_PENALTY; 3: bishop
  .byte <PAWN_ATTACK_ROOK_PENALTY; 4: rook
  .byte <PAWN_ATTACK_QUEEN_PENALTY; 5: queen
  .byte <0; 6: king
PawnAttackPenalty_Hi:
  .byte >0, >0
  .byte >PAWN_ATTACK_MINOR_PENALTY
  .byte >PAWN_ATTACK_MINOR_PENALTY
  .byte >PAWN_ATTACK_ROOK_PENALTY
  .byte >PAWN_ATTACK_QUEEN_PENALTY
  .byte >0

QueenAttackPenalty_Lo:
  .byte <0; 0: empty/invalid
  .byte <0; 1: pawn
  .byte <QUEEN_ATTACK_MINOR_PENALTY; 2: knight
  .byte <QUEEN_ATTACK_MINOR_PENALTY; 3: bishop
  .byte <0; 4: rook
  .byte <0; 5: queen
  .byte <0; 6: king
QueenAttackPenalty_Hi:
  .byte >0, >0
  .byte >QUEEN_ATTACK_MINOR_PENALTY
  .byte >QUEEN_ATTACK_MINOR_PENALTY
  .byte >0, >0, >0

MinorAttackPenalty_Lo:
  .byte <0; 0: empty/invalid
  .byte <0; 1: pawn
  .byte <0; 2: knight
  .byte <0; 3: bishop
  .byte <MINOR_ATTACK_ROOK_PENALTY; 4: rook
  .byte <MINOR_ATTACK_QUEEN_PENALTY; 5: queen
  .byte <0; 6: king
MinorAttackPenalty_Hi:
  .byte >0, >0, >0, >0
  .byte >MINOR_ATTACK_ROOK_PENALTY
  .byte >MINOR_ATTACK_QUEEN_PENALTY
  .byte >0

PinnedPiecePenalty_Lo:
  .byte <0; 0: empty/invalid
  .byte <PINNED_PAWN_PENALTY; 1: pawn
  .byte <PINNED_MINOR_PENALTY; 2: knight
  .byte <PINNED_MINOR_PENALTY; 3: bishop
  .byte <PINNED_ROOK_PENALTY; 4: rook
  .byte <PINNED_QUEEN_PENALTY; 5: queen
  .byte <0; 6: king
PinnedPiecePenalty_Hi:
  .byte >0
  .byte >PINNED_PAWN_PENALTY
  .byte >PINNED_MINOR_PENALTY
  .byte >PINNED_MINOR_PENALTY
  .byte >PINNED_ROOK_PENALTY
  .byte >PINNED_QUEEN_PENALTY
  .byte >0

PinSliderTypes:
  .byte BISHOP_TYPE, ROOK_TYPE, BISHOP_TYPE, ROOK_TYPE
  .byte ROOK_TYPE, BISHOP_TYPE, ROOK_TYPE, BISHOP_TYPE

;
; Evaluation result (16-bit signed)
; Positive = white advantage, negative = black advantage
;
.segment "BSS"

EvalScore:
  .res 2
EvalNonPawnCount:
  .res 1
EvalPawnCount:
  .res 1
EvalQueenCount:
  .res 1
EvalWhiteBishopCount:
  .res 1
EvalBlackBishopCount:
  .res 1
EvalEndgameFlag:
  .res 1
; When nonzero, EvaluatePosition computes only material + PST + phase
; counters. Set/cleared by EvaluateLazy in search.s.
EvalLazyStage:
  .res 1

;
; Pawn count storage per file (0-7)
;
WhitePawnsPerFile: .res 8
BlackPawnsPerFile: .res 8

.segment "CODE"

;
; EvaluatePosition
; Full evaluation: material + piece-square tables
; Result in EvalScore (16-bit signed)
; Clobbers: A, X, Y, $f0-$f8
;
EvaluatePosition:
; Clear score and combine material/PST in one board pass.
  lda #$00
  sta EvalScore
  sta EvalScore + 1
  sta EvalNonPawnCount
  sta EvalPawnCount
  sta EvalQueenCount
  sta EvalWhiteBishopCount
  sta EvalBlackBishopCount
  sta EvalEndgameFlag

  ldx #$00; Board index

PstLoop:
; Get piece at square
  lda Board88, x
  cmp #EMPTY_PIECE
  bne __ai_eval_pst_piece_present_0

; Empty square: advance inline (duplicate of PstNext) to skip the round trip
; through the far jmp. Same index sequence, fewer cycles.
  inx
  txa
  and #$08; Past file h in 0x88 layout?
  beq __ai_eval_pst_empty_chk_0
  txa
  clc
  adc #$08; Skip offboard gap to next rank
  tax
__ai_eval_pst_empty_chk_0:
  cpx #BOARD_SIZE
  bne PstLoop
  jmp __ai_eval_done_0

__ai_eval_pst_piece_present_0:

; Save board index
  stx $f0

; Get piece type and color (A still holds the piece; reload beats pha/pla)
  and #WHITE_COLOR
  sta $f1; $f1 = color ($80=white, $00=black)
  lda Board88, x
  and #$07; Piece type (1-6)
  sta $f2; $f2 = piece type
  cmp #PAWN_TYPE
  bne __ai_eval_piece_phase_not_pawn_0
  inc EvalPawnCount
  lda EvalLazyStage
  bne __ai_eval_piece_phase_done_0
  jsr EvaluateAdvancedPawn
  jmp __ai_eval_piece_phase_done_0
__ai_eval_piece_phase_not_pawn_0:
  cmp #KING_TYPE
  beq __ai_eval_piece_phase_done_0
  inc EvalNonPawnCount
  cmp #BISHOP_TYPE
  bne __ai_eval_piece_phase_not_bishop_0
  lda $f1
  beq __ai_eval_black_bishop_count_0
  inc EvalWhiteBishopCount
  jmp __ai_eval_piece_phase_after_bishop_0
__ai_eval_black_bishop_count_0:
  inc EvalBlackBishopCount
__ai_eval_piece_phase_after_bishop_0:
  lda $f2
__ai_eval_piece_phase_not_bishop_0:
  cmp #QUEEN_TYPE
  bne __ai_eval_piece_phase_not_queen_0
  inc EvalQueenCount
__ai_eval_piece_phase_not_queen_0:
; The per-piece pressure and mobility scans dominate evaluation cost
; (~30K cycles per piece). The lazy first stage skips them; quiescence
; stand-pat only pays for them when material+PST lands near the window.
  lda EvalLazyStage
  bne __ai_eval_piece_phase_done_0
  jsr EvaluatePawnPressure
  jsr EvaluateQueenPressure
  jsr EvaluateMinorPressure
  jsr EvaluateKnightOutpost
  jsr EvaluateMobility
  jsr EvaluateSeventhRankPressure
__ai_eval_piece_phase_done_0:

; Add material value and PST for this piece (inline per color).
; The 0x88 -> 0-63 conversion (and the black rank mirror) now come from
; lookup tables (Sq88To64 / Sq88To64Mirror below). The 16-bit adds use
; carry-conditional inc/dec of the high byte, which produces the exact same
; EvalScore as the previous adc #$00 / sbc #$00 sequences. The negative-PST
; cases keep the original "negate to unsigned magnitude" semantics so even
; a -128 entry behaves identically.
  ldy $f2
; Load the lo/hi PST table pointers once (shared by both colors).
  lda PST_Table_Lo, y
  sta $f3
  lda PST_Table_Hi, y
  sta $f4; $f3/$f4 = PST low-byte table pointer
  lda PST_TableHi_Lo, y
  sta $f5
  lda PST_TableHi_Hi, y
  sta $f6; $f5/$f6 = PST high-byte table pointer
  lda $f1
  beq __ai_eval_pst_black_side_0

; --- White: EvalScore += material (16-bit); EvalScore += signed PST (16-bit) ---
  lda PieceValues_Lo, y
  clc
  adc EvalScore
  sta EvalScore
  lda PieceValues_Hi, y
  adc EvalScore + 1
  sta EvalScore + 1
  ldx $f0
  ldy Sq88To64, x
  lda ($f3), y; PST lo byte
  clc
  adc EvalScore
  sta EvalScore
  lda ($f5), y; PST hi byte (sign-extended)
  adc EvalScore + 1
  sta EvalScore + 1
  jmp PstNext

; --- Black: EvalScore -= material (16-bit); EvalScore -= signed PST (16-bit) ---
__ai_eval_pst_black_side_0:
  sec
  lda EvalScore
  sbc PieceValues_Lo, y
  sta EvalScore
  lda EvalScore + 1
  sbc PieceValues_Hi, y
  sta EvalScore + 1
  ldx $f0
  ldy Sq88To64Mirror, x; mirrored square for black
  sec
  lda EvalScore
  sbc ($f3), y; PST lo byte
  sta EvalScore
  lda EvalScore + 1
  sbc ($f5), y; PST hi byte (sign-extended)
  sta EvalScore + 1
  jmp PstNext

PstNext:
  inx
  txa
  and #$08; Past file h in 0x88 layout?
  beq __ai_eval_pst_check_done_0
  txa
  clc
  adc #$08; Skip offboard gap to next rank
  tax
__ai_eval_pst_check_done_0:
  cpx #BOARD_SIZE
  beq __ai_eval_done_0
  jmp PstLoop
__ai_eval_done_0:
  lda EvalNonPawnCount
  cmp #ENDGAME_NONPAWN_LIMIT + 1
  bcc __ai_eval_set_endgame_0
  bne __ai_eval_phase_done_0
  lda EvalQueenCount
  bne __ai_eval_phase_done_0
__ai_eval_set_endgame_0:
  lda #$01
  sta EvalEndgameFlag

__ai_eval_phase_done_0:
; Lazy stage one ends here: material, PST, and phase counters only.
  lda EvalLazyStage
  beq __ai_eval_full_tail_0
  rts
__ai_eval_full_tail_0:
  jsr ApplyBishopPairBonus

; Evaluate pawn structure only when pawns exist. Sparse tactical and
; checkmate searches otherwise pay several board scans for a zero score.
  lda EvalPawnCount
  beq __ai_eval_pawn_structure_done_0
  jsr EvaluatePawnStructure
__ai_eval_pawn_structure_done_0:

; Middlegame king safety rewards castling and pawn shields. In endgames,
; active kings matter instead.
  lda EvalEndgameFlag
  beq __ai_eval_eval_middlegame_king_0
  jmp EvaluateEndgame
__ai_eval_eval_middlegame_king_0:
  jsr EvaluateKingPins
  jmp EvaluateKingSafety

;
; Sq88To64 - 0x88 board index -> 0-63 PST index
; Sq88To64Mirror - same, rank-mirrored (eor #$38) for black pieces
; Offboard entries are never read (the PST loop skips them); padded with 0.
;
Sq88To64:
.repeat 128, i
  .if (i & $88) = 0
    .byte ((i & $70) >> 1) | (i & $07)
  .else
    .byte $00
  .endif
.endrepeat

Sq88To64Mirror:
.repeat 128, i
  .if (i & $88) = 0
    .byte (((i & $70) >> 1) | (i & $07)) ^ $38
  .else
    .byte $00
  .endif
.endrepeat

;
; EvaluatePawnPressure
; Adds a small static tactical penalty when a non-pawn piece is attacked by an
; enemy pawn. Inputs: $f0=square, $f1=color, $f2=piece type.
; Clobbers: A, Y, $f3
;
EvaluatePawnPressure:
  jsr IsPiecePawnAttacked
  bcc __ai_eval_done_1

  lda $f1
  beq __ai_eval_black_attacked_0
  ldy $f2
  lda PawnAttackPenalty_Lo, y
  ldx PawnAttackPenalty_Hi, y
  jmp SubEval16

__ai_eval_black_attacked_0:
  ldy $f2
  lda PawnAttackPenalty_Lo, y
  ldx PawnAttackPenalty_Hi, y
  jmp AddEval16

__ai_eval_done_1:
  rts

;
; EvaluateAdvancedPawn
; Reward pawns that have crossed into enemy territory even before they qualify
; as passed. These pawns take space, cramp pieces, and become tactical hooks.
; Inputs: $f0=square, $f1=color, $f2=piece type.
; Clobbers: A
;
EvaluateAdvancedPawn:
  lda $f2
  cmp #PAWN_TYPE
  beq __ai_eval_adv_pawn_0
  rts

__ai_eval_adv_pawn_0:
  lda $f1
  beq __ai_eval_black_adv_pawn_0

; White pawns: row 3 is advanced, rows 1-2 are deep in enemy territory.
  lda $f0
  and #$70
  cmp #$30
  beq __ai_eval_white_advanced_0
  cmp #$30
  bcs __ai_eval_adv_done_0
  cmp #$00
  beq __ai_eval_adv_done_0
  lda #DEEP_ADVANCED_PAWN_BONUS
  jmp AddEvalUnsigned

__ai_eval_white_advanced_0:
  lda #ADVANCED_PAWN_BONUS
  jmp AddEvalUnsigned

__ai_eval_black_adv_pawn_0:
; Black pawns: row 4 is advanced, rows 5-6 are deep in enemy territory.
  lda $f0
  and #$70
  cmp #$40
  beq __ai_eval_black_advanced_0
  cmp #$50
  bcc __ai_eval_adv_done_0
  cmp #$70
  beq __ai_eval_adv_done_0
  lda #DEEP_ADVANCED_PAWN_BONUS
  jmp SubtractEvalUnsigned

__ai_eval_black_advanced_0:
  lda #ADVANCED_PAWN_BONUS
  jmp SubtractEvalUnsigned

__ai_eval_adv_done_0:
  rts

;
; ApplyBishopPairBonus
; Two bishops are a durable strategic asset in open positions. Track the pair
; during the main board pass and apply this compact bonus once per side.
; Clobbers: A, $f3
;
ApplyBishopPairBonus:
  lda EvalWhiteBishopCount
  cmp #$02
  bcc __ai_eval_check_black_bishop_pair_0
  lda #BISHOP_PAIR_BONUS
  jsr AddEvalUnsigned

__ai_eval_check_black_bishop_pair_0:
  lda EvalBlackBishopCount
  cmp #$02
  bcc __ai_eval_bishop_pair_done_0
  lda #BISHOP_PAIR_BONUS
  jmp SubtractEvalUnsigned

__ai_eval_bishop_pair_done_0:
  rts

;
; EvaluateQueenPressure
; Penalize loose minor pieces on an enemy home-queen ray. This catches shallow
; opening tactical failures like ...Bg4 when Qxg4 is immediately available,
; without paying full queen-ray detection once queens have moved.
; Inputs: $f0=square, $f1=color, $f2=piece type.
; Clobbers: A, X, Y, $f3-$f6
;
EvaluateQueenPressure:
  jsr IsPieceQueenAttacked
  bcc __ai_eval_done_2

  lda $f1
  beq __ai_eval_black_attacked_1
  ldy $f2
  lda QueenAttackPenalty_Lo, y
  ldx QueenAttackPenalty_Hi, y
  jmp SubEval16

__ai_eval_black_attacked_1:
  ldy $f2
  lda QueenAttackPenalty_Lo, y
  ldx QueenAttackPenalty_Hi, y
  jmp AddEval16

__ai_eval_done_2:
  rts

;
; EvaluateMinorPressure
; Penalize loose rooks and queens attacked by enemy knights or bishops. Heavy
; pieces under minor pressure are tactical targets and often become forks,
; skewers, or forced concessions before raw material changes.
; Inputs: $f0=square, $f1=color, $f2=piece type.
; Clobbers: A, X, Y, $f3-$f6
;
EvaluateMinorPressure:
  lda $f2
  cmp #ROOK_TYPE
  bcc __ai_eval_done_3
  cmp #KING_TYPE
  bcs __ai_eval_done_3

  jsr IsPieceKnightAttacked
  bcs __ai_eval_apply_minor_pressure_0

  jsr IsPieceBishopAttacked
  bcc __ai_eval_done_3

__ai_eval_apply_minor_pressure_0:
  ldy $f2
  lda MinorAttackPenalty_Lo, y
  ldx MinorAttackPenalty_Hi, y
; Zero check: only types with a nonzero penalty (rook/queen) reach here, but
; preserve the original skip-on-zero behavior across the full 16-bit value.
  sta $f3
  stx $f4
  ora $f4
  beq __ai_eval_done_3

  lda $f1
  beq __ai_eval_black_attacked_2
  lda $f3
  ldx $f4
  jmp SubEval16

__ai_eval_black_attacked_2:
  lda $f3
  ldx $f4
  jmp AddEval16

__ai_eval_done_3:
  rts

;
; EvaluateKnightOutpost
; Reward central advanced knights that are protected by a friendly pawn and
; cannot be chased by an enemy pawn. This is deliberately compact: it captures
; the common "strong square" idea without full pawn-frontier analysis.
; Inputs: $f0=square, $f1=color, $f2=piece type.
; Clobbers: A, Y, $f3
;
EvaluateKnightOutpost:
  lda $f2
  cmp #KNIGHT_TYPE
  bne __ai_eval_done_6

  lda $f0
  and #$07
  cmp #$02
  bcc __ai_eval_done_6
  cmp #$06
  bcs __ai_eval_done_6

  jsr IsPiecePawnAttacked
  bcs __ai_eval_done_6

  lda $f1
  beq __ai_eval_black_knight_outpost_0

; White outposts: central files on rows 2-4, protected from behind.
  lda $f0
  and #$70
  cmp #$20
  bcc __ai_eval_done_6
  cmp #$50
  bcs __ai_eval_done_6

  lda $f0
  clc
  adc #$0f
  jsr CheckWhitePawnAt
  bcs __ai_eval_white_outpost_found_0
  lda $f0
  clc
  adc #$11
  jsr CheckWhitePawnAt
  bcc __ai_eval_done_6

__ai_eval_white_outpost_found_0:
  lda #KNIGHT_OUTPOST_BONUS
  jmp AddEvalUnsigned

__ai_eval_black_knight_outpost_0:
; Black outposts: central files on rows 3-5, protected from behind.
  lda $f0
  and #$70
  cmp #$30
  bcc __ai_eval_done_6
  cmp #$60
  bcs __ai_eval_done_6

  lda $f0
  sec
  sbc #$0f
  jsr CheckBlackPawnAt
  bcs __ai_eval_black_outpost_found_0
  lda $f0
  sec
  sbc #$11
  jsr CheckBlackPawnAt
  bcc __ai_eval_done_6

__ai_eval_black_outpost_found_0:
  lda #KNIGHT_OUTPOST_BONUS
  jmp SubtractEvalUnsigned

__ai_eval_done_6:
  rts

;
; EvaluateMobility
; Adds a cheap pseudo-mobility score for non-pawn pieces without touching the
; shared move list. Inputs: $f0=square, $f1=color, $f2=piece type.
; Clobbers: A, X, Y, $f3-$f7, $fd-$fe
;
EvaluateMobility:
  lda $f2
  cmp #KNIGHT_TYPE
  beq __ai_eval_knight_0
  cmp #BISHOP_TYPE
  beq __ai_eval_bishop_0
  cmp #ROOK_TYPE
  beq __ai_eval_rook_0
  cmp #QUEEN_TYPE
  beq __ai_eval_queen_0
  rts

__ai_eval_knight_0:
  jsr CountKnightMobility
  jmp ApplyMobilityScore

__ai_eval_bishop_0:
  lda #<DiagonalOffsets
  sta $fd
  lda #>DiagonalOffsets
  sta $fe
  lda #$04
  jsr CountSlidingMobility
  jmp ApplyMobilityScore

__ai_eval_rook_0:
  lda #<OrthogonalOffsets
  sta $fd
  lda #>OrthogonalOffsets
  sta $fe
  lda #$04
  jsr CountSlidingMobility
  jmp ApplyMobilityScore

__ai_eval_queen_0:
  lda #<AllDirectionOffsets
  sta $fd
  lda #>AllDirectionOffsets
  sta $fe
  lda #$08
  jsr CountSlidingMobility

ApplyMobilityScore:
; Raw square-count was applied at a full eval unit (10cp) per square, uncapped
; and identical for every piece -- a centralized queen scored +250cp+ of pure
; mobility, biasing the engine toward premature queen/rook sorties. Halve it
; toward standard mobility weights. Self-play A/B (240 games): half ~55.8%
; (+41 Elo) vs the full-weight baseline; quarter and queen-quarter both lose
; (~46-50%) -- half-uniform is the optimum among {x1, x0.5, x0.25, queen-x0.25}.
  lsr
  beq __ai_eval_done_4
; Part B centipawn rescale: the mobility term is a raw (half) square-count in
; eval units with no scaling constant, so it must be multiplied by 10 like every
; other term. The half-count is small (<= ~13), so A*10 stays under 256 and the
; 8-bit Add/SubtractEvalUnsigned path is still exact. A*10 = A*8 + A*2.
  sta $f7; $f7 = half-count
  asl
  asl
  asl; A = half-count * 8
  sta $f3
  lda $f7
  asl; half-count * 2
  clc
  adc $f3; A = half-count * 10
  ldx $f1
  beq __ai_eval_black_piece_0
  jmp AddEvalUnsigned

__ai_eval_black_piece_0:
  jmp SubtractEvalUnsigned

__ai_eval_done_4:
  rts

;
; EvaluateSeventhRankPressure
; Reward rooks and queens that invade the enemy second rank. These pieces
; pressure pawns and trap kings even when the immediate material is unchanged.
; Inputs: $f0=square, $f1=color, $f2=piece type.
; Clobbers: A
;
EvaluateSeventhRankPressure:
  lda $f2
  cmp #ROOK_TYPE
  beq __ai_eval_heavy_piece_0
  cmp #QUEEN_TYPE
  beq __ai_eval_heavy_piece_0
  rts

__ai_eval_heavy_piece_0:
  lda $f1
  beq __ai_eval_black_heavy_0

; White heavy pieces on rank 7 (row $10).
  lda $f0
  and #$70
  cmp #$10
  bne __ai_eval_seventh_done_0
  lda #HEAVY_SEVENTH_RANK_BONUS
  jmp AddEvalUnsigned

__ai_eval_black_heavy_0:
; Black heavy pieces on rank 2 (row $60).
  lda $f0
  and #$70
  cmp #$60
  bne __ai_eval_seventh_done_0
  lda #HEAVY_SEVENTH_RANK_BONUS
  jmp SubtractEvalUnsigned

__ai_eval_seventh_done_0:
  rts

;
; CountKnightMobility
; Counts pseudo-legal knight destinations that are empty or enemy occupied.
; Inputs: $f0=square, $f1=color. Output: A=count.
; Clobbers: A, X, Y, $f3-$f5
;
CountKnightMobility:
  lda #$00
  sta $f3; $f3 = mobility count
  sta $f4; $f4 = offset index

__ai_eval_knight_loop_0:
  ldy $f4
  lda $f0
  clc
  adc KnightOffsets, y
  sta $f5
  and #OFFBOARD_MASK
  bne __ai_eval_next_knight_0

  ldx $f5
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_eval_count_knight_0
  and #WHITE_COLOR
  cmp $f1
  beq __ai_eval_next_knight_0

__ai_eval_count_knight_0:
  inc $f3

__ai_eval_next_knight_0:
  inc $f4
  lda $f4
  cmp #KnightOffsetsEnd - KnightOffsets
  bne __ai_eval_knight_loop_0

  lda $f3
  rts

;
; CountSlidingMobility
; Counts pseudo-legal ray destinations that are empty or enemy occupied.
; Inputs: A=direction count, $fd/$fe=direction table, $f0=square, $f1=color.
; Output: A=count. Clobbers: A, X, Y, $f3-$f7
;
CountSlidingMobility:
  sta $f7; $f7 = direction count
  lda #$00
  sta $f3; $f3 = mobility count
  sta $f4; $f4 = direction index

__ai_eval_dir_loop_0:
  ldy $f4
  lda ($fd), y
  sta $f6; $f6 = ray delta
  lda $f0
  sta $f5; $f5 = current ray square

__ai_eval_ray_loop_0:
  lda $f5
  clc
  adc $f6
  sta $f5
  and #OFFBOARD_MASK
  bne __ai_eval_next_dir_0

  ldx $f5
  lda Board88, x
  cmp #EMPTY_PIECE
  bne __ai_eval_occupied_0
  inc $f3
  jmp __ai_eval_ray_loop_0

__ai_eval_occupied_0:
  and #WHITE_COLOR
  cmp $f1
  beq __ai_eval_next_dir_0
  inc $f3

__ai_eval_next_dir_0:
  inc $f4
  lda $f4
  cmp $f7
  bne __ai_eval_dir_loop_0

  lda $f3
  rts

;
; IsPiecePawnAttacked
; Inputs: $f0=square, $f1=color, $f2=piece type.
; Output: Carry set if the piece is currently attacked by an enemy pawn.
; Clobbers: A, Y, $f3
;
IsPiecePawnAttacked:
  lda $f2
  cmp #KNIGHT_TYPE
  bcc __ai_eval_not_attacked_0
  cmp #KING_TYPE
  bcs __ai_eval_not_attacked_0

  lda $f1
  beq __ai_eval_black_piece_1

; White piece: black pawns attack from square -15 and square -17.
  lda $f0
  sec
  sbc #$0f
  jsr CheckBlackPawnAt
  bcs __ai_eval_attacked_0
  lda $f0
  sec
  sbc #$11
  jsr CheckBlackPawnAt
  bcs __ai_eval_attacked_0
  clc
  rts

__ai_eval_black_piece_1:
; Black piece: white pawns attack from square +15 and square +17.
  lda $f0
  clc
  adc #$0f
  jsr CheckWhitePawnAt
  bcs __ai_eval_attacked_0
  lda $f0
  clc
  adc #$11
  jsr CheckWhitePawnAt
  bcs __ai_eval_attacked_0

__ai_eval_not_attacked_0:
  clc
  rts

__ai_eval_attacked_0:
  sec
  rts

;
; IsPieceKnightAttacked
; Inputs: $f0=square, $f1=color.
; Output: Carry set if the piece is currently attacked by an enemy knight.
; Clobbers: A, X, Y, $f3-$f5
;
IsPieceKnightAttacked:
  lda $f1
  beq __ai_eval_black_piece_2
  lda #BLACK_KNIGHT
  jmp __ai_eval_set_enemy_knight_0

__ai_eval_black_piece_2:
  lda #WHITE_KNIGHT

__ai_eval_set_enemy_knight_0:
  sta $f4
  lda #$00
  sta $f3

__ai_eval_knight_loop_1:
  ldy $f3
  lda $f0
  clc
  adc KnightOffsets, y
  sta $f5
  and #OFFBOARD_MASK
  bne __ai_eval_next_knight_1

  ldx $f5
  lda Board88, x
  cmp $f4
  beq __ai_eval_attacked_1

__ai_eval_next_knight_1:
  inc $f3
  lda $f3
  cmp #KnightOffsetsEnd - KnightOffsets
  bne __ai_eval_knight_loop_1

  clc
  rts

__ai_eval_attacked_1:
  sec
  rts

;
; IsPieceBishopAttacked
; Inputs: $f0=square, $f1=color.
; Output: Carry set if the piece is currently attacked by an enemy bishop.
; Clobbers: A, X, Y, $f3-$f6
;
IsPieceBishopAttacked:
  lda $f1
  beq __ai_eval_black_piece_bishop_0
  lda #BLACK_BISHOP
  jmp __ai_eval_set_enemy_bishop_0

__ai_eval_black_piece_bishop_0:
  lda #WHITE_BISHOP

__ai_eval_set_enemy_bishop_0:
  sta $f6; $f6 = enemy bishop piece byte
  lda #$00
  sta $f3; $f3 = direction index

__ai_eval_bishop_dir_loop_0:
  ldy $f3
  lda DiagonalOffsets, y
  sta $f4; $f4 = ray delta
  lda $f0
  sta $f5; $f5 = current ray square

__ai_eval_bishop_ray_loop_0:
  lda $f5
  clc
  adc $f4
  sta $f5
  and #OFFBOARD_MASK
  bne __ai_eval_bishop_next_dir_0

  ldx $f5
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_eval_bishop_ray_loop_0
  cmp $f6
  beq __ai_eval_attacked_by_bishop_0

__ai_eval_bishop_next_dir_0:
  inc $f3
  lda $f3
  cmp #DiagonalOffsetsEnd - DiagonalOffsets
  bne __ai_eval_bishop_dir_loop_0

  clc
  rts

__ai_eval_attacked_by_bishop_0:
  sec
  rts

;
; IsPieceQueenAttacked
; Inputs: $f0=square, $f1=color, $f2=piece type.
; Output: Carry set if a minor piece is attacked by an enemy queen on d1/d8.
; Clobbers: A, X, Y, $f3-$f6
;
IsPieceQueenAttacked:
  lda $f2
  cmp #KNIGHT_TYPE
  bcc __ai_eval_not_attacked_1
  cmp #ROOK_TYPE
  bcs __ai_eval_not_attacked_1

  lda $f1
  beq __ai_eval_black_piece_3
  lda Board88 + $03
  cmp #BLACK_QUEEN
  bne __ai_eval_not_attacked_1
  lda #BLACK_QUEEN
  jmp __ai_eval_set_enemy_queen_0

__ai_eval_black_piece_3:
  lda Board88 + $73
  cmp #WHITE_QUEEN
  bne __ai_eval_not_attacked_1
  lda #WHITE_QUEEN

__ai_eval_set_enemy_queen_0:
  sta $f6; $f6 = enemy queen piece byte
  lda #$00
  sta $f3; $f3 = direction index

__ai_eval_dir_loop_1:
  ldy $f3
  lda AllDirectionOffsets, y
  sta $f4; $f4 = ray delta
  lda $f0
  sta $f5; $f5 = current ray square

__ai_eval_ray_loop_1:
  lda $f5
  clc
  adc $f4
  sta $f5
  and #OFFBOARD_MASK
  bne __ai_eval_next_dir_1

  ldx $f5
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_eval_ray_loop_1
  cmp $f6
  beq __ai_eval_attacked_2

__ai_eval_next_dir_1:
  inc $f3
  lda $f3
  cmp #$08
  bne __ai_eval_dir_loop_1

__ai_eval_not_attacked_1:
  clc
  rts

__ai_eval_attacked_2:
  sec
  rts

;
; SideHasPawnAttackedPiece
; Input: A = color bit ($80 white, $00 black)
; Output: Carry set if any non-pawn piece of that color is attacked by a pawn.
; Clobbers: A, X, Y, $f0-$f5
;
SideHasPawnAttackedPiece:
  sta $f4
  ldx #$00

__ai_eval_scan_loop_0:
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_eval_next_square_0
  sta $f5
  and #WHITE_COLOR
  cmp $f4
  bne __ai_eval_next_square_0
  stx $f0
  sta $f1
  lda $f5
  and #$07
  sta $f2
  jsr IsPiecePawnAttacked
  bcs __ai_eval_found_0
  ldx $f0

__ai_eval_next_square_0:
  inx
  txa
  and #$08
  beq __ai_eval_scan_check_done_0
  txa
  clc
  adc #$08
  tax
__ai_eval_scan_check_done_0:
  cpx #BOARD_SIZE
  bne __ai_eval_scan_loop_0
  clc
  rts

__ai_eval_found_0:
  sec
  rts

;
; SideHasMinorAttackedMajor
; Input: A = color bit ($80 white, $00 black)
; Output: Carry set if any rook or queen of that color is attacked by an enemy
; knight or bishop. Used to avoid trusting book moves while a major is loose.
; Clobbers: A, X, Y, $f0-$f7
;
SideHasMinorAttackedMajor:
  sta $f7
  ldx #$00

__ai_eval_major_scan_loop_0:
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_eval_major_next_square_0
  sta $f5
  and #WHITE_COLOR
  cmp $f7
  bne __ai_eval_major_next_square_0
  lda $f5
  and #$07
  cmp #ROOK_TYPE
  bcc __ai_eval_major_next_square_0
  cmp #KING_TYPE
  bcs __ai_eval_major_next_square_0

  stx $f0
  sta $f2
  lda $f7
  sta $f1
  jsr IsPieceKnightAttacked
  bcs __ai_eval_major_found_0
  jsr IsPieceBishopAttacked
  bcs __ai_eval_major_found_0
  ldx $f0

__ai_eval_major_next_square_0:
  inx
  txa
  and #$08
  beq __ai_eval_major_scan_check_done_0
  txa
  clc
  adc #$08
  tax
__ai_eval_major_scan_check_done_0:
  cpx #BOARD_SIZE
  bne __ai_eval_major_scan_loop_0
  clc
  rts

__ai_eval_major_found_0:
  sec
  rts

CheckBlackPawnAt:
  sta $f3
  and #OFFBOARD_MASK
  bne __ai_eval_not_attacked_2
  ldy $f3
  lda Board88, y
  cmp #BLACK_PAWN
  beq __ai_eval_attacked_3
__ai_eval_not_attacked_2:
  clc
  rts
__ai_eval_attacked_3:
  sec
  rts

CheckWhitePawnAt:
  sta $f3
  and #OFFBOARD_MASK
  bne __ai_eval_not_attacked_3
  ldy $f3
  lda Board88, y
  cmp #WHITE_PAWN
  beq __ai_eval_attacked_4
__ai_eval_not_attacked_3:
  clc
  rts
__ai_eval_attacked_4:
  sec
  rts

AddEvalUnsigned:
  sta $f3
  clc
  lda EvalScore
  adc $f3
  sta EvalScore
  lda EvalScore + 1
  adc #$00
  sta EvalScore + 1
  rts

SubtractEvalUnsigned:
  sta $f3
  sec
  lda EvalScore
  sbc $f3
  sta EvalScore
  lda EvalScore + 1
  sbc #$00
  sta EvalScore + 1
  rts

;
; AddEval16 / SubEval16
; Part B 16-bit term helpers. Input: A = value low byte, X = value high byte.
; AddEval16 does EvalScore += value; SubEval16 does EvalScore -= value. The
; value is treated as a 16-bit quantity (the rescaled term constants are all
; nonnegative, so the high byte is the true high byte, not a sign extension).
; Clobbers: A, $f3.
;
AddEval16:
  sta $f3
  clc
  lda EvalScore
  adc $f3
  sta EvalScore
  txa
  adc EvalScore + 1
  sta EvalScore + 1
  rts

SubEval16:
  sta $f3
  sec
  lda EvalScore
  sbc $f3
  sta EvalScore
  txa
  sta $f3
  lda EvalScore + 1
  sbc $f3
  sta EvalScore + 1
  rts

;
; EvaluateKingPins
; Penalize pieces pinned to their king by enemy bishops, rooks, or queens.
; A pinned defender is a tactical hostage: it cannot move freely and often
; becomes the lever for a winning attack.
; Clobbers: A, X, Y, $f0-$f7
;
EvaluateKingPins:
  lda whitekingsq
  ldx #WHITE_COLOR
  jsr EvaluatePinsFromKing

  lda blackkingsq
  ldx #BLACK_COLOR
; Fall through for the black king

;
; EvaluatePinsFromKing
; Input: A=king square, X=king color. Adds score against pinned side.
; Clobbers: A, X, Y, $f0-$f7
;
EvaluatePinsFromKing:
  sta $f0; $f0 = king square
  stx $f1; $f1 = pinned side color
  lda #$00
  sta $f2; $f2 = direction index

__ai_eval_pin_dir_loop_0:
  ldy $f2
  lda AllDirectionOffsets, y
  sta $f3; $f3 = ray delta
  lda $f0
  sta $f4; $f4 = current ray square
  lda #$00
  sta $f5; $f5 = candidate pinned piece type

__ai_eval_pin_ray_loop_0:
  lda $f4
  clc
  adc $f3
  sta $f4
  and #OFFBOARD_MASK
  beq __ai_eval_pin_onboard_0
  jmp __ai_eval_pin_next_dir_0

__ai_eval_pin_onboard_0:
  ldx $f4
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_eval_pin_ray_loop_0

  lda $f5
  bne __ai_eval_pin_have_candidate_0

; First occupied square must be a friendly non-king piece.
  lda Board88, x
  and #WHITE_COLOR
  cmp $f1
  bne __ai_eval_pin_next_dir_0
  stx $f6; $f6 = pinned piece square
  lda Board88, x
  and #$07
  cmp #KING_TYPE
  beq __ai_eval_pin_next_dir_0
  sta $f5
  jmp __ai_eval_pin_ray_loop_0

__ai_eval_pin_have_candidate_0:
; The next occupied square must be an enemy slider aligned with the ray.
  lda Board88, x
  and #WHITE_COLOR
  cmp $f1
  beq __ai_eval_pin_next_dir_0

  lda Board88, x
  and #$07
  cmp #QUEEN_TYPE
  beq __ai_eval_pin_apply_0
  sta $f7
  ldy $f2
  lda PinSliderTypes, y
  cmp $f7
  bne __ai_eval_pin_next_dir_0

__ai_eval_pin_apply_0:
  ldy $f5
  lda PinnedPiecePenalty_Lo, y
  ldx PinnedPiecePenalty_Hi, y
; Skip when the penalty is zero (king/empty types never reach here, but the
; original guarded on a zero table entry).
  sta $f8
  stx $f9
  ora $f9
  beq __ai_eval_pin_next_dir_0
  lda $f1
  bne __ai_eval_pin_white_piece_0
; Pinned side is black ($f1 == BLACK_COLOR == 0): add penalty (good for white).
  lda $f8
  ldx $f9
  jsr AddEval16
  jmp ApplyPinnedAttackPressure

__ai_eval_pin_white_piece_0:
  lda $f8
  ldx $f9
  jsr SubEval16
; Fall through to pinned attack pressure

;
; ApplyPinnedAttackPressure
; A pinned piece already has limited choices. If a pawn or knight is also
; attacking it, add pressure for the side doing the attacking.
; Inputs: $f1=pinned color, $f2=direction index, $f5=piece type, $f6=square.
; Clobbers: A, X, Y, $f0, $f2-$f5, $f7
;
ApplyPinnedAttackPressure:
  lda $f2
  sta $f7; Save direction index across attack probes.
  lda $f6
  sta $f0
  lda $f5
  sta $f2

  jsr IsPiecePawnAttacked
  bcs __ai_eval_pinned_extra_pressure_0
  jsr IsPieceKnightAttacked
  bcc __ai_eval_restore_pin_dir_0

__ai_eval_pinned_extra_pressure_0:
  lda #PINNED_ATTACKED_PENALTY
  ldx $f1
  beq __ai_eval_black_pinned_extra_0
  jsr SubtractEvalUnsigned
  jmp __ai_eval_restore_pin_dir_0

__ai_eval_black_pinned_extra_0:
  jsr AddEvalUnsigned

__ai_eval_restore_pin_dir_0:
  lda $f7
  sta $f2

__ai_eval_pin_next_dir_0:
  inc $f2
  lda $f2
  cmp #$08
  beq __ai_eval_pin_done_0
  jmp __ai_eval_pin_dir_loop_0
__ai_eval_pin_done_0:
  rts

;
; EvaluatePawnStructure
; Analyze pawn structure: doubled, isolated, passed pawns
; Adds/subtracts from EvalScore
; Clobbers: A, X, Y, $f0-$f7
;
EvaluatePawnStructure:
; Clear pawn counts
  ldx #$07
  lda #$00
__ai_eval_clear_pawn_counts_0:
  sta WhitePawnsPerFile, x
  sta BlackPawnsPerFile, x
  dex
  bpl __ai_eval_clear_pawn_counts_0

; Count pawns per file across the 64 valid 0x88 squares.
  ldx #$00; Board index

__ai_eval_count_pawns_loop_0:
; Get piece
  lda Board88, x
  and #$07; Get type
  cmp #$01; Is it a pawn?
  bne __ai_eval_count_next_0

; Get file (column)
  txa
  and #$07
  tay; Y = file (0-7)

; Check color
  lda Board88, x
  and #WHITE_COLOR
  bne __ai_eval_white_pawn_count_0

; Black pawn
  lda BlackPawnsPerFile, y
  clc
  adc #$01
  sta BlackPawnsPerFile, y
  jmp __ai_eval_count_next_0

__ai_eval_white_pawn_count_0:
  lda WhitePawnsPerFile, y
  clc
  adc #$01
  sta WhitePawnsPerFile, y

__ai_eval_count_next_0:
  inx
  txa
  and #$08
  beq __ai_eval_count_check_done_0
  txa
  clc
  adc #$08
  tax
__ai_eval_count_check_done_0:
  cpx #BOARD_SIZE
  bne __ai_eval_count_pawns_loop_0

;
; Check for doubled pawns (more than 1 pawn on same file)
;
  ldx #$07; File index

__ai_eval_doubled_loop_0:
; White doubled
  lda WhitePawnsPerFile, x
  cmp #$02
  bcc __ai_eval_no_white_doubled_0

; Penalty for white doubled pawns
  sec
  lda EvalScore
  sbc #DOUBLED_PAWN_PENALTY
  sta EvalScore
  lda EvalScore + 1
  sbc #$00
  sta EvalScore + 1

__ai_eval_no_white_doubled_0:
; Black doubled
  lda BlackPawnsPerFile, x
  cmp #$02
  bcc __ai_eval_no_black_doubled_0

; Bonus for white (black has weak pawns)
  clc
  lda EvalScore
  adc #DOUBLED_PAWN_PENALTY
  sta EvalScore
  lda EvalScore + 1
  adc #$00
  sta EvalScore + 1

__ai_eval_no_black_doubled_0:
  dex
  bpl __ai_eval_doubled_loop_0

;
; Check for isolated pawns (no friendly pawn on adjacent files)
;
  ldx #$07; File index

__ai_eval_isolated_loop_0:
; White isolated check
  lda WhitePawnsPerFile, x
  beq __ai_eval_check_black_iso_0; No white pawn on this file

; Check adjacent files
  cpx #$00
  beq __ai_eval_check_right_w_0; File a, only check right

; Check left file
  lda WhitePawnsPerFile - 1, x
  bne __ai_eval_no_white_iso_0; Has neighbor on left

__ai_eval_check_right_w_0:
  cpx #$07
  beq __ai_eval_white_is_iso_0; File h, already checked left, isolated

; Check right file
  lda WhitePawnsPerFile + 1, x
  bne __ai_eval_no_white_iso_0; Has neighbor on right

__ai_eval_white_is_iso_0:
; White isolated pawn - penalty
  sec
  lda EvalScore
  sbc #ISOLATED_PAWN_PENALTY
  sta EvalScore
  lda EvalScore + 1
  sbc #$00
  sta EvalScore + 1

__ai_eval_no_white_iso_0:
__ai_eval_check_black_iso_0:
; Black isolated check
  lda BlackPawnsPerFile, x
  beq __ai_eval_next_iso_file_0; No black pawn on this file

  cpx #$00
  beq __ai_eval_check_right_b_0

  lda BlackPawnsPerFile - 1, x
  bne __ai_eval_no_black_iso_0

__ai_eval_check_right_b_0:
  cpx #$07
  beq __ai_eval_black_is_iso_0

  lda BlackPawnsPerFile + 1, x
  bne __ai_eval_no_black_iso_0

__ai_eval_black_is_iso_0:
; Black isolated pawn - bonus for white
  clc
  lda EvalScore
  adc #ISOLATED_PAWN_PENALTY
  sta EvalScore
  lda EvalScore + 1
  adc #$00
  sta EvalScore + 1

__ai_eval_no_black_iso_0:
__ai_eval_next_iso_file_0:
  dex
  bpl __ai_eval_isolated_loop_0

;
; Check for passed pawns (no enemy pawns ahead or on adjacent files)
;
  ldx #$00; Board index

__ai_eval_passed_loop_0:
  lda Board88, x
  and #$07
  cmp #$01; Pawn?
  beq __ai_eval_passed_is_pawn_0
  jmp __ai_eval_passed_next_0

__ai_eval_passed_is_pawn_0:
; Get file and row
  stx $f0; Save board index
  txa
  and #$07
  sta $f1; $f1 = file (0-7)
  txa
  lsr
  lsr
  lsr
  lsr
  sta $f2; $f2 = row (0-7)

; Check pawn color
  lda Board88, x
  and #WHITE_COLOR
  beq __ai_eval_check_black_passed_0
  jmp __ai_eval_check_white_passed_0

__ai_eval_check_black_passed_0:
; Black pawn - check if passed (no white pawns ahead toward row 7)
  jsr CheckBlackPassed
  bcs __ai_eval_black_passed_continue_0
  jmp __ai_eval_passed_next_0

__ai_eval_black_passed_continue_0:
; Black passed pawn - penalty for white
; Bonus = PassedPawnBonus[7 - row] since black advances toward row 7
  lda #$07
  sec
  sbc $f2
  tay
  sec
  lda EvalScore
  sbc PassedPawnBonus_Lo, y
  sta EvalScore
  lda EvalScore + 1
  sbc PassedPawnBonus_Hi, y
  sta EvalScore + 1
  jsr CheckBlackConnectedPasser
  bcc __ai_eval_black_connected_done_0
  sec
  lda EvalScore
  sbc #CONNECTED_PASSER_BONUS
  sta EvalScore
  lda EvalScore + 1
  sbc #$00
  sta EvalScore + 1
__ai_eval_black_connected_done_0:
  jsr CheckBlackProtectedPasser
  bcc __ai_eval_black_protected_done_0
  sec
  lda EvalScore
  sbc #PROTECTED_PASSER_BONUS
  sta EvalScore
  lda EvalScore + 1
  sbc #$00
  sta EvalScore + 1
__ai_eval_black_protected_done_0:
  jsr CheckBlackBlockadedPasser
  bcc __ai_eval_black_blockaded_done_0
  clc
  lda EvalScore
  adc #BLOCKADED_PASSER_PENALTY
  sta EvalScore
  lda EvalScore + 1
  adc #$00
  sta EvalScore + 1
__ai_eval_black_blockaded_done_0:
  lda EvalEndgameFlag
  beq __ai_eval_black_passed_done_0
  jsr CheckBlackRookBehindPassed
  bcc __ai_eval_black_passed_done_0
  sec
  lda EvalScore
  sbc #ROOK_BEHIND_PASSER_BONUS
  sta EvalScore
  lda EvalScore + 1
  sbc #$00
  sta EvalScore + 1
__ai_eval_black_passed_done_0:
  jmp __ai_eval_passed_restore_0

__ai_eval_check_white_passed_0:
; White pawn - check if passed (no black pawns ahead toward row 0)
  jsr CheckWhitePassed
  bcc __ai_eval_passed_restore_0

; White passed pawn - bonus for white
; Bonus = PassedPawnBonus[row] since white advances toward row 0
  ldy $f2
  clc
  lda EvalScore
  adc PassedPawnBonus_Lo, y
  sta EvalScore
  lda EvalScore + 1
  adc PassedPawnBonus_Hi, y
  sta EvalScore + 1
  jsr CheckWhiteConnectedPasser
  bcc __ai_eval_white_connected_done_0
  clc
  lda EvalScore
  adc #CONNECTED_PASSER_BONUS
  sta EvalScore
  lda EvalScore + 1
  adc #$00
  sta EvalScore + 1
__ai_eval_white_connected_done_0:
  jsr CheckWhiteProtectedPasser
  bcc __ai_eval_white_protected_done_0
  clc
  lda EvalScore
  adc #PROTECTED_PASSER_BONUS
  sta EvalScore
  lda EvalScore + 1
  adc #$00
  sta EvalScore + 1
__ai_eval_white_protected_done_0:
  jsr CheckWhiteBlockadedPasser
  bcc __ai_eval_white_blockaded_done_0
  sec
  lda EvalScore
  sbc #BLOCKADED_PASSER_PENALTY
  sta EvalScore
  lda EvalScore + 1
  sbc #$00
  sta EvalScore + 1
__ai_eval_white_blockaded_done_0:
  lda EvalEndgameFlag
  beq __ai_eval_passed_restore_0
  jsr CheckWhiteRookBehindPassed
  bcc __ai_eval_passed_restore_0
  clc
  lda EvalScore
  adc #ROOK_BEHIND_PASSER_BONUS
  sta EvalScore
  lda EvalScore + 1
  adc #$00
  sta EvalScore + 1

__ai_eval_passed_restore_0:
  ldx $f0

__ai_eval_passed_next_0:
  inx
  txa
  and #$08
  beq __ai_eval_passed_check_done_0
  txa
  clc
  adc #$08
  tax
__ai_eval_passed_check_done_0:
  cpx #BOARD_SIZE
  beq __ai_eval_after_passed_pawns_0
  jmp __ai_eval_passed_loop_0

__ai_eval_after_passed_pawns_0:
  lda EvalEndgameFlag
  bne __ai_eval_passed_done_0
  jsr EvaluateRookFileActivity
__ai_eval_passed_done_0:
  rts

;
; EvaluateRookFileActivity
; In middlegames, rooks belong on files without friendly pawns. Open files get
; the full bonus; semi-open files still pressure enemy pawn structure.
; Pawn file counts must already be populated by EvaluatePawnStructure.
; Clobbers: A, X, Y, $f3-$f4
;
EvaluateRookFileActivity:
  ldx #$00

__ai_eval_rook_file_scan_loop_0:
  lda Board88, x
  cmp #WHITE_ROOK
  beq __ai_eval_white_rook_file_0
  cmp #BLACK_ROOK
  beq __ai_eval_black_rook_file_0
  jmp __ai_eval_rook_file_next_square_0

__ai_eval_white_rook_file_0:
  txa
  and #$07
  tay
  lda WhitePawnsPerFile, y
  bne __ai_eval_rook_file_next_square_0
  lda BlackPawnsPerFile, y
  bne __ai_eval_white_semi_open_file_0
  lda #ROOK_OPEN_FILE_BONUS
  jsr AddEvalUnsigned
  jmp __ai_eval_rook_file_next_square_0

__ai_eval_white_semi_open_file_0:
  lda #ROOK_SEMI_OPEN_FILE_BONUS
  jsr AddEvalUnsigned
  jmp __ai_eval_rook_file_next_square_0

__ai_eval_black_rook_file_0:
  txa
  and #$07
  tay
  lda BlackPawnsPerFile, y
  bne __ai_eval_rook_file_next_square_0
  lda WhitePawnsPerFile, y
  bne __ai_eval_black_semi_open_file_0
  lda #ROOK_OPEN_FILE_BONUS
  jsr SubtractEvalUnsigned
  jmp __ai_eval_rook_file_next_square_0

__ai_eval_black_semi_open_file_0:
  lda #ROOK_SEMI_OPEN_FILE_BONUS
  jsr SubtractEvalUnsigned

__ai_eval_rook_file_next_square_0:
  inx
  txa
  and #$08
  beq __ai_eval_rook_file_check_done_0
  txa
  clc
  adc #$08
  tax
__ai_eval_rook_file_check_done_0:
  cpx #BOARD_SIZE
  bne __ai_eval_rook_file_scan_loop_0
  rts

;
; CheckWhitePassed
; Check if white pawn at $f1 (file), $f2 (row) is passed
; Output: Carry set = passed, Carry clear = not passed
; Clobbers: A, Y, $f4
;
CheckWhitePassed:
; Check rows above (row-1 down to row 0) on file and adjacent files
  lda $f2
  sta $f4; Current row to check

__ai_eval_check_wp_row_0:
  dec $f4
  bmi __ai_eval_wp_is_passed_0; Checked all rows, it's passed

; Calculate 0x88 index: row * 16 + file
  lda $f4
  asl
  asl
  asl
  asl; row * 16
  ora $f1; + file
  tay; Y = square to check

; Check same file for black pawn
  lda Board88, y
  and #$07
  cmp #$01; Pawn?
  bne __ai_eval_check_wp_adj_0
  lda Board88, y
  and #WHITE_COLOR
  beq __ai_eval_wp_not_passed_0; Black pawn blocks

__ai_eval_check_wp_adj_0:
; Check left file if not file a
  lda $f1
  beq __ai_eval_check_wp_right_0
  dey; Left square
  lda Board88, y
  and #$07
  cmp #$01
  bne __ai_eval_check_wp_right_restore_0
  lda Board88, y
  and #WHITE_COLOR
  beq __ai_eval_wp_not_passed_0; Black pawn on left

__ai_eval_check_wp_right_restore_0:
  iny; Restore Y

__ai_eval_check_wp_right_0:
; Check right file if not file h
  lda $f1
  cmp #$07
  beq __ai_eval_check_wp_row_0
  iny; Right square
  lda Board88, y
  and #$07
  cmp #$01
  bne __ai_eval_check_wp_row_0
  lda Board88, y
  and #WHITE_COLOR
  beq __ai_eval_wp_not_passed_0; Black pawn on right

  jmp __ai_eval_check_wp_row_0

__ai_eval_wp_is_passed_0:
  sec
  rts

__ai_eval_wp_not_passed_0:
  clc
  rts

;
; CheckBlackPassed
; Check if black pawn at $f1 (file), $f2 (row) is passed
; Output: Carry set = passed, Carry clear = not passed
; Clobbers: A, Y, $f4
;
CheckBlackPassed:
; Check rows below (row+1 up to row 7) on file and adjacent files
  lda $f2
  sta $f4

__ai_eval_check_bp_row_0:
  inc $f4
  lda $f4
  cmp #$08
  beq __ai_eval_bp_is_passed_0; Checked all rows, it's passed

; Calculate 0x88 index
  lda $f4
  asl
  asl
  asl
  asl
  ora $f1
  tay

; Check same file for white pawn
  lda Board88, y
  and #$07
  cmp #$01
  bne __ai_eval_check_bp_adj_0
  lda Board88, y
  and #WHITE_COLOR
  bne __ai_eval_bp_not_passed_0; White pawn blocks

__ai_eval_check_bp_adj_0:
; Check left file
  lda $f1
  beq __ai_eval_check_bp_right_0
  dey
  lda Board88, y
  and #$07
  cmp #$01
  bne __ai_eval_check_bp_right_restore_0
  lda Board88, y
  and #WHITE_COLOR
  bne __ai_eval_bp_not_passed_0

__ai_eval_check_bp_right_restore_0:
  iny

__ai_eval_check_bp_right_0:
; Check right file
  lda $f1
  cmp #$07
  beq __ai_eval_check_bp_row_0
  iny
  lda Board88, y
  and #$07
  cmp #$01
  bne __ai_eval_check_bp_row_0
  lda Board88, y
  and #WHITE_COLOR
  bne __ai_eval_bp_not_passed_0

  jmp __ai_eval_check_bp_row_0

__ai_eval_bp_is_passed_0:
  sec
  rts

__ai_eval_bp_not_passed_0:
  clc
  rts

;
; CheckWhiteConnectedPasser / CheckBlackConnectedPasser
; A simple connected-passer signal: same-rank friendly pawn on an adjacent file.
; Input: $f0=square, $f1=file
; Output: Carry set = connected, carry clear = not connected
; Clobbers: A, Y
;
CheckWhiteConnectedPasser:
  lda $f1
  beq __ai_eval_white_connected_right_0
  ldy $f0
  dey
  lda Board88, y
  cmp #WHITE_PAWN
  beq __ai_eval_connected_passer_yes_0

__ai_eval_white_connected_right_0:
  lda $f1
  cmp #$07
  beq __ai_eval_connected_passer_no_0
  ldy $f0
  iny
  lda Board88, y
  cmp #WHITE_PAWN
  beq __ai_eval_connected_passer_yes_0
  jmp __ai_eval_connected_passer_no_0

CheckBlackConnectedPasser:
  lda $f1
  beq __ai_eval_black_connected_right_0
  ldy $f0
  dey
  lda Board88, y
  cmp #BLACK_PAWN
  beq __ai_eval_connected_passer_yes_0

__ai_eval_black_connected_right_0:
  lda $f1
  cmp #$07
  beq __ai_eval_connected_passer_no_0
  ldy $f0
  iny
  lda Board88, y
  cmp #BLACK_PAWN
  beq __ai_eval_connected_passer_yes_0

__ai_eval_connected_passer_no_0:
  clc
  rts

__ai_eval_connected_passer_yes_0:
  sec
  rts

;
; CheckWhiteProtectedPasser / CheckBlackProtectedPasser
; A protected passer has a friendly pawn guarding it from behind.
; Input: $f0=square
; Output: Carry set = protected, carry clear = not protected
; Clobbers: A, Y, $f4
;
CheckWhiteProtectedPasser:
  lda $f0
  clc
  adc #$0f
  sta $f4
  and #OFFBOARD_MASK
  bne __ai_eval_white_protected_right_0
  ldy $f4
  lda Board88, y
  cmp #WHITE_PAWN
  beq __ai_eval_protected_passer_yes_0

__ai_eval_white_protected_right_0:
  lda $f0
  clc
  adc #$11
  sta $f4
  and #OFFBOARD_MASK
  bne __ai_eval_protected_passer_no_0
  ldy $f4
  lda Board88, y
  cmp #WHITE_PAWN
  beq __ai_eval_protected_passer_yes_0
  jmp __ai_eval_protected_passer_no_0

CheckBlackProtectedPasser:
  lda $f0
  sec
  sbc #$0f
  sta $f4
  and #OFFBOARD_MASK
  bne __ai_eval_black_protected_right_0
  ldy $f4
  lda Board88, y
  cmp #BLACK_PAWN
  beq __ai_eval_protected_passer_yes_0

__ai_eval_black_protected_right_0:
  lda $f0
  sec
  sbc #$11
  sta $f4
  and #OFFBOARD_MASK
  bne __ai_eval_protected_passer_no_0
  ldy $f4
  lda Board88, y
  cmp #BLACK_PAWN
  beq __ai_eval_protected_passer_yes_0

__ai_eval_protected_passer_no_0:
  clc
  rts

__ai_eval_protected_passer_yes_0:
  sec
  rts

;
; CheckWhiteBlockadedPasser / CheckBlackBlockadedPasser
; Output: Carry set if the square directly ahead of the passer is occupied.
; Clobbers: A, Y, $f4
;
CheckWhiteBlockadedPasser:
  lda $f0
  sec
  sbc #$10
  sta $f4
  and #OFFBOARD_MASK
  bne __ai_eval_blockaded_passer_no_0
  ldy $f4
  lda Board88, y
  cmp #EMPTY_PIECE
  bne __ai_eval_blockaded_passer_yes_0
  jmp __ai_eval_blockaded_passer_no_0

CheckBlackBlockadedPasser:
  lda $f0
  clc
  adc #$10
  sta $f4
  and #OFFBOARD_MASK
  bne __ai_eval_blockaded_passer_no_0
  ldy $f4
  lda Board88, y
  cmp #EMPTY_PIECE
  bne __ai_eval_blockaded_passer_yes_0

__ai_eval_blockaded_passer_no_0:
  clc
  rts

__ai_eval_blockaded_passer_yes_0:
  sec
  rts

;
; CheckWhiteRookBehindPassed
; For a white passed pawn at $f1=file, $f2=row, look behind it toward row 7.
; Output: Carry set = friendly rook behind passer
; Clobbers: A, Y, $f4
;
CheckWhiteRookBehindPassed:
  lda $f2
  sta $f4

__ai_eval_white_rook_row_0:
  inc $f4
  lda $f4
  cmp #$08
  beq __ai_eval_no_white_rook_0

  lda $f4
  asl
  asl
  asl
  asl
  ora $f1
  tay
  lda Board88, y
  cmp #WHITE_ROOK
  bne __ai_eval_white_rook_row_0

__ai_eval_has_white_rook_0:
  sec
  rts

__ai_eval_no_white_rook_0:
  clc
  rts

;
; CheckBlackRookBehindPassed
; For a black passed pawn at $f1=file, $f2=row, look behind it toward row 0.
; Output: Carry set = friendly rook behind passer
; Clobbers: A, Y, $f4
;
CheckBlackRookBehindPassed:
  lda $f2
  sta $f4

__ai_eval_black_rook_row_0:
  dec $f4
  bmi __ai_eval_no_black_rook_0

  lda $f4
  asl
  asl
  asl
  asl
  ora $f1
  tay
  lda Board88, y
  cmp #BLACK_ROOK
  bne __ai_eval_black_rook_row_0

__ai_eval_has_black_rook_0:
  sec
  rts

__ai_eval_no_black_rook_0:
  clc
  rts

;
; EvaluateEndgame
; In simple endings, active centralized kings are assets, not liabilities.
; Adds/subtracts compact king activity scores from EvalScore.
; Clobbers: A, $f0-$f3
;
EvaluateEndgame:
  lda whitekingsq
  jsr EvaluateEndgameKingActivity
; A = activity lo, X = activity hi (good for white).
  jsr AddEval16

  lda blackkingsq
  jsr EvaluateEndgameKingActivity
; A = activity lo, X = activity hi (good for black = bad for white).
  jsr SubEval16

  lda EvalPawnCount
  beq __ai_eval_done_5
  lda EvalNonPawnCount
  beq __ai_eval_done_5
  jsr EvaluateEndgameRookActivity
__ai_eval_done_5:
  rts

;
; EvaluateEndgameRookActivity
; In single-piece pawn endings, a rook on a file without friendly pawns is
; often worth more than another quiet king step. Pawn file counts must already
; be populated by EvaluatePawnStructure.
; Clobbers: A, X, Y, $f3-$f4
;
EvaluateEndgameRookActivity:
  ldx #$00

__ai_eval_scan_loop_1:
  lda Board88, x
  cmp #WHITE_ROOK
  beq __ai_eval_white_rook_0
  cmp #BLACK_ROOK
  beq __ai_eval_black_rook_0
  jmp __ai_eval_next_square_1

__ai_eval_white_rook_0:
  txa
  and #$07
  sta $f4
  tay
  lda WhitePawnsPerFile, y
  bne __ai_eval_next_square_1
  stx $f5; preserve board scan index across the 16-bit add (AddEval16 reads X)
  lda #<ENDGAME_ROOK_OPEN_FILE_BONUS
  ldx #>ENDGAME_ROOK_OPEN_FILE_BONUS
  jsr AddEval16
  ldx $f5
  lda blackkingsq
  and #$07
  sec
  sbc $f4
  bcs __ai_eval_white_distance_ready_0
  eor #$ff
  clc
  adc #$01
__ai_eval_white_distance_ready_0:
  cmp #$02
  bcs __ai_eval_next_square_1
  lda #ENDGAME_ROOK_KING_CUTOFF_BONUS
  jsr AddEvalUnsigned
  jmp __ai_eval_next_square_1

__ai_eval_black_rook_0:
  txa
  and #$07
  sta $f4
  tay
  lda BlackPawnsPerFile, y
  bne __ai_eval_next_square_1
  stx $f5; preserve board scan index across the 16-bit sub (SubEval16 reads X)
  lda #<ENDGAME_ROOK_OPEN_FILE_BONUS
  ldx #>ENDGAME_ROOK_OPEN_FILE_BONUS
  jsr SubEval16
  ldx $f5
  lda whitekingsq
  and #$07
  sec
  sbc $f4
  bcs __ai_eval_black_distance_ready_0
  eor #$ff
  clc
  adc #$01
__ai_eval_black_distance_ready_0:
  cmp #$02
  bcs __ai_eval_next_square_1
  lda #ENDGAME_ROOK_KING_CUTOFF_BONUS
  jsr SubtractEvalUnsigned

__ai_eval_next_square_1:
  inx
  txa
  and #$08
  beq __ai_eval_scan_check_done_1
  txa
  clc
  adc #$08
  tax
__ai_eval_scan_check_done_1:
  cpx #BOARD_SIZE
  bne __ai_eval_scan_loop_1
  rts

;
; EvaluateEndgameKingActivity
; Input: A = king square (0x88)
; Output: A = unsigned activity bonus low byte, X = high byte (Part B: the
;         bonus can reach 600 after the x10 rescale, so it is now 16-bit).
; Clobbers: $f0-$f1
;
EvaluateEndgameKingActivity:
  sta $f0
  lda #$00
  sta $f1; $f1 = activity accumulator low byte
  sta $f7; $f7 = activity accumulator high byte

  lda $f0
  and #$07; file
  cmp #$02
  bcc __ai_eval_activity_file_done_0
  cmp #$06
  bcs __ai_eval_activity_file_done_0
  clc
  lda $f1
  adc #<ENDGAME_KING_ACTIVITY_BONUS
  sta $f1
  lda $f7
  adc #>ENDGAME_KING_ACTIVITY_BONUS
  sta $f7

__ai_eval_activity_file_done_0:
  lda $f0
  lsr
  lsr
  lsr
  lsr; row
  cmp #$02
  bcc __ai_eval_activity_done_0
  cmp #$06
  bcs __ai_eval_activity_done_0
  clc
  lda $f1
  adc #<ENDGAME_KING_ACTIVITY_BONUS
  sta $f1
  lda $f7
  adc #>ENDGAME_KING_ACTIVITY_BONUS
  sta $f7

__ai_eval_activity_done_0:
  ldx $f7
  lda $f1
  rts

EvaluateKingSafety:
; Part B centipawn rescale: EvaluateSingleKingSafety is unchanged and still
; returns a signed *byte* (pre-rescale scale, wraparound included). Multiply that
; byte by 10 into a 16-bit signed value, then add (white) / subtract (black) the
; full 16-bit product, so the contribution is exactly (old byte) x 10 and the
; baseline -- overflow artifact and all -- is reproduced move-identically.
; Evaluate white king safety
  lda whitekingsq
  jsr EvaluateSingleKingSafety
  jsr KingSafetyByteX10; A = lo, X = hi of (signed byte) * 10
  sta $f0
  stx $f7
  clc
  lda EvalScore
  adc $f0
  sta EvalScore
  lda EvalScore + 1
  adc $f7
  sta EvalScore + 1

; Evaluate black king safety
  lda blackkingsq
  jsr EvaluateSingleKingSafety
  jsr KingSafetyByteX10; A = lo, X = hi of (signed byte) * 10
  sta $f0
  stx $f7
  sec
  lda EvalScore
  sbc $f0
  sta EvalScore
  lda EvalScore + 1
  sbc $f7
  sta EvalScore + 1

  rts

;
; KingSafetyByteX10
; Multiply a SIGNED byte (A) by 10, returning a 16-bit signed result in A (low)
; and X (high). Used to scale the pre-rescale king-safety byte up to centipawns.
; n*10 fits in [-1280, 1270]. Implemented as sign-extend to 16-bit, then *10 via
; *8 + *2 with 16-bit shifts. Clobbers: A, X, Y, $f5, $f6.
;
KingSafetyByteX10:
  ldx #$00
  cmp #$80
  bcc __ai_ksafe_x10_pos_0
  ldx #$ff; sign-extend negative byte
__ai_ksafe_x10_pos_0:
  sta $f5; $f5/$f6 = sign-extended 16-bit value n
  stx $f6
; t = n * 2
  asl $f5
  rol $f6
; save t in Y-less temps: reuse A/X via stack-free copy
  lda $f5
  ldy $f6; Y = (n*2) high
  pha; (n*2) low on stack
; t = t * 4  -> n * 8 (continue shifting $f5/$f6)
  asl $f5
  rol $f6
  asl $f5
  rol $f6; $f5/$f6 = n * 8
; result = n*8 + n*2
  pla; A = (n*2) low
  clc
  adc $f5
  sta $f5
  tya; (n*2) high
  adc $f6
  sta $f6; $f5/$f6 = n*10
  lda $f5
  ldx $f6
  rts

;
; EvaluateSingleKingSafety
; Input: A = king square (0x88)
; Output: A = signed safety score (higher = safer)
; Clobbers: X, Y, $f0-$f4
;
EvaluateSingleKingSafety:
  sta $f0; $f0 = king square
  lda #$00
  sta $f1; $f1 = safety score accumulator

; Get file and row
  lda $f0
  and #$07
  sta $f2; $f2 = file (0-7)
  lda $f0
  lsr
  lsr
  lsr
  lsr
  sta $f3; $f3 = row (0-7)

; Determine if this is white or black king
  lda $f0
  cmp whitekingsq
  beq __ai_eval_is_white_0
  jmp EvalBlackKingSafety

__ai_eval_is_white_0:
; Fall through to white king safety

;
; EvalWhiteKingSafety - Helper for white king safety
; Input: $f0=king square, $f1=score, $f2=file, $f3=row
; Output: A = safety score
; Clobbers: X, Y
;
EvalWhiteKingSafety:
; Check if castled (on g1 or c1 = row 7, file 6 or 2)
  lda $f3
  cmp #$07; Row 7 (rank 1)?
  beq __ai_eval_check_castled_file_0
  jmp __ai_eval_white_not_castled_0

__ai_eval_check_castled_file_0:
  lda $f2
  cmp #$06; File g (kingside)?
  beq __ai_eval_white_castled_0
  cmp #$02; File c (queenside)?
  beq __ai_eval_white_castled_0
  jmp __ai_eval_white_not_castled_0

__ai_eval_white_castled_0:
; King is castled - bonus
  clc
  lda $f1
  adc #CASTLED_BONUS
  sta $f1

; Check pawn shield (pawns in front of king)
; For kingside: check f2, g2, h2 squares
; For queenside: check a2, b2, c2 squares
  lda $f2
  cmp #$06
  bne __ai_eval_white_qs_shield_0

; Kingside: check $65 (f2), $66 (g2), $67 (h2)
  lda Board88 + $65
  and #$07
  cmp #$01; Pawn?
  bne __ai_eval_ws1_0
  lda Board88 + $65
  and #WHITE_COLOR
  beq __ai_eval_ws1_0
  clc
  lda $f1
  adc #PAWN_SHIELD_BONUS
  sta $f1
__ai_eval_ws1_0:
  lda Board88 + $66
  and #$07
  cmp #$01
  bne __ai_eval_ws2_0
  lda Board88 + $66
  and #WHITE_COLOR
  beq __ai_eval_ws2_0
  clc
  lda $f1
  adc #PAWN_SHIELD_BONUS
  sta $f1
__ai_eval_ws2_0:
  lda Board88 + $67
  and #$07
  cmp #$01
  bne __ai_eval_white_done_0
  lda Board88 + $67
  and #WHITE_COLOR
  beq __ai_eval_white_done_0
  clc
  lda $f1
  adc #PAWN_SHIELD_BONUS
  sta $f1
  jmp __ai_eval_white_done_0

__ai_eval_white_qs_shield_0:
; Queenside: check $60 (a2), $61 (b2), $62 (c2)
  lda Board88 + $60
  and #$07
  cmp #$01
  bne __ai_eval_wqs1_0
  lda Board88 + $60
  and #WHITE_COLOR
  beq __ai_eval_wqs1_0
  clc
  lda $f1
  adc #PAWN_SHIELD_BONUS
  sta $f1
__ai_eval_wqs1_0:
  lda Board88 + $61
  and #$07
  cmp #$01
  bne __ai_eval_wqs2_0
  lda Board88 + $61
  and #WHITE_COLOR
  beq __ai_eval_wqs2_0
  clc
  lda $f1
  adc #PAWN_SHIELD_BONUS
  sta $f1
__ai_eval_wqs2_0:
  lda Board88 + $62
  and #$07
  cmp #$01
  bne __ai_eval_white_done_0
  lda Board88 + $62
  and #WHITE_COLOR
  beq __ai_eval_white_done_0
  clc
  lda $f1
  adc #PAWN_SHIELD_BONUS
  sta $f1
  jmp __ai_eval_white_done_0

__ai_eval_white_not_castled_0:
; King not castled - check if in center (files d-e)
  lda $f2
  cmp #$03; File d?
  beq __ai_eval_white_center_penalty_0
  cmp #$04; File e?
  bne __ai_eval_white_done_0

__ai_eval_white_center_penalty_0:
; King in center - penalty
  sec
  lda $f1
  sbc #KING_CENTER_PENALTY
  sta $f1

__ai_eval_white_done_0:
; A king that has marched up the board in the middlegame is the single most
; common way our Stockfish-ladder games end in mating attacks. Penalize every
; rank past the second, hardest the farther it walks. This routine only runs
; in the middlegame, so endgame king activity is unaffected; castled kings on
; rank 1 are a no-op.
  lda $f3
  cmp #$06
  bcs __ai_eval_white_march_done_0
  lda #$06
  sec
  sbc $f3; ranks advanced past rank 2 (1..6)
  asl
  asl
  asl; times KING_MARCH_STEP (8)
  clc
  adc #KING_MARCH_BASE
  sta $f4
  sec
  lda $f1
  sbc $f4
  sta $f1
__ai_eval_white_march_done_0:
  jsr ApplyWhiteKingFileExposure
  lda #BLACKS_TURN
  jsr ApplyKingZonePressure
  lda $f1; Return safety score
  rts

;
; EvalBlackKingSafety - Helper for black king safety
; Input: $f0=king square, $f1=score, $f2=file, $f3=row
; Output: A = safety score
; Clobbers: X, Y
;
EvalBlackKingSafety:
; Check if castled (on g8 or c8 = row 0, file 6 or 2)
  lda $f3
  cmp #$00; Row 0 (rank 8)?
  beq __ai_eval_check_black_castled_file_0
  jmp __ai_eval_black_not_castled_0

__ai_eval_check_black_castled_file_0:
  lda $f2
  cmp #$06; File g?
  beq __ai_eval_black_castled_0
  cmp #$02; File c?
  beq __ai_eval_black_castled_0
  jmp __ai_eval_black_not_castled_0

__ai_eval_black_castled_0:
; King is castled - bonus
  clc
  lda $f1
  adc #CASTLED_BONUS
  sta $f1

; Check pawn shield (pawns in front of king)
; For kingside: check f7, g7, h7 squares
; For queenside: check a7, b7, c7 squares
  lda $f2
  cmp #$06
  bne __ai_eval_black_qs_shield_0

; Kingside: check $15 (f7), $16 (g7), $17 (h7)
  lda Board88 + $15
  and #$07
  cmp #$01
  bne __ai_eval_bs1_0
  lda Board88 + $15
  and #WHITE_COLOR
  bne __ai_eval_bs1_0; Must be BLACK pawn
  clc
  lda $f1
  adc #PAWN_SHIELD_BONUS
  sta $f1
__ai_eval_bs1_0:
  lda Board88 + $16
  and #$07
  cmp #$01
  bne __ai_eval_bs2_0
  lda Board88 + $16
  and #WHITE_COLOR
  bne __ai_eval_bs2_0
  clc
  lda $f1
  adc #PAWN_SHIELD_BONUS
  sta $f1
__ai_eval_bs2_0:
  lda Board88 + $17
  and #$07
  cmp #$01
  bne __ai_eval_black_done_0
  lda Board88 + $17
  and #WHITE_COLOR
  bne __ai_eval_black_done_0
  clc
  lda $f1
  adc #PAWN_SHIELD_BONUS
  sta $f1
  jmp __ai_eval_black_done_0

__ai_eval_black_qs_shield_0:
; Queenside: check $10 (a7), $11 (b7), $12 (c7)
  lda Board88 + $10
  and #$07
  cmp #$01
  bne __ai_eval_bqs1_0
  lda Board88 + $10
  and #WHITE_COLOR
  bne __ai_eval_bqs1_0
  clc
  lda $f1
  adc #PAWN_SHIELD_BONUS
  sta $f1
__ai_eval_bqs1_0:
  lda Board88 + $11
  and #$07
  cmp #$01
  bne __ai_eval_bqs2_0
  lda Board88 + $11
  and #WHITE_COLOR
  bne __ai_eval_bqs2_0
  clc
  lda $f1
  adc #PAWN_SHIELD_BONUS
  sta $f1
__ai_eval_bqs2_0:
  lda Board88 + $12
  and #$07
  cmp #$01
  bne __ai_eval_black_done_0
  lda Board88 + $12
  and #WHITE_COLOR
  bne __ai_eval_black_done_0
  clc
  lda $f1
  adc #PAWN_SHIELD_BONUS
  sta $f1
  jmp __ai_eval_black_done_0

__ai_eval_black_not_castled_0:
; King not castled - check if in center
  lda $f2
  cmp #$03
  beq __ai_eval_black_center_penalty_0
  cmp #$04
  bne __ai_eval_black_done_0

__ai_eval_black_center_penalty_0:
  sec
  lda $f1
  sbc #KING_CENTER_PENALTY
  sta $f1

__ai_eval_black_done_0:
; Mirror of the white king-march penalty: black ranks 8-7 are rows 0-1, so
; anything at row 2 or beyond has wandered into the middlegame crossfire.
  lda $f3
  cmp #$02
  bcc __ai_eval_black_march_done_0
  sec
  sbc #$01; ranks advanced past rank 7 (1..6)
  asl
  asl
  asl; times KING_MARCH_STEP (8)
  clc
  adc #KING_MARCH_BASE
  sta $f4
  sec
  lda $f1
  sbc $f4
  sta $f1
__ai_eval_black_march_done_0:
  jsr ApplyBlackKingFileExposure
  lda #WHITE_COLOR
  jsr ApplyKingZonePressure
  lda $f1; Return safety score
  rts

;
; ApplyWhiteKingFileExposure / ApplyBlackKingFileExposure
; Penalize missing friendly pawns on files adjacent to the king. A fully open
; file near the king is worse than a semi-open file with an enemy pawn still
; present. Pawn file counts are valid only when EvalPawnCount is nonzero.
; Inputs: $f1=safety score, $f2=king file.
; Clobbers: A, Y, $f4
;
ApplyWhiteKingFileExposure:
  lda EvalPawnCount
  beq __ai_eval_white_exposure_done_0

  lda $f2
  beq __ai_eval_white_exposure_file_0
  sec
  sbc #$01
  jsr PenalizeWhiteKingFile

__ai_eval_white_exposure_file_0:
  lda $f2
  jsr PenalizeWhiteKingFile

  lda $f2
  cmp #$07
  beq __ai_eval_white_exposure_done_0
  clc
  adc #$01
  jsr PenalizeWhiteKingFile

__ai_eval_white_exposure_done_0:
  rts

ApplyBlackKingFileExposure:
  lda EvalPawnCount
  beq __ai_eval_black_exposure_done_0

  lda $f2
  beq __ai_eval_black_exposure_file_0
  sec
  sbc #$01
  jsr PenalizeBlackKingFile

__ai_eval_black_exposure_file_0:
  lda $f2
  jsr PenalizeBlackKingFile

  lda $f2
  cmp #$07
  beq __ai_eval_black_exposure_done_0
  clc
  adc #$01
  jsr PenalizeBlackKingFile

__ai_eval_black_exposure_done_0:
  rts

;
; ApplyKingZonePressure
; Penalize enemy sliders and knights aimed at the king zone. This is a compact
; attacker count; it avoids repeated full attack-detection calls inside eval.
; Inputs: $f0=king square, $f1=safety score, A=attacker color
; Clobbers: A, X, Y, $f2-$f7
;
ApplyKingZonePressure:
  sta $f5; attacking side
  lda #$00
  sta $f7; direction index

__ai_eval_king_zone_ray_loop_0:
  ldx $f7
  lda $f0
  sta $f6; ray square

__ai_eval_king_zone_ray_step_0:
  ldx $f7
  lda $f6
  clc
  adc AllDirectionOffsets, x
  sta $f6
  and #OFFBOARD_MASK
  bne __ai_eval_king_zone_next_ray_0

  ldy $f6
  lda Board88, y
  cmp #EMPTY_PIECE
  beq __ai_eval_king_zone_ray_step_0
  sta $f4
  and #WHITE_COLOR
  cmp $f5
  bne __ai_eval_king_zone_next_ray_0

  lda $f4
  and #$07
  sta $f2
  cmp #QUEEN_TYPE
  beq __ai_eval_king_zone_penalize_ray_0

  lda $f7
  cmp #$01
  beq __ai_eval_king_zone_orthogonal_0
  cmp #$03
  beq __ai_eval_king_zone_orthogonal_0
  cmp #$04
  beq __ai_eval_king_zone_orthogonal_0
  cmp #$06
  beq __ai_eval_king_zone_orthogonal_0

  lda $f2
  cmp #BISHOP_TYPE
  beq __ai_eval_king_zone_penalize_ray_0
  jmp __ai_eval_king_zone_next_ray_0

__ai_eval_king_zone_orthogonal_0:
  lda $f2
  cmp #ROOK_TYPE
  bne __ai_eval_king_zone_next_ray_0

__ai_eval_king_zone_penalize_ray_0:
  jsr SubtractKingZonePressure

__ai_eval_king_zone_next_ray_0:
  inc $f7
  lda $f7
  cmp #AllDirectionOffsetsEnd - AllDirectionOffsets
  bne __ai_eval_king_zone_ray_loop_0

  lda #$00
  sta $f7; knight offset index

__ai_eval_king_zone_knight_loop_0:
  lda $f0
  clc
  ldx $f7
  adc KnightOffsets, x
  sta $f6
  and #OFFBOARD_MASK
  bne __ai_eval_king_zone_next_knight_0
  ldy $f6
  lda Board88, y
  cmp #EMPTY_PIECE
  beq __ai_eval_king_zone_next_knight_0
  sta $f4
  and #WHITE_COLOR
  cmp $f5
  bne __ai_eval_king_zone_next_knight_0
  lda $f4
  and #$07
  cmp #KNIGHT_TYPE
  bne __ai_eval_king_zone_next_knight_0
  jsr SubtractKingZonePressure

__ai_eval_king_zone_next_knight_0:
  inc $f7
  lda $f7
  cmp #KnightOffsetsEnd - KnightOffsets
  bne __ai_eval_king_zone_knight_loop_0
  rts

SubtractKingZonePressure:
  sec
  lda $f1
  sbc #KING_ZONE_ATTACK_PENALTY
  sta $f1
  rts

PenalizeWhiteKingFile:
  tay
  lda WhitePawnsPerFile, y
  bne __ai_eval_king_file_done_0
  lda BlackPawnsPerFile, y
  bne __ai_eval_king_file_semi_open_0
  lda #OPEN_FILE_PENALTY
  jmp SubtractKingSafety

PenalizeBlackKingFile:
  tay
  lda BlackPawnsPerFile, y
  bne __ai_eval_king_file_done_0
  lda WhitePawnsPerFile, y
  bne __ai_eval_king_file_semi_open_0
  lda #OPEN_FILE_PENALTY
  jmp SubtractKingSafety

__ai_eval_king_file_semi_open_0:
  lda #SEMI_OPEN_FILE_PENALTY

SubtractKingSafety:
  sta $f4
  sec
  lda $f1
  sbc $f4
  sta $f1

__ai_eval_king_file_done_0:
  rts
