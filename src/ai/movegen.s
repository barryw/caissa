; Generated ca65 port from Chess/ai/movegen.asm.
; Keep source changes in this repository in ca65 syntax.

; import-once was handled by the ca65 include topology

; Pseudo-Legal Move Generator
; Generates all moves that follow piece movement rules
; Legality (king in check) verified separately

.segment "CODE"

;
; Move List Storage
; Maximum ~218 moves in any chess position (theoretical max)
; Using 2 bytes per move: from (0x88) + to (0x88)
; 128 moves = 256 bytes storage
;
MAX_MOVES = 128

; Move count (number of moves in list)
.segment "BSS"

MoveCount:
  .res 1

; Move list: pairs of (from, to) squares
; Index by: MoveListFrom[i], MoveListTo[i]
MoveListFrom:
  .res MAX_MOVES

MoveListTo:
  .res MAX_MOVES

.segment "CODE"

.ifndef CHESS_RULES_ONLY
; Compact ranks for 8-bit MVV-LVA move ordering. Full evaluation values
; overflow when multiplied inside a byte, so ordering uses bounded ranks.
MVV_LVA_ScoreValues:
  .byte 0; 0: empty
  .byte 1; 1: pawn
  .byte 3; 2: knight
  .byte 3; 3: bishop
  .byte 5; 4: rook
  .byte 9; 5: queen
  .byte 0; 6: king

RECAPTURE_ORDER_BONUS = 32

; Score storage for MVV-LVA sorting (one per move)
.segment "BSS"

MoveScores:
  .res MAX_MOVES

; Compact quiet-move history table. Index is (from << 1) xor to, masked to
; 7 bits, so it is move-shaped without paying for a full from/to matrix.
HistoryScores:
  .res 128

; Countermove table keyed by the previous move's destination square. This is a
; compact continuation-history hint: if a quiet move refutes replies after a
; given destination, try it early the next time that destination appears.
CounterMoveFrom:
  .res 128
CounterMoveTo:
  .res 128

.segment "CODE"
.endif

;
; Clear move list
; Resets count to zero
; Clobbers: A
;
ClearMoveList:
  lda #$00
  sta MoveCount
  rts

;
; Add move to list
; Input: A = from square (0x88 index)
;        X = to square (0x88 index)
; Clobbers: Y
; Note: Does not check for overflow (caller's responsibility)
;
AddMove:
  ldy MoveCount; Y = current count (index for new move)
  sta MoveListFrom, y; Store 'from' square
  txa; A = to square
  sta MoveListTo, y; Store 'to' square
  inc MoveCount; Increment count
  rts

;
; Generate knight moves from a square
; Input: A = from square (0x88 index)
;        X = side to move color ($80 = white, $00 = black)
; Clobbers: A, X, Y, $f7-$fa
;
GenerateKnightMoves:
  sta $f7; $f7 = from square
  sta __ai_movegen_knight_base_0+1; SMC: patch the (invariant) from square as base
  stx $f8; $f8 = our color
  lda #$00
  sta $f9; $f9 = offset index

__ai_movegen_knight_loop_0:
  ldx $f9; X = offset index
__ai_movegen_knight_base_0:
  lda #$00; patched: from square ($f7)
  clc
  adc KnightOffsets, x; Add knight offset
  sta $fa; $fa = target square

; Check if target is on board
  and #OFFBOARD_MASK
  bne __ai_movegen_knight_next_0; Off board, skip

; Check what's on target square
  ldx $fa
  lda Board88, x

; If empty, add move
  cmp #EMPTY_PIECE
  beq __ai_movegen_add_knight_move_0

; Check if enemy piece (can capture)
  and #WHITE_COLOR; Get piece color
  cmp $f8; Compare with our color
  beq __ai_movegen_knight_next_0; Same color = can't capture, skip

; Enemy piece - can capture
__ai_movegen_add_knight_move_0:
  lda $f7; A = from
  ldx $fa; X = to
  jsr AddMove

__ai_movegen_knight_next_0:
  inc $f9; Next offset
  lda $f9
  cmp #$08; 8 knight offsets
  bne __ai_movegen_knight_loop_0

  rts

;
; Generate sliding moves in given directions
; Input: A = from square (0x88 index)
;        X = side to move color ($80 = white, $00 = black)
;        Y = number of directions
;        $fd/$fe = pointer to direction table (set before calling)
; Clobbers: A, X, Y, $f7-$fe
;
; This is a helper used by rook, bishop, queen generators
; Uses $fd/$fe as zero-page pointer for indirect indexed addressing
;

GenerateSlidingMoves:
  sta $f7; $f7 = from square
  stx $f8; $f8 = our color
  sty $fb; $fb = number of directions
  lda #$00
  sta $f9; $f9 = direction index

__ai_movegen_direction_loop_0:
; Get direction offset
  ldy $f9
  lda ($fd), y; $fd/$fe = direction table pointer
  sta __ai_movegen_slide_delta_0+1; SMC: patch the step delta as an immediate

; Start sliding from the from square (reset each direction)
  lda $f7
  sta $fc; $fc = current square

__ai_movegen_slide_loop_0:
; Move one step in direction
  lda $fc
  clc
__ai_movegen_slide_delta_0:
  adc #$00; patched: step delta
  sta $fc; $fc = new target square

; Check if on board
  and #OFFBOARD_MASK
  bne __ai_movegen_next_direction_0; Off board, try next direction

; Check what's on target square
  ldx $fc
  lda Board88, x

; If empty, add move and continue sliding
  cmp #EMPTY_PIECE
  beq __ai_movegen_add_slide_move_0

; Not empty - check if enemy piece
  and #WHITE_COLOR; Get piece color
  cmp $f8; Compare with our color
  beq __ai_movegen_next_direction_0; Same color = blocked, next direction

; Enemy piece - add capture move, then stop
  lda $f7; A = from
  ldx $fc; X = to
  jsr AddMove
  jmp __ai_movegen_next_direction_0

__ai_movegen_add_slide_move_0:
  lda $f7; A = from
  ldx $fc; X = to
  jsr AddMove
  jmp __ai_movegen_slide_loop_0; Continue sliding

__ai_movegen_next_direction_0:
  inc $f9; Next direction
  lda $f9
  cmp $fb; Done all directions?
  bne __ai_movegen_direction_loop_0

  rts

;
; Generate rook moves (orthogonal sliding)
; Input: A = from square, X = side color
; Clobbers: A, X, Y, $f7-$fe
;
GenerateRookMoves:
  pha; Save from square
  lda #<OrthogonalOffsets
  sta $fd; Direction pointer low byte
  lda #>OrthogonalOffsets
  sta $fe; Direction pointer high byte
  pla; Restore from square
  ldy #$04; 4 orthogonal directions
  jmp GenerateSlidingMoves

;
; Generate bishop moves (diagonal sliding)
; Input: A = from square, X = side color
; Clobbers: A, X, Y, $f7-$fe
;
GenerateBishopMoves:
  pha; Save from square
  lda #<DiagonalOffsets
  sta $fd; Direction pointer low byte
  lda #>DiagonalOffsets
  sta $fe; Direction pointer high byte
  pla; Restore from square
  ldy #$04; 4 diagonal directions
  jmp GenerateSlidingMoves

;
; Generate queen moves (all 8 directions sliding)
; Input: A = from square, X = side color
; Clobbers: A, X, Y, $f7-$fe
;
GenerateQueenMoves:
  pha; Save from square
  lda #<AllDirectionOffsets
  sta $fd; Direction pointer low byte
  lda #>AllDirectionOffsets
  sta $fe; Direction pointer high byte
  pla; Restore from square
  ldy #$08; 8 directions
  jmp GenerateSlidingMoves

;
; Generate king moves (one square in any direction)
; Input: A = from square, X = side color
; Note: Does NOT check for moving into check - that's done at legality level
; Clobbers: A, X, Y, $f7-$fa
;
GenerateKingMoves:
  sta $f7; $f7 = from square
  sta __ai_movegen_king_base_0+1; SMC: patch the (invariant) from square as base
  stx $f8; $f8 = our color
  lda #$00
  sta $f9; $f9 = direction index

__ai_movegen_king_loop_0:
  ldx $f9; X = direction index
__ai_movegen_king_base_0:
  lda #$00; patched: from square ($f7)
  clc
  adc AllDirectionOffsets, x; Add direction offset
  sta $fa; $fa = target square

; Check if target is on board
  and #OFFBOARD_MASK
  bne __ai_movegen_king_next_0; Off board, skip

; Check what's on target square
  ldx $fa
  lda Board88, x

; If empty, add move
  cmp #EMPTY_PIECE
  beq __ai_movegen_add_king_move_0

; Check if enemy piece (can capture)
  and #WHITE_COLOR; Get piece color
  cmp $f8; Compare with our color
  beq __ai_movegen_king_next_0; Same color = can't capture, skip

; Enemy piece - can capture
__ai_movegen_add_king_move_0:
  lda $f7; A = from
  ldx $fa; X = to
  jsr AddMove

__ai_movegen_king_next_0:
  inc $f9; Next direction
  lda $f9
  cmp #$08; 8 king directions
  bne __ai_movegen_king_loop_0

; Fall through to castling generation

;
; Generate castling moves (called from GenerateKingMoves)
; Uses $f7 = king's current square, $f8 = our color
; Checks castling rights, empty squares between king and rook
; Note: Does NOT check if king passes through check (legal filter handles that)
;
GenerateCastlingMoves:
  lda $f8; Our color
  bne __ai_movegen_white_castle_0

__ai_movegen_black_castle_0:
; Black castling - king must be on e8 ($04)
  lda $f7
  cmp #$04
  beq __ai_movegen_black_king_ok_0
  jmp __ai_movegen_castle_done_0
__ai_movegen_black_king_ok_0:

; Check black kingside (bit 2)
  lda castlerights
  and #%00000100
  beq __ai_movegen_black_queenside_0

; Check f8 ($05) and g8 ($06) are empty
  lda Board88 + $05
  cmp #EMPTY_PIECE
  bne __ai_movegen_black_queenside_0
  lda Board88 + $06
  cmp #EMPTY_PIECE
  bne __ai_movegen_black_queenside_0

; Add black kingside castle: e8 ($04) -> g8 ($06)
  lda #$04
  ldx #$06
  jsr AddMove

__ai_movegen_black_queenside_0:
; Check black queenside (bit 3)
  lda castlerights
  and #%00001000
  beq __ai_movegen_castle_done_0

; Check b8 ($01), c8 ($02), d8 ($03) are empty
  lda Board88 + $01
  cmp #EMPTY_PIECE
  bne __ai_movegen_castle_done_0
  lda Board88 + $02
  cmp #EMPTY_PIECE
  bne __ai_movegen_castle_done_0
  lda Board88 + $03
  cmp #EMPTY_PIECE
  bne __ai_movegen_castle_done_0

; Add black queenside castle: e8 ($04) -> c8 ($02)
  lda #$04
  ldx #$02
  jmp AddMove

__ai_movegen_white_castle_0:
; White castling - king must be on e1 ($74)
  lda $f7
  cmp #$74
  bne __ai_movegen_castle_done_0

; Check white kingside (bit 0)
  lda castlerights
  and #%00000001
  beq __ai_movegen_white_queenside_0

; Check f1 ($75) and g1 ($76) are empty
  lda Board88 + $75
  cmp #EMPTY_PIECE
  bne __ai_movegen_white_queenside_0
  lda Board88 + $76
  cmp #EMPTY_PIECE
  bne __ai_movegen_white_queenside_0

; Add white kingside castle: e1 ($74) -> g1 ($76)
  lda #$74
  ldx #$76
  jsr AddMove

__ai_movegen_white_queenside_0:
; Check white queenside (bit 1)
  lda castlerights
  and #%00000010
  beq __ai_movegen_castle_done_0

; Check b1 ($71), c1 ($72), d1 ($73) are empty
  lda Board88 + $71
  cmp #EMPTY_PIECE
  bne __ai_movegen_castle_done_0
  lda Board88 + $72
  cmp #EMPTY_PIECE
  bne __ai_movegen_castle_done_0
  lda Board88 + $73
  cmp #EMPTY_PIECE
  bne __ai_movegen_castle_done_0

; Add white queenside castle: e1 ($74) -> c1 ($72)
  lda #$74
  ldx #$72
  jmp AddMove

__ai_movegen_castle_done_0:
  rts

;
; Generate pawn moves
; Input: A = from square, X = side color ($80 = white, $00 = black)
; Note: Now handles en passant captures
; Clobbers: A, X, Y, $f7-$fb
;
WHITE_PAWN_PUSH = $f0; -16 (north)
BLACK_PAWN_PUSH = $10; +16 (south)
WHITE_START_ROW = $60; Row 6 (rank 2)
BLACK_START_ROW = $10; Row 1 (rank 7)
PROMO_FLAG_KNIGHT = $80; Bit 7 set = Knight promotion (vs Queen)
WHITE_PROMO_ROW = $00; Row 0 (rank 8) - white promotes here
BLACK_PROMO_ROW = $70; Row 7 (rank 1) - black promotes here

GeneratePawnMoves:
  sta $f7; $f7 = from square
  stx $f8; $f8 = our color

; Determine push direction based on color
  lda $f8
  bne __ai_movegen_white_pawn_0

; Black pawn - pushes south
  lda #BLACK_PAWN_PUSH
  sta $f9; $f9 = push direction
  lda #BLACK_START_ROW
  sta $fb; $fb = start row base
  jmp __ai_movegen_generate_pawn_pushes_0

__ai_movegen_white_pawn_0:
; White pawn - pushes north
  lda #WHITE_PAWN_PUSH
  sta $f9; $f9 = push direction
  lda #WHITE_START_ROW
  sta $fb; $fb = start row base

__ai_movegen_generate_pawn_pushes_0:
; Single push
  lda $f7
  clc
  adc $f9; Add push direction
  sta $fa; $fa = target square

; Check if on board
  and #OFFBOARD_MASK
  bne GeneratePawnCapturesFromState; Off board, skip to captures

; Check if empty (pawns can only push to empty squares)
  ldx $fa
  lda Board88, x
  cmp #EMPTY_PIECE
  bne GeneratePawnCapturesFromState; Blocked, skip to captures

; Add single push move - check for promotion first
  jsr AddPawnMoveWithPromotion

; Check for double push (from start row)
  lda $f7
  and #$70; Get row (high nibble)
  cmp $fb; Compare with start row
  bne GeneratePawnCapturesFromState; Not on start row, skip double push

; Double push - add another step
  lda $fa; Current target (after single push)
  clc
  adc $f9; Add push direction again
  sta $fa; $fa = double push target

; Check if on board
  and #OFFBOARD_MASK
  bne GeneratePawnCapturesFromState; Off board

; Check if empty
  ldx $fa
  lda Board88, x
  cmp #EMPTY_PIECE
  bne GeneratePawnCapturesFromState; Blocked

; Add double push move
  lda $f7; A = from
  ldx $fa; X = to
  jsr AddMove
  jmp GeneratePawnCapturesFromState

GeneratePawnCaptures:
  sta $f7; $f7 = from square
  stx $f8; $f8 = our color

GeneratePawnCapturesFromState:
; Generate capture moves
; White captures: NW (-17=$ef), NE (-15=$f1)
; Black captures: SW (+15=$0f), SE (+17=$11)
; Use PawnCaptureOffsets table: [Black SW, Black SE, White NW, White NE]

; Determine capture offset base
  lda $f8; Our color
  beq __ai_movegen_black_captures_0
  lda #$02; White offset index = 2
  jmp __ai_movegen_capture_loop_start_0
__ai_movegen_black_captures_0:
  lda #$00; Black offset index = 0

__ai_movegen_capture_loop_start_0:
  sta $fb; $fb = capture offset index

__ai_movegen_capture_loop_0:
  ldx $fb
  lda PawnCaptureOffsets, x
  sta $fa; $fa = capture direction

  lda $f7
  clc
  adc $fa; Target capture square
  sta $fa

; Check if on board
  and #OFFBOARD_MASK
  bne __ai_movegen_next_capture_0

; Check if enemy piece or en passant square
  ldx $fa
  lda Board88, x
  cmp #EMPTY_PIECE
  bne __ai_movegen_check_enemy_0

; Empty square - check if it's en passant target
  lda $fa
  cmp enpassantsq
  bne __ai_movegen_next_capture_0; Not en passant square, skip
  jmp __ai_movegen_add_capture_0; Is en passant - add the move

__ai_movegen_check_enemy_0:
; Check if enemy
  and #WHITE_COLOR
  cmp $f8
  beq __ai_movegen_next_capture_0; Same color - can't capture own piece

__ai_movegen_add_capture_0:
; Enemy piece or en passant - add capture move with promotion check
  jsr AddPawnMoveWithPromotion

__ai_movegen_next_capture_0:
  inc $fb; Next capture direction
  lda $fb
; Check if done (white: 2,3 -> done at 4; black: 0,1 -> done at 2)
  lda $f8
  bne __ai_movegen_white_capture_check_0
  lda $fb
  cmp #$02; Black done after index 1
  bne __ai_movegen_capture_loop_0
  rts

__ai_movegen_white_capture_check_0:
  lda $fb
  cmp #$04; White done after index 3
  bne __ai_movegen_capture_loop_0
  rts

;
; AddPawnMoveWithPromotion - Add pawn move, generating both Q and N if promoting
; Uses $f7 = from square, $f8 = our color, $fa = to square
; Checks if to square is on promotion rank and adds both promotion variants
; Clobbers: A, X
;
AddPawnMoveWithPromotion:
; Determine promotion row based on color
  lda $f8; Our color
  bne __ai_movegen_check_white_promo_0

; Black pawn - promotes on row 7 ($70)
  lda $fa; to square
  and #$70; Get row nibble
  cmp #BLACK_PROMO_ROW
  beq __ai_movegen_is_promotion_0
  jmp __ai_movegen_normal_pawn_move_0

__ai_movegen_check_white_promo_0:
; White pawn - promotes on row 0 ($00)
  lda $fa; to square
  and #$70; Get row nibble
  cmp #WHITE_PROMO_ROW
  bne __ai_movegen_normal_pawn_move_0

__ai_movegen_is_promotion_0:
  jmp AddPawnPromotionMoves

__ai_movegen_normal_pawn_move_0:
; Not a promotion - add regular move
  lda $f7; A = from
  ldx $fa; X = to
  jmp AddMove

;
; Generate all pseudo-legal moves for a side
; Input: X = side to move color ($80 = white, $00 = black)
; Output: Moves added to move list (call ClearMoveList first!)
; Clobbers: A, X, Y, $f0-$fe
;
GenerateAllMoves:
  stx $f0; $f0 = side to move color

; Loop through the active piece list for the side instead of scanning all 64
; squares. MakeMove/UnmakeMove keep the lists compact during search.
  lda #$00
  sta $f1; $f1 = piece-list index
  lda $f0
  beq __ai_movegen_black_list_count_0
  lda WhitePieceCount
  jmp __ai_movegen_list_count_ready_0
__ai_movegen_black_list_count_0:
  lda BlackPieceCount
__ai_movegen_list_count_ready_0:
  sta $f6; $f6 = piece-list count

__ai_movegen_gen_loop_0:
  lda $f1
  cmp $f6
  bcc __ai_movegen_get_list_square_0
  jmp __ai_movegen_gen_done_0

__ai_movegen_get_list_square_0:
  lda $f0
  beq __ai_movegen_get_black_square_0
  ldy $f1
  lda WhitePieceList, y
  jmp __ai_movegen_have_list_square_0
__ai_movegen_get_black_square_0:
  ldy $f1
  lda BlackPieceList, y

__ai_movegen_have_list_square_0:
  cmp #$ff
  beq __ai_movegen_gen_next_square_0
  sta $f5; $f5 = from square
  tax
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_movegen_gen_next_square_0; Stale list slot, skip

; Check if piece belongs to side to move
  sta $f2; Save piece value without stack traffic
  and #WHITE_COLOR; Get piece color
  cmp $f0; Compare with side to move
  bne __ai_movegen_gen_next_square_0; Not our piece, skip

; Our piece - determine type and generate moves
  lda $f2; Restore piece value
  and #$07; Get piece type (1-6)
  cmp #$01; Pawn?
  beq __ai_movegen_gen_pawn_0
  cmp #$02; Knight?
  beq __ai_movegen_gen_knight_0
  cmp #$03; Bishop?
  beq __ai_movegen_gen_bishop_0
  cmp #$04; Rook?
  beq __ai_movegen_gen_rook_0
  cmp #$05; Queen?
  beq __ai_movegen_gen_queen_0
  cmp #$06; King?
  beq __ai_movegen_gen_king_0
  jmp __ai_movegen_gen_next_square_0; Unknown piece type

__ai_movegen_gen_pawn_0:
  lda $f5; From square
  ldx $f0; Side color
  jsr GeneratePawnMoves
  jmp __ai_movegen_gen_next_square_0

__ai_movegen_gen_knight_0:
  lda $f5; From square
  ldx $f0; Side color
  jsr GenerateKnightMoves
  jmp __ai_movegen_gen_next_square_0

__ai_movegen_gen_bishop_0:
  lda $f5; From square
  ldx $f0; Side color
  jsr GenerateBishopMoves
  jmp __ai_movegen_gen_next_square_0

__ai_movegen_gen_rook_0:
  lda $f5; From square
  ldx $f0; Side color
  jsr GenerateRookMoves
  jmp __ai_movegen_gen_next_square_0

__ai_movegen_gen_queen_0:
  lda $f5; From square
  ldx $f0; Side color
  jsr GenerateQueenMoves
  jmp __ai_movegen_gen_next_square_0

__ai_movegen_gen_king_0:
  lda $f5; From square
  ldx $f0; Side color
  jsr GenerateKingMoves

__ai_movegen_gen_next_square_0:
  inc $f1
  jmp __ai_movegen_gen_loop_0

__ai_movegen_gen_done_0:
  lda MoveCount; Return move count in A
  rts

.ifndef CHESS_RULES_ONLY
;
; OrderMovesMVVLVA - Sort captures by Most Valuable Victim - Least Valuable Attacker
; Winning/safe captures are sorted to front by MVV-LVA score descending.
; Obviously losing captures stay with quiet moves so killers can precede them.
;
; Input: MoveListFrom/MoveListTo populated, MoveCount set
; Output: Move list reordered with best captures first
; Clobbers: A, X, Y, $e0-$e7, $f0-$f5
;
OrderMovesMVVLVA:
; First pass: score all captures, partition to front
  lda #$00
  sta $e0; $e0 = write index (captures)
  sta $e1; $e1 = read index

__ai_movegen_score_loop_0:
  lda $e1
  cmp MoveCount
  bne __ai_movegen_score_move_mvv_0
  jmp __ai_movegen_sort_captures_0

__ai_movegen_score_move_mvv_0:
; Get target square
  ldx $e1
  lda MoveListTo, x
  and #$7f; Clear promotion flag if present
  tay
  lda Board88, y; Piece on target
  cmp #EMPTY_PIECE
  beq __ai_movegen_not_capture_mvv_0

__ai_movegen_capture_mvv_0:
; It's a capture - calculate MVV-LVA score
  and #$07; Victim type
  tay
  lda MVV_LVA_ScoreValues, y
  sta $e4; Victim rank
  asl
  asl
  asl
  asl; Victim rank * 16
  sta $e2; Victim score

; Get attacker type
  ldx $e1
  lda MoveListFrom, x
  tay
  lda Board88, y
  and #$07; Attacker type
  tay
  lda MVV_LVA_ScoreValues, y
  sta $e3; Attacker value

; Score = victim rank * 16 - attacker rank
  lda $e2
  sec
  sbc $e3
  ldx $e1
  sta MoveScores, x; Store score for this move
  jsr ApplyRecaptureOrderingBonus

; Swap-off gate: lower-value captures only stay tactical if the destination
; is not defended after the move is made.
  ldx $e1
  jsr CapturePassesSwapOff
  bcc __ai_movegen_bad_capture_mvv_0

__ai_movegen_promote_capture_mvv_0:
  ldx $e1

; Swap capture to write position
  ldy $e0
  cpx $e0
  beq __ai_movegen_same_pos_mvv_0

; Swap from[x] with from[y]
  lda MoveListFrom, x
  pha
  lda MoveListFrom, y
  sta MoveListFrom, x
  pla
  sta MoveListFrom, y

; Swap to[x] with to[y]
  lda MoveListTo, x
  pha
  lda MoveListTo, y
  sta MoveListTo, x
  pla
  sta MoveListTo, y

; Swap scores[x] with scores[y]
  lda MoveScores, x
  pha
  lda MoveScores, y
  sta MoveScores, x
  pla
  sta MoveScores, y

__ai_movegen_same_pos_mvv_0:
  inc $e0; Advance write pointer

__ai_movegen_not_capture_mvv_0:
  inc $e1
  jmp __ai_movegen_score_loop_0

__ai_movegen_bad_capture_mvv_0:
  ldx $e1
  lda #$00
  sta MoveScores, x
  jmp __ai_movegen_not_capture_mvv_0

__ai_movegen_sort_captures_0:
; $e0 = number of captures
; Now bubble sort captures by score (descending)
  lda $e0
  cmp #$02
  bcc __ai_movegen_mvvlva_done_0; 0 or 1 captures, no sort needed

  sta $e4; $e4 = capture count

__ai_movegen_outer_sort_0:
  lda #$00
  sta $e5; $e5 = swapped flag

  lda #$00
  sta $e1; $e1 = index

__ai_movegen_inner_sort_0:
  lda $e1
  clc
  adc #$01
  cmp $e4
  bcs __ai_movegen_check_swapped_0; Done inner loop

; Compare scores[i] with scores[i+1]
  ldx $e1
  lda MoveScores, x
  ldy $e1
  iny
  cmp MoveScores, y
  bcs __ai_movegen_no_swap_mvv_0; scores[i] >= scores[i+1], no swap

; Swap moves at i and i+1
  lda MoveListFrom, x
  pha
  lda MoveListFrom, y
  sta MoveListFrom, x
  pla
  sta MoveListFrom, y

  lda MoveListTo, x
  pha
  lda MoveListTo, y
  sta MoveListTo, x
  pla
  sta MoveListTo, y

  lda MoveScores, x
  pha
  lda MoveScores, y
  sta MoveScores, x
  pla
  sta MoveScores, y

  lda #$01
  sta $e5; Set swapped flag

__ai_movegen_no_swap_mvv_0:
  inc $e1
  jmp __ai_movegen_inner_sort_0

__ai_movegen_check_swapped_0:
  lda $e5
  bne __ai_movegen_outer_sort_0; If swapped, do another pass

__ai_movegen_mvvlva_done_0:
; After captures are sorted, move forcing quiet moves to the front of the quiet
; band: promotions first, then quiet checks. Killer/history ordering handles
; the remaining quiet moves after these threats.
  lda $e0
  sta $e6; $e6 = start of quiet moves
  lda SearchDepth
  cmp #$02
  bcs __ai_movegen_skip_forcing_quiets_0
  jsr PromoteForcingQuietMoves
__ai_movegen_skip_forcing_quiets_0:

; Check each quiet move against killers
  lda $e6
  sta $e1; $e1 = current index

__ai_movegen_killer_reorder_loop_0:
  lda $e1
  cmp MoveCount
  bcs __ai_movegen_killer_done_reorder_0

; Get move
  ldx $e1
  lda MoveListFrom, x
  sta $e2
  lda MoveListTo, x
  and #$7f; Clear promotion flag
  sta $e3
  tay
  lda Board88, y
  cmp #EMPTY_PIECE
  bne __ai_movegen_next_killer_check_0; Stale killers must not promote captures.

; Check if it's a killer
  lda $e2; from
  ldx $e3; to
  ldy SearchDepth
  jsr IsKillerMove
  bcc __ai_movegen_next_killer_check_0

; It's a killer - swap to front of quiet moves
  ldx $e1
  ldy $e6
  cpx $e6
  beq __ai_movegen_advance_killer_front_0

; Swap from[x] with from[y]
  lda MoveListFrom, x
  pha
  lda MoveListFrom, y
  sta MoveListFrom, x
  pla
  sta MoveListFrom, y

; Swap to[x] with to[y]
  lda MoveListTo, x
  pha
  lda MoveListTo, y
  sta MoveListTo, x
  pla
  sta MoveListTo, y

__ai_movegen_advance_killer_front_0:
  inc $e6; Advance quiet move insertion point

__ai_movegen_next_killer_check_0:
  inc $e1
  jmp __ai_movegen_killer_reorder_loop_0

__ai_movegen_killer_done_reorder_0:
; Countermove ordering: after killers, try the quiet reply that most recently
; refuted the current node's previous move destination.
  lda SearchCounterMoveActive
  beq __ai_movegen_counter_done_0
  lda SearchDepth
  beq __ai_movegen_counter_done_0
  tay
  lda LastMoveToByDepth, y
  cmp #$ff
  beq __ai_movegen_counter_done_0
  and #$7f
  tay
  lda CounterMoveFrom, y
  cmp #$ff
  beq __ai_movegen_counter_done_0
  sta $e2
  lda CounterMoveTo, y
  sta $e3

  lda $e6
  sta $e1

__ai_movegen_counter_scan_loop_0:
  lda $e1
  cmp MoveCount
  bcs __ai_movegen_counter_done_0

  ldx $e1
  lda MoveListTo, x
  bmi __ai_movegen_counter_next_0
  and #$7f
  cmp $e3
  bne __ai_movegen_counter_next_0
  tay
  lda Board88, y
  cmp #EMPTY_PIECE
  bne __ai_movegen_counter_next_0
  lda MoveListFrom, x
  cmp $e2
  bne __ai_movegen_counter_next_0

  ldx $e1
  ldy $e6
  cpx $e6
  beq __ai_movegen_counter_advance_0

  lda MoveListFrom, x
  pha
  lda MoveListFrom, y
  sta MoveListFrom, x
  pla
  sta MoveListFrom, y

  lda MoveListTo, x
  pha
  lda MoveListTo, y
  sta MoveListTo, x
  pla
  sta MoveListTo, y

__ai_movegen_counter_advance_0:
  inc $e6
  jmp __ai_movegen_counter_done_0

__ai_movegen_counter_next_0:
  inc $e1
  jmp __ai_movegen_counter_scan_loop_0

__ai_movegen_counter_done_0:
  lda SearchHistoryActive
  bne __ai_movegen_history_start_0
  rts

__ai_movegen_history_start_0:
; Promote the best historical quiet move to the front of the remaining quiets.
  lda $e6
  cmp MoveCount
  bcc __ai_movegen_history_has_quiets_0
  rts

__ai_movegen_history_has_quiets_0:
  sta $e1; scan index
  sta $e4; best index
  lda #$00
  sta $e5; best score

__ai_movegen_history_scan_loop_0:
  lda $e1
  cmp MoveCount
  bcs __ai_movegen_history_promote_0

__ai_movegen_history_score_move_0:
  ldx $e1
  lda MoveListTo, x
  bmi __ai_movegen_history_next_0; Promotions are tactical, not history.
  and #$7f
  tay
  lda Board88, y
  cmp #EMPTY_PIECE
  bne __ai_movegen_history_next_0; Captures keep MVV-LVA ordering.

  lda MoveListFrom, x
  asl
  eor MoveListTo, x
  and #$7f
  tay
  lda HistoryScores, y
  cmp $e5
  beq __ai_movegen_history_next_0
  bcc __ai_movegen_history_next_0
  sta $e5
  lda $e1
  sta $e4

__ai_movegen_history_next_0:
  inc $e1
  jmp __ai_movegen_history_scan_loop_0

__ai_movegen_history_promote_0:
  lda $e5
  bne __ai_movegen_history_swap_0
  rts

__ai_movegen_history_swap_0:
  ldx $e4
  ldy $e6
  cpx $e6
  bne __ai_movegen_history_do_swap_0
  rts

__ai_movegen_history_do_swap_0:
  lda MoveListFrom, x
  pha
  lda MoveListFrom, y
  sta MoveListFrom, x
  pla
  sta MoveListFrom, y

  lda MoveListTo, x
  pha
  lda MoveListTo, y
  sta MoveListTo, x
  pla
  sta MoveListTo, y
  rts

;
; ApplyRecaptureOrderingBonus
; Captures back on the previous capture square are often forced. Give them a
; bounded score bump inside MVV-LVA without blindly outranking huge wins.
; Input: X = move index, MoveScores[x] already populated.
; Clobbers: A, Y, $e2
;
ApplyRecaptureOrderingBonus:
  lda SearchDepth
  beq __ai_movegen_recapture_bonus_done_0
  tay
  lda LastMoveWasCaptureByDepth, y
  beq __ai_movegen_recapture_bonus_done_0
  lda LastMoveToByDepth, y
  cmp #$ff
  beq __ai_movegen_recapture_bonus_done_0
  and #$7f
  sta $e2
  lda MoveListTo, x
  and #$7f
  cmp $e2
  bne __ai_movegen_recapture_bonus_done_0

  lda MoveScores, x
  clc
  adc #RECAPTURE_ORDER_BONUS
  bcc __ai_movegen_recapture_bonus_store_0
  lda #$ff
__ai_movegen_recapture_bonus_store_0:
  sta MoveScores, x

__ai_movegen_recapture_bonus_done_0:
  rts

;
; PromoteForcingQuietMoves
; Within the quiet move band, move promotions and checks before ordinary
; quiets so alpha-beta sees forcing moves before positional shuffling.
; Input/Output: $e6 = first non-forcing quiet index.
; Clobbers: A, X, Y, $e1-$e5, $f0-$f5, attack_sq, attack_color
;
PromoteForcingQuietMoves:
  lda $e6
  sta $e1; scan index

__ai_movegen_forcing_scan_loop_0:
  lda $e1
  cmp MoveCount
  bcc __ai_movegen_forcing_check_0
  rts

__ai_movegen_forcing_check_0:
  ldx $e1
  jsr IsQuietPromotionMove
  bcs __ai_movegen_promote_forcing_0

  ldx $e1
  jsr IsQuietMoveSearchForcing
  bcc __ai_movegen_forcing_next_0

__ai_movegen_promote_forcing_0:
  ldx $e1
  ldy $e6
  cpx $e6
  beq __ai_movegen_forcing_advance_0

  lda MoveListFrom, x
  pha
  lda MoveListFrom, y
  sta MoveListFrom, x
  pla
  sta MoveListFrom, y

  lda MoveListTo, x
  pha
  lda MoveListTo, y
  sta MoveListTo, x
  pla
  sta MoveListTo, y

__ai_movegen_forcing_advance_0:
  inc $e6

__ai_movegen_forcing_next_0:
  inc $e1
  jmp __ai_movegen_forcing_scan_loop_0

;
; IsQuietPromotionMove
; Input: X = move index. Output: carry set if this quiet move promotes.
; Clobbers: A, X, Y, $f0-$f3
;
IsQuietPromotionMove:
  lda MoveListTo, x
  and #$7f
  sta $f0
  tay
  lda Board88, y
  cmp #EMPTY_PIECE
  bne __ai_movegen_not_quiet_promotion_0

  lda MoveListFrom, x
  tay
  lda Board88, y
  cmp #EMPTY_PIECE
  beq __ai_movegen_not_quiet_promotion_0
  sta $f1
  and #$07
  cmp #PAWN_TYPE
  bne __ai_movegen_not_quiet_promotion_0

  lda $f1
  and #WHITE_COLOR
  beq __ai_movegen_black_promotion_check_0

  lda $f0
  and #$70
  cmp #WHITE_PROMO_ROW
  beq __ai_movegen_is_quiet_promotion_0
  clc
  rts

__ai_movegen_black_promotion_check_0:
  lda $f0
  and #$70
  cmp #BLACK_PROMO_ROW
  beq __ai_movegen_is_quiet_promotion_0

__ai_movegen_not_quiet_promotion_0:
  clc
  rts

__ai_movegen_is_quiet_promotion_0:
  sec
  rts

;
; IsQuietMoveSearchForcing
; Input: X = move index. Output: carry set if this quiet move gives check or
; creates a new attack on an enemy rook/queen.
; Clobbers: A, X, Y, $e2, $f0-$f7, attack_sq, attack_color
;
IsQuietMoveSearchForcing:
  stx $e2
  jsr IsQuietMoveChecking
  bcs __ai_movegen_quiet_forcing_0
  ldx $e2
  jsr IsQuietMoveMajorThreat
  bcs __ai_movegen_quiet_forcing_0
  clc
  rts

__ai_movegen_quiet_forcing_0:
  sec
  rts

;
; IsQuietMoveChecking
; Input: X = move index. Output: carry set if the quiet move gives check.
; Clobbers: A, X, Y, $f0-$f5, attack_sq, attack_color
;
IsQuietMoveChecking:
  lda MoveListTo, x
  bmi __ai_movegen_not_checking_quiet_0
  and #$7f
  sta $f1; destination
  tay
  lda Board88, y
  cmp #EMPTY_PIECE
  bne __ai_movegen_not_checking_quiet_0

  lda MoveListFrom, x
  sta $f0; source
  tay
  lda Board88, y
  cmp #EMPTY_PIECE
  beq __ai_movegen_not_checking_quiet_0
  sta $f2; moving piece
  and #WHITE_COLOR
  sta $f4; moving color

; Skip castling here; the temporary move below does not move the rook.
  lda $f2
  and #$07
  cmp #KING_TYPE
  bne __ai_movegen_temp_check_move_0
  lda $f1
  sec
  sbc $f0
  cmp #$02
  beq __ai_movegen_not_checking_quiet_0
  cmp #$fe
  beq __ai_movegen_not_checking_quiet_0

__ai_movegen_temp_check_move_0:
  ldx $f0
  lda #EMPTY_PIECE
  sta Board88, x
  ldx $f1
  lda $f2
  sta Board88, x

  lda $f4
  beq __ai_movegen_black_checking_move_0
  lda blackkingsq
  sta attack_sq
  lda #WHITES_TURN
  jmp __ai_movegen_checking_attack_ready_0

__ai_movegen_black_checking_move_0:
  lda whitekingsq
  sta attack_sq
  lda #BLACKS_TURN

__ai_movegen_checking_attack_ready_0:
  sta attack_color
  jsr IsSquareAttacked
  lda #$00
  rol
  sta $f5; 1 if checking

  ldx $f0
  lda $f2
  sta Board88, x
  ldx $f1
  lda #EMPTY_PIECE
  sta Board88, x

  lda $f5
  beq __ai_movegen_not_checking_quiet_0
  sec
  rts

__ai_movegen_not_checking_quiet_0:
  clc
  rts

;
; IsQuietMoveMajorThreat
; Input: X = move index. Output: carry set if the quiet move newly attacks an
; enemy rook or queen. This catches quiet tactics such as discovered attacks
; and knight forks without treating already-attacked majors as new threats.
; Clobbers: A, X, Y, $f0-$f7, attack_sq, attack_color
;
IsQuietMoveMajorThreat:
  lda MoveListTo, x
  bmi __ai_movegen_major_reject_0
  and #$7f
  sta $f1; destination
  tay
  lda Board88, y
  cmp #EMPTY_PIECE
  bne __ai_movegen_major_reject_0

  lda MoveListFrom, x
  sta $f0; source
  tay
  lda Board88, y
  cmp #EMPTY_PIECE
  beq __ai_movegen_major_reject_0
  sta $f2; moving piece
  and #WHITE_COLOR
  sta $f4; moving color

; Skip castling; the temporary move below does not move the rook.
  lda $f2
  and #$07
  cmp #KING_TYPE
  bne __ai_movegen_major_scan_start_0
  lda $f1
  sec
  sbc $f0
  cmp #$02
  beq __ai_movegen_major_reject_0
  cmp #$fe
  beq __ai_movegen_major_reject_0
  bne __ai_movegen_major_scan_start_0

__ai_movegen_major_reject_0:
  jmp __ai_movegen_not_major_threat_0

__ai_movegen_major_scan_start_0:
  lda #$00
  sta $f5; scan square

__ai_movegen_major_scan_loop_0:
  ldx $f5
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_movegen_major_next_square_0
  sta $f7; target piece
  and #WHITE_COLOR
  cmp $f4
  beq __ai_movegen_major_next_square_0
  lda $f7
  and #$07
  cmp #ROOK_TYPE
  beq __ai_movegen_major_candidate_0
  cmp #QUEEN_TYPE
  bne __ai_movegen_major_next_square_0

__ai_movegen_major_candidate_0:
  ldx $f5
  stx $f6; target square
  stx attack_sq
  lda $f4
  beq __ai_movegen_major_before_black_0
  lda #WHITES_TURN
  jmp __ai_movegen_major_before_ready_0
__ai_movegen_major_before_black_0:
  lda #BLACKS_TURN
__ai_movegen_major_before_ready_0:
  sta attack_color
  jsr IsSquareAttacked
  bcs __ai_movegen_major_next_square_0; Already attacked before this move.

; Temporarily apply the quiet move and see if the major piece becomes attacked.
  ldx $f0
  lda #EMPTY_PIECE
  sta Board88, x
  ldx $f1
  lda $f2
  sta Board88, x

  lda $f6
  sta attack_sq
  lda $f4
  beq __ai_movegen_major_after_black_0
  lda #WHITES_TURN
  jmp __ai_movegen_major_after_ready_0
__ai_movegen_major_after_black_0:
  lda #BLACKS_TURN
__ai_movegen_major_after_ready_0:
  sta attack_color
  jsr IsSquareAttacked
  lda #$00
  rol
  sta $f7

  ldx $f0
  lda $f2
  sta Board88, x
  ldx $f1
  lda #EMPTY_PIECE
  sta Board88, x

  lda $f7
  bne __ai_movegen_is_major_threat_0

__ai_movegen_major_next_square_0:
  inc $f5
  lda $f5
  and #$08
  beq __ai_movegen_major_check_done_0
  lda $f5
  clc
  adc #$08
  sta $f5
__ai_movegen_major_check_done_0:
  lda $f5
  cmp #BOARD_SIZE
  beq __ai_movegen_not_major_threat_0
  jmp __ai_movegen_major_scan_loop_0

__ai_movegen_not_major_threat_0:
  clc
  rts

__ai_movegen_is_major_threat_0:
  sec
  rts

;
; CapturePassesSwapOff
; Classify a capture using a cheap static exchange test. Winning/equal captures
; always pass. Losing captures pass only when the destination is not attacked
; after temporarily applying the move.
;
; Input: X = move list index.
; Output: Carry set = search/order as tactical, carry clear = bad capture.
; Clobbers: A, X, Y, attack_sq, attack_color, $f0-$f7
;
CapturePassesSwapOff:
  stx $f7; $f7 = move index

  lda MoveListTo, x
  and #$7f
  sta $f0; $f0 = destination square
  tay
  lda Board88, y
  cmp #EMPTY_PIECE
  beq __ai_movegen_safe_0
  sta $f5; $f5 = captured piece
  and #$07
  tay
  lda MVV_LVA_ScoreValues, y
  sta $f2; $f2 = victim rank

  ldx $f7
  lda MoveListFrom, x
  sta $f4; $f4 = source square
  tay
  lda Board88, y
  cmp #EMPTY_PIECE
  beq __ai_movegen_safe_0
  sta $f6; $f6 = moving piece
  and #WHITE_COLOR
  sta $f1; $f1 = moving color
  lda $f6
  and #$07
  tay
  lda MVV_LVA_ScoreValues, y
  sta $f3; $f3 = attacker rank
  tya
  cmp #KING_TYPE
  bne __ai_movegen_swapoff_compare_values_0
  lda #$0a
  sta $f3; Treat king captures as expensive if a raw list reaches SEE.

__ai_movegen_swapoff_compare_values_0:
  lda $f2
  cmp $f3
  bcs __ai_movegen_safe_0; Victim >= attacker: non-losing exchange.

; Temporarily make the move so x-ray defenders opened by the source square
; are visible to the shared attack detector.
  ldy $f4
  lda #EMPTY_PIECE
  sta Board88, y
  ldy $f0
  lda $f6
  sta Board88, y

  lda $f0
  sta attack_sq
  lda $f1
  beq __ai_movegen_black_moved_0
  lda #BLACKS_TURN
  jmp __ai_movegen_attack_color_ready_0
__ai_movegen_black_moved_0:
  lda #WHITES_TURN
__ai_movegen_attack_color_ready_0:
  sta attack_color
  jsr IsSquareAttacked
  lda #$00
  rol
  sta $f2; $f2 = attacked flag

  ldy $f4
  lda $f6
  sta Board88, y
  ldy $f0
  lda $f5
  sta Board88, y

  lda $f2
  bne __ai_movegen_bad_0

__ai_movegen_safe_0:
  sec
  rts

__ai_movegen_bad_0:
  clc
  rts

;
; GenerateCaptures
; Generate only capture moves (for quiescence search)
; Input: X = side to move color ($80=white, $00=black)
; Output: Captures in move list, MoveCount set
; Clobbers: A, X, Y, $f0-$fe
;
GenerateCaptures:
  stx $f0; $f0 = side to move color

; Generate captures directly instead of generating quiet moves and filtering.
  jsr ClearMoveList

  lda #$00
  sta $f1; $f1 = piece-list index
  lda $f0
  beq __ai_movegen_cap_black_list_count_0
  lda WhitePieceCount
  jmp __ai_movegen_cap_list_count_ready_0
__ai_movegen_cap_black_list_count_0:
  lda BlackPieceCount
__ai_movegen_cap_list_count_ready_0:
  sta $f6; $f6 = piece-list count

__ai_movegen_cap_gen_loop_0:
  lda $f1
  cmp $f6
  bcc __ai_movegen_cap_get_list_square_0
  jmp __ai_movegen_cap_done_0

__ai_movegen_cap_get_list_square_0:
  lda $f0
  beq __ai_movegen_cap_get_black_square_0
  ldy $f1
  lda WhitePieceList, y
  jmp __ai_movegen_cap_have_list_square_0
__ai_movegen_cap_get_black_square_0:
  ldy $f1
  lda BlackPieceList, y

__ai_movegen_cap_have_list_square_0:
  cmp #$ff
  beq __ai_movegen_cap_next_square_0
  sta $f5; $f5 = from square
  tax
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_movegen_cap_next_square_0

  sta $f2; Save piece value
  and #WHITE_COLOR
  cmp $f0
  bne __ai_movegen_cap_next_square_0; Not our piece

  lda $f2
  and #$07
  cmp #$01; Pawn?
  beq __ai_movegen_cap_pawn_0
  cmp #$02; Knight?
  beq __ai_movegen_cap_knight_0
  cmp #$03; Bishop?
  beq __ai_movegen_cap_bishop_0
  cmp #$04; Rook?
  beq __ai_movegen_cap_rook_0
  cmp #$05; Queen?
  beq __ai_movegen_cap_queen_0
  cmp #$06; King?
  beq __ai_movegen_cap_king_0
  jmp __ai_movegen_cap_next_square_0

__ai_movegen_cap_pawn_0:
  lda $f5
  ldx $f0
  jsr GeneratePawnCaptures
  jmp __ai_movegen_cap_next_square_0

__ai_movegen_cap_knight_0:
  lda $f5
  ldx $f0
  jsr GenerateKnightCaptures
  jmp __ai_movegen_cap_next_square_0

__ai_movegen_cap_bishop_0:
  lda $f5
  ldx $f0
  jsr GenerateBishopCaptures
  jmp __ai_movegen_cap_next_square_0

__ai_movegen_cap_rook_0:
  lda $f5
  ldx $f0
  jsr GenerateRookCaptures
  jmp __ai_movegen_cap_next_square_0

__ai_movegen_cap_queen_0:
  lda $f5
  ldx $f0
  jsr GenerateQueenCaptures
  jmp __ai_movegen_cap_next_square_0

__ai_movegen_cap_king_0:
  lda $f5
  ldx $f0
  jsr GenerateKingCaptures

__ai_movegen_cap_next_square_0:
  inc $f1
  jmp __ai_movegen_cap_gen_loop_0

__ai_movegen_cap_done_0:
  lda MoveCount
  rts

;
; AddCaptureIfEnemy
; Input: $f7 = from square, $f8 = our color, $fa = target square
; Adds the move only when the target contains an enemy piece.
; Clobbers: A, X
;
AddCaptureIfEnemy:
  ldx $fa
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_movegen_not_capture_0

  and #WHITE_COLOR
  cmp $f8
  beq __ai_movegen_not_capture_0

  lda $f7
  ldx $fa
  jmp AddMove

__ai_movegen_not_capture_0:
  rts

;
; Generate capture-only knight moves.
; Input: A = from square, X = side color
; Clobbers: A, X, $f7-$fa
;
GenerateKnightCaptures:
  sta $f7
  sta __ai_movegen_knightcap_base_0+1; SMC: patch the (invariant) from square as base
  stx $f8
  lda #$00
  sta $f9

__ai_movegen_knight_cap_loop_0:
  ldx $f9
__ai_movegen_knightcap_base_0:
  lda #$00; patched: from square ($f7)
  clc
  adc KnightOffsets, x
  sta $fa
  and #OFFBOARD_MASK
  bne __ai_movegen_knight_cap_next_0

  jsr AddCaptureIfEnemy

__ai_movegen_knight_cap_next_0:
  inc $f9
  lda $f9
  cmp #$08
  bne __ai_movegen_knight_cap_loop_0
  rts

;
; Generate capture-only sliding moves.
; Input: A = from square, X = side color, Y = number of directions
;        $fd/$fe = direction table pointer
; Clobbers: A, X, Y, $f7-$fe
;
GenerateSlidingCaptures:
  sta $f7
  stx $f8
  sty $fb
  lda #$00
  sta $f9

__ai_movegen_slide_cap_dir_loop_0:
  ldy $f9
  lda ($fd), y
  sta __ai_movegen_slidecap_delta_0+1; SMC: patch the step delta as an immediate
  lda $f7
  sta $fc; $fc = current square

__ai_movegen_slide_cap_loop_0:
  lda $fc
  clc
__ai_movegen_slidecap_delta_0:
  adc #$00; patched: step delta
  sta $fc
  and #OFFBOARD_MASK
  bne __ai_movegen_slide_cap_next_dir_0

  ldx $fc
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_movegen_slide_cap_loop_0

  and #WHITE_COLOR
  cmp $f8
  beq __ai_movegen_slide_cap_next_dir_0

  lda $f7
  ldx $fc
  jsr AddMove

__ai_movegen_slide_cap_next_dir_0:
  inc $f9
  lda $f9
  cmp $fb
  bne __ai_movegen_slide_cap_dir_loop_0
  rts

GenerateRookCaptures:
  pha
  lda #<OrthogonalOffsets
  sta $fd
  lda #>OrthogonalOffsets
  sta $fe
  pla
  ldy #$04
  jmp GenerateSlidingCaptures

GenerateBishopCaptures:
  pha
  lda #<DiagonalOffsets
  sta $fd
  lda #>DiagonalOffsets
  sta $fe
  pla
  ldy #$04
  jmp GenerateSlidingCaptures

GenerateQueenCaptures:
  pha
  lda #<AllDirectionOffsets
  sta $fd
  lda #>AllDirectionOffsets
  sta $fe
  pla
  ldy #$08
  jmp GenerateSlidingCaptures

;
; Generate capture-only king moves. Castling is intentionally excluded.
; Input: A = from square, X = side color
; Clobbers: A, X, $f7-$fa
;
GenerateKingCaptures:
  sta $f7
  sta __ai_movegen_kingcap_base_0+1; SMC: patch the (invariant) from square as base
  stx $f8
  lda #$00
  sta $f9

__ai_movegen_king_cap_loop_0:
  ldx $f9
__ai_movegen_kingcap_base_0:
  lda #$00; patched: from square ($f7)
  clc
  adc AllDirectionOffsets, x
  sta $fa
  and #OFFBOARD_MASK
  bne __ai_movegen_king_cap_next_0

  jsr AddCaptureIfEnemy

__ai_movegen_king_cap_next_0:
  inc $f9
  lda $f9
  cmp #$08
  bne __ai_movegen_king_cap_loop_0
  rts

;
; IsKillerMove
; Check if a move matches a killer for the current depth
; Input: A = from, X = to, Y = depth
; Output: Carry set = is killer, Carry clear = not killer
; Clobbers: $f0-$f2
;
IsKillerMove:
  sta $f0; from
  stx $f1; to

; Calculate offset: depth * 4
  tya
  cmp #MAX_KILLER_DEPTH
  bcs __ai_movegen_not_killer_0
  asl
  asl
  tay

; Check killer[0]
  lda KillerMoves, y
  cmp $f0
  bne __ai_movegen_check_killer_1_0
  lda KillerMoves + 1, y
  cmp $f1
  beq __ai_movegen_is_killer_0

__ai_movegen_check_killer_1_0:
; Check killer[1]
  lda KillerMoves + 2, y
  cmp $f0
  bne __ai_movegen_not_killer_0
  lda KillerMoves + 3, y
  cmp $f1
  bne __ai_movegen_not_killer_0

__ai_movegen_is_killer_0:
  sec
  rts

__ai_movegen_not_killer_0:
  clc
  rts
.endif
