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
PAWN_VALUE = 10
KNIGHT_VALUE = 32
BISHOP_VALUE = 33
ROOK_VALUE = 50
QUEEN_VALUE = 90
KING_VALUE = 0; Kings not counted in material

;
; Tactical pressure constants
; Penalize pieces currently attacked by enemy pawns. A pawn fork/threat is
; cheap to detect and catches many otherwise invisible one-ply tactics.
;
PAWN_ATTACK_MINOR_PENALTY = 60
PAWN_ATTACK_ROOK_PENALTY = 60
PAWN_ATTACK_QUEEN_PENALTY = 85
QUEEN_ATTACK_MINOR_PENALTY = 75
KNIGHT_ATTACK_QUEEN_PENALTY = 35

;
; Pawn Structure Evaluation Constants
;
DOUBLED_PAWN_PENALTY = 15
ISOLATED_PAWN_PENALTY = 20
PASSED_PAWN_BONUS_BASE = 20
ROOK_BEHIND_PASSER_BONUS = 20
ENDGAME_NONPAWN_LIMIT = 1; K+P and single-piece endings
ENDGAME_KING_ACTIVITY_BONUS = 30
ENDGAME_ROOK_OPEN_FILE_BONUS = 60
ENDGAME_ROOK_KING_CUTOFF_BONUS = 25

;
; King Safety Evaluation Constants
;
CASTLED_BONUS = 30; Bonus for being on castled squares
PAWN_SHIELD_BONUS = 10; Bonus per pawn in shield
OPEN_FILE_PENALTY = 25; Penalty for open file near king
KING_CENTER_PENALTY = 30; Penalty for king in center in middlegame

; Passed pawn bonus by rank (row 0 = rank 8, row 7 = rank 1)
; White pawns advance toward row 0, black toward row 7
PassedPawnBonus:
  .byte 40, 30, 25, 20, 15, 10, 0, 0; Rank 8 unused; rank 7=30 down to rank 3=10

;
; Piece value lookup table
; Indexed by (piece & $07) - piece type
; Index 0 = empty, 1-6 = pawn through king
;
PieceValues:
  .byte 0; 0: empty/invalid
  .byte PAWN_VALUE; 1: pawn
  .byte KNIGHT_VALUE; 2: knight
  .byte BISHOP_VALUE; 3: bishop
  .byte ROOK_VALUE; 4: rook
  .byte QUEEN_VALUE; 5: queen
  .byte KING_VALUE; 6: king

PawnAttackPenalty:
  .byte 0; 0: empty/invalid
  .byte 0; 1: pawn
  .byte PAWN_ATTACK_MINOR_PENALTY; 2: knight
  .byte PAWN_ATTACK_MINOR_PENALTY; 3: bishop
  .byte PAWN_ATTACK_ROOK_PENALTY; 4: rook
  .byte PAWN_ATTACK_QUEEN_PENALTY; 5: queen
  .byte 0; 6: king

QueenAttackPenalty:
  .byte 0; 0: empty/invalid
  .byte 0; 1: pawn
  .byte QUEEN_ATTACK_MINOR_PENALTY; 2: knight
  .byte QUEEN_ATTACK_MINOR_PENALTY; 3: bishop
  .byte 0; 4: rook
  .byte 0; 5: queen
  .byte 0; 6: king

;
; Evaluation result (16-bit signed)
; Positive = white advantage, negative = black advantage
;
EvalScore:
  .word $0000
EvalNonPawnCount:
  .byte $00
EvalPawnCount:
  .byte $00
EvalQueenCount:
  .byte $00
EvalEndgameFlag:
  .byte $00

;
; Pawn count storage per file (0-7)
;
WhitePawnsPerFile: .res 8, $00
BlackPawnsPerFile: .res 8, $00

;
; Evaluate material balance
; Loops through board, sums white pieces, subtracts black pieces
; Result in EvalScore (16-bit signed)
; Clobbers: A, X, Y
;
EvaluateMaterial:
; Clear score
  lda #$00
  sta EvalScore
  sta EvalScore + 1

; Loop through the 64 valid 0x88 squares, skipping offboard gaps.
  ldx #$00

__ai_eval_squareloop_0:
; Get piece at this square
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_eval_nextsquare_0

; Save square index
  stx $f7

; Extract piece type (lower 3 bits)
  pha; Save full piece value
  and #$07; Get type (1-6)
  tay; Y = piece type index
  lda PieceValues, y; A = piece value
  sta $f8; Save value

; Check piece color
  pla; Restore piece value
  and #WHITE_COLOR; Check high bit
  beq __ai_eval_blackpiece_0

; White piece - add to score
  clc
  lda EvalScore
  adc $f8
  sta EvalScore
  lda EvalScore + 1
  adc #$00; Add carry
  sta EvalScore + 1
  jmp __ai_eval_restorex_0

__ai_eval_blackpiece_0:
; Black piece - subtract from score
  sec
  lda EvalScore
  sbc $f8
  sta EvalScore
  lda EvalScore + 1
  sbc #$00; Subtract borrow
  sta EvalScore + 1

__ai_eval_restorex_0:
; Restore square index
  ldx $f7

__ai_eval_nextsquare_0:
  inx
  txa
  and #$08; Past file h in 0x88 layout?
  beq __ai_eval_mat_check_done_0
  txa
  clc
  adc #$08; Skip offboard gap to next rank
  tax
__ai_eval_mat_check_done_0:
  cpx #BOARD_SIZE; Done all 128 bytes?
  bne __ai_eval_squareloop_0

  rts

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
  sta EvalEndgameFlag

  ldx #$00; Board index

PstLoop:
; Get piece at square
  lda Board88, x
  cmp #EMPTY_PIECE
  bne __ai_eval_pst_piece_present_0
  jmp PstNext

__ai_eval_pst_piece_present_0:

; Save board index
  stx $f0

; Get piece type and color
  pha
  and #WHITE_COLOR
  sta $f1; $f1 = color ($80=white, $00=black)
  pla
  and #$07; Piece type (1-6)
  sta $f2; $f2 = piece type
  cmp #PAWN_TYPE
  bne __ai_eval_piece_phase_not_pawn_0
  inc EvalPawnCount
  jmp __ai_eval_piece_phase_done_0
__ai_eval_piece_phase_not_pawn_0:
  cmp #KING_TYPE
  beq __ai_eval_piece_phase_done_0
  inc EvalNonPawnCount
  cmp #QUEEN_TYPE
  bne __ai_eval_piece_phase_not_queen_0
  inc EvalQueenCount
__ai_eval_piece_phase_not_queen_0:
  jsr EvaluatePawnPressure
  jsr EvaluateQueenPressure
  jsr EvaluateMinorPressure
  jsr EvaluateMobility
__ai_eval_piece_phase_done_0:

; Add material value for this piece.
  ldy $f2
  lda PieceValues, y
  sta $f8
  lda $f1
  beq __ai_eval_pst_black_material_0

  clc
  lda EvalScore
  adc $f8
  sta EvalScore
  lda EvalScore + 1
  adc #$00
  sta EvalScore + 1
  jmp __ai_eval_pst_material_done_0

__ai_eval_pst_black_material_0:
  sec
  lda EvalScore
  sbc $f8
  sta EvalScore
  lda EvalScore + 1
  sbc #$00
  sta EvalScore + 1

__ai_eval_pst_material_done_0:
; Get PST pointer for this piece type
  ldy $f2
  lda PST_Table_Lo, y
  sta $f3
  lda PST_Table_Hi, y
  sta $f4; $f3/$f4 = PST pointer

; Convert 0x88 square to 0-63 index
; sq64 = (row * 8) + col = ((sq >> 4) * 8) + (sq & 7)
  lda $f0
  and #$07; Column (0-7)
  sta $f5
  lda $f0
  lsr
  lsr
  lsr
  lsr; Row (0-7)
  asl
  asl
  asl; Row * 8
  ora $f5; + column = 0-63
  sta $f5; $f5 = square index 0-63

; For black pieces, mirror the square (XOR with $38 = flip rank)
  lda $f1
  beq __ai_eval_mirror_0
  jmp __ai_eval_lookup_0
__ai_eval_mirror_0:
  lda $f5
  eor #$38; Mirror for black
  sta $f5

__ai_eval_lookup_0:
; Look up PST value
  ldy $f5
  lda ($f3), y; A = PST value (signed byte)
  sta $f6; Save PST value

; Call appropriate helper based on color
  lda $f1
  beq PstBlackPiece
  jmp PstWhitePiece

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
  jsr EvaluateEndgame
  rts
__ai_eval_eval_middlegame_king_0:
  jsr EvaluateKingSafety
  rts

;
; PstWhitePiece - Add PST value for white piece
; Input: $f6 = signed PST value
; Modifies: A
;
PstWhitePiece:
  lda $f6
  bmi __ai_eval_negative_0
; Positive PST value - add it
  clc
  lda EvalScore
  adc $f6
  sta EvalScore
  lda EvalScore + 1
  adc #$00
  sta EvalScore + 1
  ldx $f0
  jmp PstNext

__ai_eval_negative_0:
; Negative PST value - subtract its absolute value
  lda $f6
  eor #$ff
  clc
  adc #$01; Negate to get positive
  sta $f6
  sec
  lda EvalScore
  sbc $f6
  sta EvalScore
  lda EvalScore + 1
  sbc #$00
  sta EvalScore + 1
  ldx $f0
  jmp PstNext

;
; PstBlackPiece - Subtract PST value for black piece
; Input: $f6 = signed PST value
; Modifies: A
;
PstBlackPiece:
  lda $f6
  bmi __ai_eval_negative_1
; Positive PST value - subtract it
  sec
  lda EvalScore
  sbc $f6
  sta EvalScore
  lda EvalScore + 1
  sbc #$00
  sta EvalScore + 1
  ldx $f0
  jmp PstNext

__ai_eval_negative_1:
; Negative PST value - subtracting negative = adding positive
  lda $f6
  eor #$ff
  clc
  adc #$01; Negate to get positive
  sta $f6
  clc
  lda EvalScore
  adc $f6
  sta EvalScore
  lda EvalScore + 1
  adc #$00
  sta EvalScore + 1
  ldx $f0
  jmp PstNext

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
  lda PawnAttackPenalty, y
  jsr SubtractEvalUnsigned
  rts

__ai_eval_black_attacked_0:
  ldy $f2
  lda PawnAttackPenalty, y
  jsr AddEvalUnsigned

__ai_eval_done_1:
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
  lda QueenAttackPenalty, y
  jsr SubtractEvalUnsigned
  rts

__ai_eval_black_attacked_1:
  ldy $f2
  lda QueenAttackPenalty, y
  jsr AddEvalUnsigned

__ai_eval_done_2:
  rts

;
; EvaluateMinorPressure
; Penalize a queen currently attacked by an enemy knight. This is intentionally
; narrow: queen-in-danger positions are expensive when missed, and knight
; attacks are cheap to detect from the queen square.
; Inputs: $f0=square, $f1=color, $f2=piece type.
; Clobbers: A, X, Y, $f3-$f5
;
EvaluateMinorPressure:
  lda $f2
  cmp #QUEEN_TYPE
  bne __ai_eval_done_3

  jsr IsPieceKnightAttacked
  bcc __ai_eval_done_3

  lda $f1
  beq __ai_eval_black_attacked_2
  lda #KNIGHT_ATTACK_QUEEN_PENALTY
  jsr SubtractEvalUnsigned
  rts

__ai_eval_black_attacked_2:
  lda #KNIGHT_ATTACK_QUEEN_PENALTY
  jsr AddEvalUnsigned

__ai_eval_done_3:
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
  jmp ApplyMobilityScore

ApplyMobilityScore:
  beq __ai_eval_done_4
  ldx $f1
  beq __ai_eval_black_piece_0
  jsr AddEvalUnsigned
  rts

__ai_eval_black_piece_0:
  jsr SubtractEvalUnsigned

__ai_eval_done_4:
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
  bne __ai_eval_check_white_passed_0

; Black pawn - check if passed (no white pawns ahead toward row 7)
  jsr CheckBlackPassed
  bcc __ai_eval_passed_next_0

; Black passed pawn - penalty for white
; Bonus = PassedPawnBonus[7 - row] since black advances toward row 7
  lda #$07
  sec
  sbc $f2
  tay
  lda PassedPawnBonus, y
  sta $f3
  sec
  lda EvalScore
  sbc $f3
  sta EvalScore
  lda EvalScore + 1
  sbc #$00
  sta EvalScore + 1
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
  lda PassedPawnBonus, y
  sta $f3
  clc
  lda EvalScore
  adc $f3
  sta EvalScore
  lda EvalScore + 1
  adc #$00
  sta EvalScore + 1
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
  beq __ai_eval_passed_done_0
  jmp __ai_eval_passed_loop_0

__ai_eval_passed_done_0:
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
  beq __ai_eval_has_white_rook_0
  jmp __ai_eval_white_rook_row_0

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
  beq __ai_eval_has_black_rook_0
  jmp __ai_eval_black_rook_row_0

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
  sta $f0
  clc
  lda EvalScore
  adc $f0
  sta EvalScore
  lda EvalScore + 1
  adc #$00
  sta EvalScore + 1

  lda blackkingsq
  jsr EvaluateEndgameKingActivity
  sta $f0
  sec
  lda EvalScore
  sbc $f0
  sta EvalScore
  lda EvalScore + 1
  sbc #$00
  sta EvalScore + 1

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
  lda #ENDGAME_ROOK_OPEN_FILE_BONUS
  jsr AddEvalUnsigned
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
  lda #ENDGAME_ROOK_OPEN_FILE_BONUS
  jsr SubtractEvalUnsigned
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
; Output: A = unsigned activity bonus
; Clobbers: $f0-$f1
;
EvaluateEndgameKingActivity:
  sta $f0
  lda #$00
  sta $f1

  lda $f0
  and #$07; file
  cmp #$02
  bcc __ai_eval_activity_file_done_0
  cmp #$06
  bcs __ai_eval_activity_file_done_0
  lda $f1
  clc
  adc #ENDGAME_KING_ACTIVITY_BONUS
  sta $f1

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
  lda $f1
  clc
  adc #ENDGAME_KING_ACTIVITY_BONUS
  sta $f1

__ai_eval_activity_done_0:
  lda $f1
  rts

;
; EvaluateKingSafety
; Score king safety: castling position, pawn shield, exposure
; Adds/subtracts from EvalScore
; Clobbers: A, X, Y, $f0-$f4
;
EvaluateKingSafety:
; Evaluate white king safety
  lda whitekingsq
  jsr EvaluateSingleKingSafety
; A = signed safety score (positive = safe, negative = unsafe)
; Add signed byte to EvalScore (good for white)
  sta $f0
  clc
  lda EvalScore
  adc $f0
  sta EvalScore
  ldx $f0
  bpl __ai_eval_white_safety_positive_0
  lda EvalScore + 1
  adc #$ff
  jmp __ai_eval_white_safety_done_0
__ai_eval_white_safety_positive_0:
  lda EvalScore + 1
  adc #$00
__ai_eval_white_safety_done_0:
  sta EvalScore + 1

; Evaluate black king safety
  lda blackkingsq
  jsr EvaluateSingleKingSafety
; A = signed safety score
; Subtract signed byte from EvalScore (good for black = bad for white)
  sta $f0
  sec
  lda EvalScore
  sbc $f0
  sta EvalScore
  ldx $f0
  bpl __ai_eval_black_safety_positive_0
  lda EvalScore + 1
  sbc #$ff
  jmp __ai_eval_black_safety_done_0
__ai_eval_black_safety_positive_0:
  lda EvalScore + 1
  sbc #$00
__ai_eval_black_safety_done_0:
  sta EvalScore + 1

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
  jmp EvalWhiteKingSafety

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
  lda $f1; Return safety score
  rts
