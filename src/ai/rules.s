; Generated ca65 port from Chess/ai/rules.asm.
; Keep source changes in this repository in ca65 syntax.

; import-once was handled by the ca65 include topology

; Chess Rules Module
; Draw detection: 50-move rule, threefold repetition, insufficient material

.segment "CODE"

;
; UpdateHalfmoveClock
; Call after each move to update the 50-move rule counter
; Input: A = 1 if pawn moved, 0 otherwise
;        Carry set if capture occurred
; Resets clock on pawn move or capture, increments otherwise
;
UpdateHalfmoveClock:
  bcs __ai_rules_reset_clock_0; Capture - reset
  cmp #$01
  beq __ai_rules_reset_clock_0; Pawn move - reset

; Not pawn or capture - increment
  inc HalfmoveClock
  rts

__ai_rules_reset_clock_0:
  lda #$00
  sta HalfmoveClock
  rts

;
; CheckFiftyMoveRule
; Check if 50-move rule draw has been reached
; Output: Carry set = draw by 50-move rule
;         Carry clear = not a draw
;
CheckFiftyMoveRule:
  lda HalfmoveClock
  cmp #100; 50 moves = 100 half-moves
  bcs __ai_rules_fifty_draw_0
  clc
  rts
__ai_rules_fifty_draw_0:
  sec
  rts

;
; RecordPosition
; Store current position hash in history for repetition detection
; Call after each move
; Uses ZobristHash (2 bytes) from zobrist.asm
;
RecordPosition:
  ldx HistoryCount
  cpx #MAX_HISTORY
  bcs __ai_rules_history_full_0; Don't overflow

  lda ZobristHash
  sta PositionHistoryLo, x
  lda ZobristHash + 1
  sta PositionHistoryHi, x
  inc HistoryCount

__ai_rules_history_full_0:
  rts

;
; CheckRepetition
; Check if current position has occurred 3 times (threefold repetition)
; Output: Carry set = draw by repetition
;         Carry clear = not a draw
; Clobbers: A, X, Y
; Optimized: Loop check at bottom saves 1 cycle/iteration (up to 200 cycles)
;
CheckRepetition:
  lda #$00
  sta RepeatCount; Count occurrences
  ldx #$00; History index
  cpx HistoryCount; Handle empty history
  beq __ai_rules_check_rep_done_0

__ai_rules_check_rep_loop_0:
; Compare current hash with history[X]
  lda ZobristHash
  cmp PositionHistoryLo, x
  bne __ai_rules_rep_next_0
  lda ZobristHash + 1
  cmp PositionHistoryHi, x
  bne __ai_rules_rep_next_0

; Match found
  inc RepeatCount
  lda RepeatCount
  cmp #$03; 3 occurrences?
  bcs __ai_rules_repetition_draw_0

__ai_rules_rep_next_0:
  inx
  cpx HistoryCount; Check at bottom: BNE saves 1 cycle vs JMP
  bne __ai_rules_check_rep_loop_0

__ai_rules_check_rep_done_0:
  clc; No repetition draw
  rts

__ai_rules_repetition_draw_0:
  sec; Draw by repetition
  rts

RepeatCount:
  .byte $00

;
; ClearPositionHistory
; Reset history for new game
;
ClearPositionHistory:
  lda #$00
  sta HistoryCount
  sta HalfmoveClock
  rts

;
; CheckInsufficientMaterial
; Check if the position has insufficient material for checkmate
; Draws: K vs K, K+B vs K, K+N vs K, K+B vs K+B (same color)
; Output: Carry set = insufficient material (draw)
;         Carry clear = sufficient material
; Clobbers: A, X, Y, $e0-$e5
;
; Strategy: Count pieces by type. If only kings remain, or only
; king + minor piece vs king, it's insufficient.
;
; Optimized: Scans only the 64 valid 0x88 squares, skipping offboard gaps.
;
CheckInsufficientMaterial:
; Initialize piece counts
  lda #$00
  sta WhitePawnCnt
  sta WhiteKnightCnt
  sta WhiteBishopCnt
  sta WhiteRookCnt
  sta WhiteQueenCnt
  sta BlackPawnCnt
  sta BlackKnightCnt
  sta BlackBishopCnt
  sta BlackRookCnt
  sta BlackQueenCnt
  sta WhiteBishopSquare
  sta BlackBishopSquare

; Scan the 64 valid 0x88 squares.
  ldx #$00; Board index

__ai_rules_insuf_scan_loop_0:
; Check if empty (hot path: most valid squares are empty)
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_rules_insuf_next_sq_0; Empty - branch to nearby label (2 cycles vs 3)

; Has piece - process (cold path, ~16-32 pieces)
  jmp __ai_rules_process_piece_0

__ai_rules_insuf_next_sq_0:
  inx
  txa
  and #$08; Past file h in 0x88 layout?
  beq __ai_rules_insuf_check_done_0
  txa
  clc
  adc #$08; Skip offboard gap to next rank
  tax
__ai_rules_insuf_check_done_0:
  cpx #BOARD_SIZE
  bne __ai_rules_insuf_scan_loop_0; Branch back (2 cycles vs 3 for JMP)

__ai_rules_done_scan_0:
  jmp __ai_rules_evaluate_material_0

; Piece processing moved here to keep hot path tight
__ai_rules_process_piece_0:
; Save square for bishop color check
  stx TempSq

; Determine piece type and color
  pha; Save piece
  and #WHITE_COLOR; Get color bit
  sta TempColor; $80 = white, $00 = black
  pla; Restore piece
  and #$07; Get type (1-6)

; Increment appropriate counter
  cmp #PAWN_TYPE
  bne __ai_rules_not_pawn_insuf_0
  lda TempColor
  bne __ai_rules_white_pawn_insuf_0
  inc BlackPawnCnt
  jmp __ai_rules_insuf_next_sq_0
__ai_rules_white_pawn_insuf_0:
  inc WhitePawnCnt
  jmp __ai_rules_insuf_next_sq_0

__ai_rules_not_pawn_insuf_0:
  cmp #KNIGHT_TYPE
  bne __ai_rules_not_knight_insuf_0
  lda TempColor
  bne __ai_rules_white_knight_insuf_0
  inc BlackKnightCnt
  jmp __ai_rules_insuf_next_sq_0
__ai_rules_white_knight_insuf_0:
  inc WhiteKnightCnt
  jmp __ai_rules_insuf_next_sq_0

__ai_rules_not_knight_insuf_0:
  cmp #BISHOP_TYPE
  bne __ai_rules_not_bishop_insuf_0
; Save bishop square color for same-color bishop check
  lda TempSq
  jsr GetSquareColor; Returns $00 = dark, $01 = light
  sta TempBishopColor
  lda TempColor
  bne __ai_rules_white_bishop_insuf_0
  inc BlackBishopCnt
  lda TempBishopColor
  sta BlackBishopSquare
  jmp __ai_rules_insuf_next_sq_0
__ai_rules_white_bishop_insuf_0:
  inc WhiteBishopCnt
  lda TempBishopColor
  sta WhiteBishopSquare
  jmp __ai_rules_insuf_next_sq_0

__ai_rules_not_bishop_insuf_0:
  cmp #ROOK_TYPE
  bne __ai_rules_not_rook_insuf_0
  lda TempColor
  bne __ai_rules_white_rook_insuf_0
  inc BlackRookCnt
  jmp __ai_rules_insuf_next_sq_0
__ai_rules_white_rook_insuf_0:
  inc WhiteRookCnt
  jmp __ai_rules_insuf_next_sq_0

__ai_rules_not_rook_insuf_0:
  cmp #QUEEN_TYPE
  bne __ai_rules_is_king_insuf_0; Must be king, skip counting
  lda TempColor
  bne __ai_rules_white_queen_insuf_0
  inc BlackQueenCnt
  jmp __ai_rules_insuf_next_sq_0
__ai_rules_white_queen_insuf_0:
  inc WhiteQueenCnt
  jmp __ai_rules_insuf_next_sq_0

__ai_rules_is_king_insuf_0:
  jmp __ai_rules_insuf_next_sq_0

__ai_rules_evaluate_material_0:

; Now check for insufficient material
; First: any pawns, rooks, or queens = sufficient
  lda WhitePawnCnt
  ora BlackPawnCnt
  ora WhiteRookCnt
  ora BlackRookCnt
  ora WhiteQueenCnt
  ora BlackQueenCnt
  bne __ai_rules_sufficient_0

; Only kings, knights, and bishops left
; Calculate total minor pieces for each side
  lda WhiteKnightCnt
  clc
  adc WhiteBishopCnt
  sta WhiteMinorCnt

  lda BlackKnightCnt
  clc
  adc BlackBishopCnt
  sta BlackMinorCnt

; K vs K
  lda WhiteMinorCnt
  ora BlackMinorCnt
  beq __ai_rules_insufficient_0

; K + minor vs K (either side has 1 minor, other has 0)
  lda WhiteMinorCnt
  beq __ai_rules_check_black_lone_minor_0
  cmp #$01
  bne __ai_rules_check_two_bishops_0
  lda BlackMinorCnt
  beq __ai_rules_insufficient_0; White has 1 minor, black has none
  jmp __ai_rules_check_two_bishops_0

__ai_rules_check_black_lone_minor_0:
  lda BlackMinorCnt
  cmp #$01
  beq __ai_rules_insufficient_0; Black has 1 minor, white has none

__ai_rules_check_two_bishops_0:
; K + B vs K + B on same color squares
  lda WhiteMinorCnt
  cmp #$01
  bne __ai_rules_sufficient_0
  lda BlackMinorCnt
  cmp #$01
  bne __ai_rules_sufficient_0

; Both sides have exactly 1 minor piece
; Check if both are bishops on same color
  lda WhiteBishopCnt
  cmp #$01
  bne __ai_rules_sufficient_0
  lda BlackBishopCnt
  cmp #$01
  bne __ai_rules_sufficient_0

; Both sides have single bishop - check colors
  lda WhiteBishopSquare
  cmp BlackBishopSquare
  bne __ai_rules_sufficient_0; Different colors = can mate

__ai_rules_insufficient_0:
  sec; Insufficient material
  rts

__ai_rules_sufficient_0:
  clc; Sufficient material
  rts

;
; GetSquareColor
; Determine if a square is light or dark
; Input: A = 0x88 square index
; Output: A = 0 (dark) or 1 (light)
; Dark squares: a1, c1, e1, g1, b2, d2... (row XOR col) odd
; Light squares: b1, d1, f1, h1, a2, c2... (row XOR col) even
; Optimized: XOR trick avoids PHA/PLA, saves ~11 cycles
;
GetSquareColor:
  sta TempCol; Save square
  lsr; Shift right 4 times to get row in low nibble
  lsr
  lsr
  lsr
  eor TempCol; XOR with original: bit0 = (row bit0) XOR (col bit0)
  and #$01; Isolate parity bit
  eor #$01; Flip convention (0=dark, 1=light)
  rts

;
; IsCurrentKingAttacked
; Check if the current side's king (based on SearchSide) is under attack
; Output: Carry set = king is attacked, Carry clear = not attacked
; Clobbers: A
; Optimized: Extracted common code, reduces duplication by ~40 bytes
;
IsCurrentKingAttacked:
; Get king square based on SearchSide
  lda SearchSide
  bne __ai_rules_get_white_king_0
  lda blackkingsq
  bne __ai_rules_got_king_0; BNE always taken (king never at $00)
__ai_rules_get_white_king_0:
  lda whitekingsq
__ai_rules_got_king_0:
  sta attack_sq

; Set attacker color (opposite of SearchSide)
; If SearchSide=1 (white), attacker=black (0)
; If SearchSide=0 (black), attacker=white (1)
  lda SearchSide
  eor #$01; Flip: 0->1, 1->0
  sta attack_color
  jmp IsSquareAttacked; Tail call optimization: JMP instead of JSR+RTS

;
; AICheckGameState
; Comprehensive game state check for AI search combining all conditions
; Output: A = game state constant
;   GAME_NORMAL (0) = game continues normally
;   GAME_CHECK (1) = king in check, has moves
;   GAME_CHECKMATE (2) = checkmate
;   GAME_STALEMATE (3) = stalemate
;   GAME_DRAW_50_MOVE (4) = 50-move rule
;   GAME_DRAW_REPETITION (5) = threefold repetition
;   GAME_DRAW_INSUFFICIENT (6) = insufficient material
;
AICheckGameState:
; First check draws (before expensive move generation)
  jsr CheckFiftyMoveRule
  bcc __ai_rules_not_fifty_0
  lda #GAME_DRAW_50_MOVE
  rts

__ai_rules_not_fifty_0:
  jsr CheckRepetition
  bcc __ai_rules_not_repetition_0
  lda #GAME_DRAW_REPETITION
  rts

__ai_rules_not_repetition_0:
  jsr CheckInsufficientMaterial
  bcc __ai_rules_not_insufficient_0
  lda #GAME_DRAW_INSUFFICIENT
  rts

__ai_rules_not_insufficient_0:
; Generate legal moves to check for checkmate/stalemate
  jsr GenerateLegalMoves
  lda MoveCount
  bne __ai_rules_has_moves_0

; No moves - check if king is in check
  jsr IsCurrentKingAttacked
  bcc __ai_rules_stalemate_0

; King in check with no moves = checkmate
  lda #GAME_CHECKMATE
  rts

__ai_rules_stalemate_0:
  lda #GAME_STALEMATE
  rts

__ai_rules_has_moves_0:
; Has moves - check if in check
  jsr IsCurrentKingAttacked
  bcc __ai_rules_normal_0

  lda #GAME_CHECK
  rts

__ai_rules_normal_0:
  lda #GAME_NORMAL
  rts

; Temporary storage for insufficient material check
WhitePawnCnt:     .byte $00
WhiteKnightCnt:   .byte $00
WhiteBishopCnt:   .byte $00
WhiteRookCnt:     .byte $00
WhiteQueenCnt:    .byte $00
BlackPawnCnt:     .byte $00
BlackKnightCnt:   .byte $00
BlackBishopCnt:   .byte $00
BlackRookCnt:     .byte $00
BlackQueenCnt:    .byte $00
WhiteMinorCnt:    .byte $00
BlackMinorCnt:    .byte $00
WhiteBishopSquare: .byte $00
BlackBishopSquare: .byte $00
TempSq:           .byte $00
TempColor:        .byte $00
TempCol:          .byte $00
TempBishopColor:  .byte $00
