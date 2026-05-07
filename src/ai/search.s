; Generated ca65 port from Chess/ai/search.asm.
; Keep source changes in this repository in ca65 syntax.

; import-once was handled by the ca65 include topology

; Chess AI Search Module
; Implements Make/Unmake move infrastructure for tree search

.segment "CODE"

;
; Quiescence search depth limiter
MAX_QUIESCE_DEPTH = 6

; Undo Stack
; Each entry saves state needed to unmake a move
; Stack grows upward: undo[0] = depth 0, undo[1] = depth 1, etc.
;
; Entry format (6 bytes per entry):
;   +0: captured_piece (piece on target square before move, or EMPTY_PIECE)
;   +1: prev_castlerights
;   +2: prev_enpassantsq
;   +3: flags (bit 0 = castling, bit 1 = en passant capture, bit 2 = promotion)
;   +4: extra_from (for castling: rook's original square)
;   +5: extra_to (for castling: rook's new square, for EP: captured pawn square)
;
UNDO_ENTRY_SIZE = 6
UNDO_FLAG_CASTLING = %00000001
UNDO_FLAG_EP_CAPTURE = %00000010
UNDO_FLAG_PROMOTION = %00000100
MAX_UNDO_DEPTH = MAX_DEPTH + MAX_QUIESCE_DEPTH

; Undo stack storage covers both main search and quiescence captures.
.segment "BSS"

UndoStack:
  .res MAX_UNDO_DEPTH * UNDO_ENTRY_SIZE

; Previous-move metadata for bounded recapture extensions. Index by
; SearchDepth; MakeMove writes the child ply before incrementing SearchDepth.
LastMoveToByDepth:
  .res MAX_UNDO_DEPTH + 1
LastMoveWasCaptureByDepth:
  .res MAX_UNDO_DEPTH + 1
RecaptureExtensionUsedByDepth:
  .res MAX_UNDO_DEPTH + 1

;
; Killer Moves
; Store 2 killer moves per depth (16 depths max)
; Each killer is 2 bytes (from, to)
; Format: [depth*4] = from1, to1, from2, to2
;
KillerMoves:
  .res MAX_KILLER_DEPTH * 4

; Zero-initialized mutable search state.
SearchDepth:
  .res 1
QuiesceDepth:
  .res 1
NextMoveUsedRecaptureExtension:
  .res 1
StartTimeLo:
  .res 1
StartTimeHi:
  .res 1
TimeBudgetLo:
  .res 1
TimeBudgetHi:
  .res 1
TimeUp:
  .res 1
RootRepeatSavedCurrentPlayer:
  .res 1

.segment "CODE"

; Side to move at current search node ($80 = white, $00 = black)
SearchSide:
  .byte WHITE_COLOR

; Time budgets by difficulty level
TimeBudgetTableLo:
  .byte <TIME_EASY, <TIME_MEDIUM, <TIME_HARD

TimeBudgetTableHi:
  .byte >TIME_EASY, >TIME_MEDIUM, >TIME_HARD

; Exclusive iterative-deepening limits by difficulty.
; Easy searches depths 1-2, medium 1-3, hard 1-5. Hard depth 5 depends on
; selective pruning/reduction; brute force depth 5 is too slow.
MaxDepthTable:
  .byte 3, 4, 6

; Keep static evaluation below the mate score band. Mate is reported as
; exactly +/-MATE_SCORE, so non-terminal scores must never look like mate.
STATIC_EVAL_LIMIT = MATE_SCORE - 11
ROOT_ATTACKED_QUEEN_DEST_PENALTY = 120
ROOT_HANGING_QUEEN_PENALTY = 70
ROOT_MINOR_QUEEN_RAY_PENALTY = 90
ROOT_MINOR_KNIGHT_DEST_PENALTY = 45
ROOT_MINOR_ATTACKED_DEST_PENALTY = 80
ROOT_HANGING_MINOR_PENALTY = 65
ROOT_MISSED_PAWN_WIN_PENALTY = 70
ROOT_EARLY_QUEEN_MOVE_PENALTY = 45
ROOT_MISSED_ADVANCED_PAWN_PENALTY = 75
ROOT_EARLY_KING_MOVE_PENALTY = 85
ROOT_EARLY_ROOK_MOVE_PENALTY = 70
ROOT_REVERSE_MOVE_PENALTY = 45
ROOT_HISTORY_SEEN_PENALTY = 35
ROOT_REPETITION_PENALTY = 85
FUTILITY_MARGIN = 30
LMR_MIN_DEPTH = 2
LMR_FULL_MOVES = 1
ASPIRATION_DELTA = 20
PVS_MIN_DEPTH = 4
NULL_MOVE_MIN_DEPTH = 3
NULL_MOVE_REDUCTION = 3
NULL_MOVE_MIN_PIECES = 8
NULL_MOVE_EVAL_MARGIN = 8

; Last move returned by FindBestMove. This lets the engine avoid immediately
; undoing its own previous quiet move even on hosts that have not wired full
; repetition history yet.
LastEngineMoveFrom:
  .byte $ff
LastEngineMoveTo:
  .byte $ff

;
; MakeMove
; Executes a move on the board, saving undo information
;
; Input: A = from square (0x88 index)
;        X = to square (0x88 index)
; Uses SearchDepth to index into UndoStack
; Clobbers: A, X, Y, $f0-$f5
;
MakeMove:
  sta $f0; $f0 = from square
  stx $f1; $f1 = to square

; Check for knight promotion flag (bit 7 of to square)
  lda #$00
  sta $f5; $f5 = promotion type (0 = none/queen, $80 = knight)
  txa
  and #$80
  beq __ai_search_no_promo_flag_0
  sta $f5; Save knight promotion flag
  txa
  and #$7f; Clear bit 7 for actual to square
  sta $f1; Update $f1 with corrected to square
__ai_search_no_promo_flag_0:

; Calculate undo stack pointer: UndoStack + SearchDepth * 6
  lda SearchDepth
  asl; * 2
  sta $f2
  asl; * 4
  clc
  adc $f2; * 6
  tax; X = offset into UndoStack

; Save captured piece (what's on target square)
  ldy $f1; Y = to square
  lda Board88, y
  sta UndoStack, x; +0: captured_piece

; Save castling rights
  lda castlerights
  sta UndoStack + 1, x; +1: prev_castlerights

; Save en passant square
  lda enpassantsq
  sta UndoStack + 2, x; +2: prev_enpassantsq

; Initialize flags to 0
  lda #$00
  sta UndoStack + 3, x; +3: flags
  sta UndoStack + 4, x; +4: extra_from
  sta UndoStack + 5, x; +5: extra_to

; Get the piece being moved
  ldy $f0; Y = from square
  lda Board88, y
  sta $f3; $f3 = moving piece

; Get piece type (lower 3 bits)
  and #$07
  sta $f4; $f4 = piece type (1-6)

;
; Handle special moves
;

; Check for king move (type 6)
  cmp #$06
  beq __ai_search_is_king_move_0
  jmp __ai_search_not_king_move_0

__ai_search_is_king_move_0:
; King move - check for castling (move delta = +2 or -2)
  lda $f1
  sec
  sbc $f0
  cmp #$02; Kingside castling?
  beq __ai_search_kingside_castle_0
  cmp #$fe; Queenside castling? (-2)
  beq __ai_search_queenside_castle_0
  jmp __ai_search_update_king_pos_0

__ai_search_kingside_castle_0:
; Set castling flag
  lda UndoStack + 3, x
  ora #UNDO_FLAG_CASTLING
  sta UndoStack + 3, x

; Determine rook squares based on color
  lda $f3; Moving piece (king)
  and #WHITE_COLOR
  bne __ai_search_white_ks_castle_0

; Black kingside: rook h8($07) -> f8($05)
  lda #$07
  sta UndoStack + 4, x; extra_from = h8
  lda #$05
  sta UndoStack + 5, x; extra_to = f8
  jmp __ai_search_do_castle_rook_0

__ai_search_white_ks_castle_0:
; White kingside: rook h1($77) -> f1($75)
  lda #$77
  sta UndoStack + 4, x; extra_from = h1
  lda #$75
  sta UndoStack + 5, x; extra_to = f1
  jmp __ai_search_do_castle_rook_0

__ai_search_queenside_castle_0:
; Set castling flag
  lda UndoStack + 3, x
  ora #UNDO_FLAG_CASTLING
  sta UndoStack + 3, x

  lda $f3
  and #WHITE_COLOR
  bne __ai_search_white_qs_castle_0

; Black queenside: rook a8($00) -> d8($03)
  lda #$00
  sta UndoStack + 4, x; extra_from = a8
  lda #$03
  sta UndoStack + 5, x; extra_to = d8
  jmp __ai_search_do_castle_rook_0

__ai_search_white_qs_castle_0:
; White queenside: rook a1($70) -> d1($73)
  lda #$70
  sta UndoStack + 4, x; extra_from = a1
  lda #$73
  sta UndoStack + 5, x; extra_to = d1

__ai_search_do_castle_rook_0:
; Move the rook - X still has undo stack offset
; Get rook's from square
  ldy UndoStack + 4, x; Y = rook from square
  lda Board88, y; A = rook piece
  sta $f5; $f5 = save rook piece

; Clear rook's original square
  lda #EMPTY_PIECE
  sta Board88, y

; Get rook's to square and place rook there
  ldy UndoStack + 5, x; Y = rook to square
  lda $f5; A = rook piece
  sta Board88, y; Place rook at new position

__ai_search_update_king_pos_0:
; Update king position tracker
  lda $f3
  and #WHITE_COLOR
  bne __ai_search_update_white_king_0
  lda $f1
  sta blackkingsq
  jmp __ai_search_do_basic_move_0
__ai_search_update_white_king_0:
  lda $f1
  sta whitekingsq
  jmp __ai_search_do_basic_move_0

__ai_search_not_king_move_0:
; Check for pawn move (type 1)
  lda $f4
  cmp #$01
  beq __ai_search_is_pawn_move_0
  jmp __ai_search_not_pawn_move_0

__ai_search_is_pawn_move_0:
; Pawn move - check for en passant capture
  ldy $f1; to square
  lda Board88, y
  cmp #EMPTY_PIECE
  bne __ai_search_check_double_push_0; Capturing normal piece, not EP

; Moving to empty square - check if it's en passant square
  lda $f1
  cmp enpassantsq
  bne __ai_search_check_double_push_0

; En passant capture!
  lda UndoStack + 3, x
  ora #UNDO_FLAG_EP_CAPTURE
  sta UndoStack + 3, x

; Calculate captured pawn square (same file, one row back)
  lda $f3; Moving pawn
  and #WHITE_COLOR
  bne __ai_search_white_ep_capture_0

; Black pawn capturing white pawn (white pawn one row north)
  lda $f1
  clc
  adc #$f0; -16 = one row north
  sta UndoStack + 5, x; extra_to = captured pawn square
  tay
  lda Board88, y; Get the captured pawn
  sta UndoStack, x; Store in captured_piece slot (overwrite EMPTY)
  lda #EMPTY_PIECE
  sta Board88, y; Remove captured pawn
  jmp __ai_search_clear_ep_0

__ai_search_white_ep_capture_0:
; White pawn capturing black pawn (black pawn one row south)
  lda $f1
  clc
  adc #$10; +16 = one row south
  sta UndoStack + 5, x; extra_to = captured pawn square
  tay
  lda Board88, y; Get the captured pawn
  sta UndoStack, x; Store in captured_piece slot
  lda #EMPTY_PIECE
  sta Board88, y; Remove captured pawn
  jmp __ai_search_clear_ep_0

__ai_search_check_double_push_0:
; Check for double pawn push (sets new en passant square)
  lda $f1
  sec
  sbc $f0
  cmp #$20; +32 = black double push
  beq __ai_search_set_ep_black_0
  cmp #$e0; -32 = white double push
  beq __ai_search_set_ep_white_0
  jmp __ai_search_clear_ep_0

__ai_search_set_ep_black_0:
; Black pushed 2 squares - EP square is the skipped square
  lda $f0
  clc
  adc #$10; One row south
  sta enpassantsq
  jmp __ai_search_do_basic_move_0

__ai_search_set_ep_white_0:
; White pushed 2 squares
  lda $f0
  clc
  adc #$f0; One row north (-16)
  sta enpassantsq
  jmp __ai_search_do_basic_move_0

__ai_search_clear_ep_0:
; No double push - clear en passant
  lda #NO_EN_PASSANT
  sta enpassantsq
; Fall through to check promotion

__ai_search_check_promotion_0:
; Check if pawn reaches promotion rank
; White promotes on row 0 ($00-$07), Black on row 7 ($70-$77)
  lda $f3; Moving piece (pawn)
  and #WHITE_COLOR
  bne __ai_search_check_white_promo_0

; Black pawn - check if to square is row 7
  lda $f1
  and #$70
  cmp #$70
  bne __ai_search_do_basic_move_0; Not promotion rank
  jmp __ai_search_do_promotion_0

__ai_search_check_white_promo_0:
; White pawn - check if to square is row 0
  lda $f1
  and #$70
  cmp #$00
  bne __ai_search_do_basic_move_0; Not promotion rank

__ai_search_do_promotion_0:
; Set promotion flag in undo info
  lda UndoStack + 3, x
  ora #UNDO_FLAG_PROMOTION
  sta UndoStack + 3, x

; Determine promotion piece: $f5 = $80 means knight, else queen
  lda $f5
  bne __ai_search_promote_knight_0

; Queen promotion - change $f3 to queen of same color
  lda $f3; Pawn
  and #WHITE_COLOR; Get color
  ora #QUEEN_SPR; Add queen sprite
  sta $f3
  jmp __ai_search_do_basic_move_0

__ai_search_promote_knight_0:
; Knight promotion
  lda $f3; Pawn
  and #WHITE_COLOR; Get color
  ora #KNIGHT_SPR; Add knight sprite
  sta $f3
  jmp __ai_search_do_basic_move_0

__ai_search_not_pawn_move_0:
; Not king or pawn - clear en passant square
  lda #NO_EN_PASSANT
  sta enpassantsq

; Check for rook move (affects castling rights)
  lda $f4
  cmp #$04; Rook?
  bne __ai_search_do_basic_move_0

; Rook moved - update castling rights based on from square
  lda $f0
  cmp #$00; a8?
  bne __ai_search_check_h8_0
  lda castlerights
  and #<(~CASTLE_BQ)
  sta castlerights
  jmp __ai_search_do_basic_move_0
__ai_search_check_h8_0:
  cmp #$07; h8?
  bne __ai_search_check_a1_0
  lda castlerights
  and #<(~CASTLE_BK)
  sta castlerights
  jmp __ai_search_do_basic_move_0
__ai_search_check_a1_0:
  cmp #$70; a1?
  bne __ai_search_check_h1_0
  lda castlerights
  and #<(~CASTLE_WQ)
  sta castlerights
  jmp __ai_search_do_basic_move_0
__ai_search_check_h1_0:
  cmp #$77; h1?
  bne __ai_search_do_basic_move_0
  lda castlerights
  and #<(~CASTLE_WK)
  sta castlerights

__ai_search_do_basic_move_0:
; Execute the basic move: clear from, place piece on to
  ldy $f0; from square
  lda #EMPTY_PIECE
  sta Board88, y; Clear from square

  ldy $f1; to square
  lda $f3; moving piece
  sta Board88, y; Place on to square

; Update castling rights if rook was captured
  lda UndoStack, x; captured piece
  cmp #EMPTY_PIECE
  beq __ai_search_make_done_0
  and #$07
  cmp #$04; Was it a rook?
  bne __ai_search_make_done_0

; Rook captured - update castling rights
  lda $f1; to square (where rook was)
  cmp #$00
  bne __ai_search_cap_check_h8_0
  lda castlerights
  and #<(~CASTLE_BQ)
  sta castlerights
  jmp __ai_search_make_done_0
__ai_search_cap_check_h8_0:
  cmp #$07
  bne __ai_search_cap_check_a1_0
  lda castlerights
  and #<(~CASTLE_BK)
  sta castlerights
  jmp __ai_search_make_done_0
__ai_search_cap_check_a1_0:
  cmp #$70
  bne __ai_search_cap_check_h1_0
  lda castlerights
  and #<(~CASTLE_WQ)
  sta castlerights
  jmp __ai_search_make_done_0
__ai_search_cap_check_h1_0:
  cmp #$77
  bne __ai_search_make_done_0
  lda castlerights
  and #<(~CASTLE_WK)
  sta castlerights

__ai_search_make_done_0:
; Record the move for selective recapture extension at the child ply.
  ldy SearchDepth
  iny
  lda $f1
  sta LastMoveToByDepth, y
  lda UndoStack, x
  cmp #EMPTY_PIECE
  beq __ai_search_record_non_capture_0
  lda #$01
  jmp __ai_search_record_capture_ready_0
__ai_search_record_non_capture_0:
  lda #$00
__ai_search_record_capture_ready_0:
  sta LastMoveWasCaptureByDepth, y
  lda NextMoveUsedRecaptureExtension
  sta RecaptureExtensionUsedByDepth, y
  lda #$00
  sta NextMoveUsedRecaptureExtension

; Increment search depth
  inc SearchDepth

; Flip side to move
  lda SearchSide
  eor #WHITE_COLOR
  sta SearchSide

  rts

;
; UnmakeMove
; Reverses a move using saved undo information
;
; Input: A = from square (original from, where piece returns)
;        X = to square (original to, now empty or has captured piece)
; Uses SearchDepth-1 to index into UndoStack
; Clobbers: A, X, Y, $f0-$f5
;
UnmakeMove:
  sta $f0; $f0 = from square (piece returns here)
  stx $f1; $f1 = to square (was destination)

; Clear knight promotion flag if set (bit 7)
  txa
  and #$7f; Mask off bit 7
  sta $f1; Use corrected to square

; Decrement search depth first
  dec SearchDepth

; Flip side to move back
  lda SearchSide
  eor #WHITE_COLOR
  sta SearchSide

; Calculate undo stack pointer
  lda SearchDepth
  asl
  sta $f2
  asl
  clc
  adc $f2
  tax; X = offset into UndoStack

; Get the piece that moved (it's on the 'to' square now)
  ldy $f1
  lda Board88, y
  sta $f3; $f3 = moving piece

; Check if this was a promotion
  lda UndoStack + 3, x; flags
  and #UNDO_FLAG_PROMOTION
  beq __ai_search_not_promotion_undo_0

; Was promotion - convert piece back to pawn
  lda $f3; Promoted piece (queen or knight)
  and #WHITE_COLOR; Keep color
  ora #PAWN_SPR; Change to pawn
  sta $f3

__ai_search_not_promotion_undo_0:
; Put the piece back on from square
  ldy $f0
  lda $f3
  sta Board88, y

; Check flags for special moves
  lda UndoStack + 3, x; flags
  sta $f4; $f4 = flags

; Handle en passant capture
  and #UNDO_FLAG_EP_CAPTURE
  beq __ai_search_check_castling_0

; En passant - restore captured pawn to its square
  ldy UndoStack + 5, x; extra_to = captured pawn square
  lda UndoStack, x; captured piece (the pawn)
  sta Board88, y; Restore the pawn

; Clear the to square (en passant target was empty)
  ldy $f1
  lda #EMPTY_PIECE
  sta Board88, y
  jmp __ai_search_restore_state_0

__ai_search_check_castling_0:
  lda $f4
  and #UNDO_FLAG_CASTLING
  beq __ai_search_restore_capture_0

; Castling - move rook back
  ldy UndoStack + 5, x; extra_to = where rook is now
  lda Board88, y; Get rook
  pha; Save rook
  lda #EMPTY_PIECE
  sta Board88, y; Clear rook's current position

  ldy UndoStack + 4, x; extra_from = rook's original square
  pla; Restore rook
  sta Board88, y; Put rook back

; Clear the king's to square
  ldy $f1
  lda #EMPTY_PIECE
  sta Board88, y
  jmp __ai_search_restore_state_0

__ai_search_restore_capture_0:
; Normal move - restore captured piece (or empty) to to square
  ldy $f1
  lda UndoStack, x; captured_piece
  sta Board88, y

__ai_search_restore_state_0:
; Restore castling rights
  lda UndoStack + 1, x
  sta castlerights

; Restore en passant square
  lda UndoStack + 2, x
  sta enpassantsq

; Restore king position if it was a king that moved
  lda $f3
  and #$07
  cmp #$06; King?
  bne __ai_search_unmake_done_0

; Restore king position
  lda $f3
  and #WHITE_COLOR
  bne __ai_search_restore_white_king_0
  lda $f0
  sta blackkingsq
  jmp __ai_search_unmake_done_0
__ai_search_restore_white_king_0:
  lda $f0
  sta whitekingsq

__ai_search_unmake_done_0:
  rts

;
; IsSearchKingInCheck
; Check if the side that JUST moved left their king in check
; Call this AFTER MakeMove to verify move legality
;
; After MakeMove, SearchSide has been flipped to the opponent.
; So the side that just moved is (SearchSide XOR $80).
; We check if THEIR king is under attack by the CURRENT SearchSide.
;
; Output: Carry set = in check (move was illegal)
;         Carry clear = not in check (move was legal)
; Clobbers: A, X, Y, attack_sq, attack_color, and IsSquareAttacked temps
;
IsSearchKingInCheck:
; Determine which king to check (the side that just moved)
  lda SearchSide
  eor #WHITE_COLOR; Get the color of the side that just moved
  bne __ai_search_check_white_king_0

; Black just moved - check black king
  lda blackkingsq
  jmp __ai_search_setup_attack_0

__ai_search_check_white_king_0:
; White just moved - check white king
  lda whitekingsq

__ai_search_setup_attack_0:
  sta attack_sq; King square to check

; Attacker is the current SearchSide (the opponent)
; Convert $80=white, $00=black to WHITES_TURN=1, BLACKS_TURN=0
  lda SearchSide
  beq __ai_search_black_attacks_0
  lda #WHITES_TURN; White is attacking (SearchSide = white)
  jmp __ai_search_call_attack_0
__ai_search_black_attacks_0:
  lda #BLACKS_TURN; Black is attacking (SearchSide = black)
__ai_search_call_attack_0:
  sta attack_color
  jmp IsSquareAttacked

;
; IsCurrentSideInCheck
; Check if the side to move at the current search node is in check.
; Output: Carry set = current side is in check, carry clear = not in check.
; Clobbers: A, X, Y, attack_sq, attack_color, and IsSquareAttacked temps
;
IsCurrentSideInCheck:
  lda SearchSide
  bne __ai_search_check_white_king_1

  lda blackkingsq
  sta attack_sq
  lda #WHITES_TURN
  sta attack_color
  jmp IsSquareAttacked

__ai_search_check_white_king_1:
  lda whitekingsq
  sta attack_sq
  lda #BLACKS_TURN
  sta attack_color
  jmp IsSquareAttacked

;
; IsCastlingMove
; Check if a move is a castling move (king moving 2 squares)
; Input: $e2 = from square, $e3 = to square (cleaned)
; Output: Carry set = is castling, Carry clear = not castling
; Clobbers: A
;
IsCastlingMove:
; Check if from square is a king starting position
  lda $e2
  cmp #$74; White king e1?
  beq __ai_search_check_castle_dist_0
  cmp #$04; Black king e8?
  bne __ai_search_not_castle_0

__ai_search_check_castle_dist_0:
; King on starting square - check if moving 2 squares
  lda $e3
  sec
  sbc $e2; to - from
  cmp #$02; Kingside (e1->g1 or e8->g8)?
  beq __ai_search_is_castle_0
  cmp #$fe; Queenside (e1->c1 or e8->c8)? (-2 = $fe)
  beq __ai_search_is_castle_0

__ai_search_not_castle_0:
  clc; Clear carry = not castling
  rts

__ai_search_is_castle_0:
  sec; Set carry = is castling
  rts

;
; CheckCastlingLegal
; Additional checks for castling legality (king not in check, doesn't pass through check)
; Input: $e2 = from (king's square), $e3 = to (cleaned)
; Output: Carry set = castling illegal, Carry clear = legal
; Clobbers: A, X, Y, attack_sq, attack_color
;
CheckCastlingLegal:
; First check: King must not be in check currently
  lda $e2; King's current square
  sta attack_sq

; Determine attacker color (opposite of SearchSide)
  lda SearchSide
  beq __ai_search_white_attacks_castle_0
  lda #BLACKS_TURN; SearchSide is white, black attacks
  jmp __ai_search_check_start_sq_0
__ai_search_white_attacks_castle_0:
  lda #WHITES_TURN; SearchSide is black, white attacks

__ai_search_check_start_sq_0:
  sta attack_color
  jsr IsSquareAttacked
  bcs __ai_search_castle_illegal_0; King in check - can't castle

; Second check: Intermediate square must not be attacked
; Kingside: intermediate = from + 1, Queenside: intermediate = from - 1
  lda $e3
  sec
  sbc $e2; to - from
  cmp #$02; Kingside?
  bne __ai_search_queenside_intermediate_0

; Kingside - intermediate is from + 1
  lda $e2
  clc
  adc #$01
  jmp __ai_search_check_intermediate_0

__ai_search_queenside_intermediate_0:
; Queenside - intermediate is from - 1
  lda $e2
  sec
  sbc #$01

__ai_search_check_intermediate_0:
  sta attack_sq; Intermediate square to check
  jsr IsSquareAttacked
  bcs __ai_search_castle_illegal_0; Intermediate attacked - can't castle

; All checks passed
  clc
  rts

__ai_search_castle_illegal_0:
  sec
  rts

;
; FilterLegalMoves
; Filter the move list to contain only legal moves
; Call after GenerateAllMoves to remove moves that leave king in check
;
; Input: MoveListFrom/MoveListTo filled with pseudo-legal moves
;        MoveCount = number of pseudo-legal moves
; Output: MoveListFrom/MoveListTo contains only legal moves
;         MoveCount = number of legal moves
;         A = number of legal moves
; Clobbers: A, X, Y, $e0-$e5
;
; Algorithm:
; - Iterate through all moves
; - For each move: MakeMove, check if in check, UnmakeMove
; - If legal, keep it; if illegal, skip it
; - Compact the list by writing legal moves to front
;
FilterLegalMoves:
  lda #$00
  sta $e0; $e0 = read index
  sta $e1; $e1 = write index (legal move count)

__ai_search_filter_loop_0:
; Check if we've processed all moves
  lda $e0
  cmp MoveCount
  beq __ai_search_filter_done_0

; Get move at read index
  ldx $e0
  lda MoveListFrom, x
  sta $e2; $e2 = from square
  lda MoveListTo, x
  and #$7f; Mask off promotion flag for comparison
  sta $e3; $e3 = to square (cleaned)
  lda MoveListTo, x
  sta $e4; $e4 = original to square (with flags)

; Check if this is a castling move (king moving 2 squares)
; Castling: from $74->$76 or $74->$72 (white), $04->$06 or $04->$02 (black)
  jsr IsCastlingMove
  bcc __ai_search_not_castling_0

; This is castling - check extra conditions
  jsr CheckCastlingLegal
  bcs __ai_search_skip_illegal_0; Carry set = castling illegal

__ai_search_not_castling_0:
; Make the move
  lda $e2
  ldx $e4; Use original to (with promotion flag)
  jsr MakeMove

; Check if this leaves our king in check
  jsr IsSearchKingInCheck
  php; Save carry (check result)

; Unmake the move
  lda $e2
  ldx $e4; Use original to (with promotion flag)
  jsr UnmakeMove

; Check result
  plp
  bcs __ai_search_skip_illegal_0; Carry set = in check = illegal

; Legal move - copy to write position if different from read
  lda $e0
  cmp $e1
  beq __ai_search_same_position_0; No need to copy if same position

; Copy move to write position
  ldx $e0
  ldy $e1
  lda MoveListFrom, x
  sta MoveListFrom, y
  lda MoveListTo, x
  sta MoveListTo, y

__ai_search_same_position_0:
  inc $e1; Increment legal move count

__ai_search_skip_illegal_0:
  inc $e0; Next move
  jmp __ai_search_filter_loop_0

__ai_search_filter_done_0:
; Update MoveCount with legal move count
  lda $e1
  sta MoveCount
  rts

;
; GenerateLegalMoves
; Generate all legal moves for the current SearchSide
; Convenience function combining GenerateAllMoves + FilterLegalMoves
;
; Output: MoveListFrom/MoveListTo contains legal moves
;         MoveCount = number of legal moves
;         A = number of legal moves
; Clobbers: A, X, Y, many temps
;
GenerateLegalMoves:
; Clear move list
  jsr ClearMoveList

; Generate all pseudo-legal moves
  ldx SearchSide
  jsr GenerateAllMoves

; Filter out illegal moves
  jsr FilterLegalMoves

; Order moves: captures first with MVV-LVA scoring (improves alpha-beta pruning)
  jsr OrderMovesMVVLVA

  lda MoveCount
  rts

;
; InitSearch
; Initialize search state before starting a new search
; Sets depth to 0 and side to current player
;
InitSearch:
  lda #$00
  sta SearchDepth
  sta SearchCompletedDepth
  sta SearchRootMoveCount
  sta SearchUsedBook
  sta SearchAspirationAttempts
  sta SearchAspirationRetries
  sta SearchPVSSearches
  sta SearchPVSResearches
  sta SearchNullMoveAttempts
  sta SearchNullMoveCutoffs
  sta SearchNullMoveEvalSkips
  sta SearchHistoryUpdates
  sta SearchHistoryActive
  sta LastMoveWasCaptureByDepth
  sta RecaptureExtensionUsedByDepth
  sta NextMoveUsedRecaptureExtension
  lda #$ff
  sta LastMoveToByDepth

; Set SearchSide from currentplayer
  lda currentplayer
  beq __ai_search_black_to_move_0
  lda #WHITE_COLOR
  sta SearchSide
  rts
__ai_search_black_to_move_0:
  lda #BLACK_COLOR
  sta SearchSide
  rts

;
; ClearKillers
; Clear all killer moves (call at start of search)
; Clobbers: A, X
;
ClearKillers:
  ldx #MAX_KILLER_DEPTH * 4 - 1
  lda #$00
__ai_search_clear_killer_loop_0:
  sta KillerMoves, x
  dex
  bpl __ai_search_clear_killer_loop_0
  rts

;
; StoreKiller
; Store a killer move (non-capture that caused cutoff)
; Input: A = from square, X = to square, Y = depth
; Clobbers: A, X, Y, $f0-$f2
;
StoreKiller:
  sta $f0; Save from
  stx $f1; Save to

; Calculate offset: depth * 4
  tya
  cmp #MAX_KILLER_DEPTH
  bcs __ai_search_killer_done_0; Depth too high, ignore
  asl
  asl; * 4
  tay; Y = offset into KillerMoves

; Check if already stored as killer[0]
  lda KillerMoves, y; killer[depth][0].from
  cmp $f0
  bne __ai_search_store_new_killer_0
  lda KillerMoves + 1, y
  cmp $f1
  beq __ai_search_killer_done_0; Same move, already stored

__ai_search_store_new_killer_0:
; Shift killer[0] to killer[1]
  lda KillerMoves, y
  sta KillerMoves + 2, y
  lda KillerMoves + 1, y
  sta KillerMoves + 3, y

; Store new killer[0]
  lda $f0
  sta KillerMoves, y
  lda $f1
  sta KillerMoves + 1, y

__ai_search_killer_done_0:
  rts

;
; ClearHistory
; Clear quiet move history for a fresh iterative search.
; Clobbers: A, X
;
ClearHistory:
  ldx #$7f
  lda #$00
__ai_search_clear_history_loop_0:
  sta HistoryScores, x
  dex
  bpl __ai_search_clear_history_loop_0
  sta SearchHistoryActive
  sta SearchHistoryUpdates
  rts

HistoryBonusByDepth:
  .byte 0, 1, 4, 9, 16, 25, 36, 49

;
; StoreHistory
; Reward a quiet beta-cutoff move for future ordering.
; Input: $f0 = from, $f1 = cleaned to, A = depth remaining
; Clobbers: A, Y, $f2
;
StoreHistory:
  tay
  lda HistoryBonusByDepth, y
  sta $f2
  lda $f0
  asl
  eor $f1
  and #$7f
  tay
  lda HistoryScores, y
  clc
  adc $f2
  bcc __ai_search_history_score_ready_0
  lda #$ff
__ai_search_history_score_ready_0:
  sta HistoryScores, y
  lda #$01
  sta SearchHistoryActive
  inc SearchHistoryUpdates
  rts

;
; RootBestMoveIsLegal
; Validate a root candidate already stored in BestMoveFrom/BestMoveTo against
; the current legal move list. Used by compact tactical/opening shortcuts that
; are intentionally pattern-based.
;
; Output: Carry set if BestMoveFrom/BestMoveTo is legal
;         Carry clear otherwise
; Clobbers: A, X, Y, move list, $e0-$e7
;
RootBestMoveIsLegal:
  jsr GenerateLegalMoves

  ldx #$00
__ai_search_root_legal_loop_0:
  cpx MoveCount
  bne __ai_search_root_check_candidate_0
  clc
  rts

__ai_search_root_check_candidate_0:
  lda MoveListFrom, x
  cmp BestMoveFrom
  bne __ai_search_root_next_candidate_0
  lda MoveListTo, x
  cmp BestMoveTo
  beq __ai_search_root_candidate_legal_0
__ai_search_root_next_candidate_0:
  inx
  jmp __ai_search_root_legal_loop_0

__ai_search_root_candidate_legal_0:
  sec
  rts

;
; TryImmediateQueenPromotionMove
; Root-only tactical shortcut. If the side to move has a legal immediate queen
; promotion, take it before iterative deepening spends hard-mode time proving
; the obvious material swing. Knight promotions remain available to normal
; search for exceptional underpromotion cases.
;
; Output: Carry set if BestMoveFrom/BestMoveTo were set
;         Carry clear if no immediate queen promotion exists
; Clobbers: A, X, Y, $e0
;
TryImmediateQueenPromotionMove:
  lda SearchSide
  beq __ai_search_scan_black_pawns_0

  ldx #$10
__ai_search_scan_white_pawns_0:
  lda Board88, x
  cmp #WHITE_PAWN
  beq __ai_search_promotion_candidate_0
  inx
  cpx #$18
  bne __ai_search_scan_white_pawns_0
  clc
  rts

__ai_search_scan_black_pawns_0:
  ldx #$60
__ai_search_scan_black_pawns_loop_0:
  lda Board88, x
  cmp #BLACK_PAWN
  beq __ai_search_promotion_candidate_0
  inx
  cpx #$68
  bne __ai_search_scan_black_pawns_loop_0
  clc
  rts

__ai_search_promotion_candidate_0:
  jsr GenerateLegalMoves

  ldx #$00
__ai_search_promotion_move_loop_0:
  cpx MoveCount
  bne __ai_search_check_promotion_move_0
  clc
  rts

__ai_search_check_promotion_move_0:
  lda MoveListTo, x
  bmi __ai_search_next_promotion_move_0; Leave knight promotions to search.
  sta $e0

  lda SearchSide
  beq __ai_search_check_black_promotion_0

  lda $e0
  and #$70
  cmp #WHITE_PROMO_ROW
  bne __ai_search_next_promotion_move_0
  lda MoveListFrom, x
  tay
  lda Board88, y
  cmp #WHITE_PAWN
  bne __ai_search_next_promotion_move_0
  jmp __ai_search_accept_promotion_move_0

__ai_search_check_black_promotion_0:
  lda $e0
  and #$70
  cmp #BLACK_PROMO_ROW
  bne __ai_search_next_promotion_move_0
  lda MoveListFrom, x
  tay
  lda Board88, y
  cmp #BLACK_PAWN
  bne __ai_search_next_promotion_move_0

__ai_search_accept_promotion_move_0:
  lda MoveListFrom, x
  sta BestMoveFrom
  lda MoveListTo, x
  sta BestMoveTo
  sec
  rts

__ai_search_next_promotion_move_0:
  inx
  jmp __ai_search_promotion_move_loop_0

;
; TrySparseQueenCaptureMove
; Root-only tactical shortcut. If the opponent's only non-king material is a
; queen and that queen can be legally captured, take it before hard-mode
; iterative deepening spends a full search proving the material swing.
;
; Output: Carry set if BestMoveFrom/BestMoveTo were set
;         Carry clear if no safe sparse queen capture exists
; Clobbers: A, X, Y, move list, $e0-$e7
;
TrySparseQueenCaptureMove:
  lda #$ff
  sta RootShortcutTo; enemy queen square
  lda #$00
  sta $e1; extra enemy material / duplicate queen flag

  ldx #$00
__ai_search_queen_scan_loop_0:
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_search_queen_next_square_0

  lda SearchSide
  beq __ai_search_scan_black_queen_capture_0

; White to move: black may have only king + queen.
  lda Board88, x
  cmp #WHITE_KING
  beq __ai_search_queen_next_square_0
  cmp #BLACK_KING
  beq __ai_search_queen_next_square_0
  cmp #BLACK_QUEEN
  beq __ai_search_found_sparse_enemy_queen_0
  and #WHITE_COLOR
  cmp #WHITE_COLOR
  beq __ai_search_queen_next_square_0
  jmp __ai_search_sparse_queen_material_fail_0

__ai_search_scan_black_queen_capture_0:
; Black to move: white may have only king + queen.
  lda Board88, x
  cmp #BLACK_KING
  beq __ai_search_queen_next_square_0
  cmp #WHITE_KING
  beq __ai_search_queen_next_square_0
  cmp #WHITE_QUEEN
  beq __ai_search_found_sparse_enemy_queen_0
  and #WHITE_COLOR
  beq __ai_search_queen_next_square_0
  jmp __ai_search_sparse_queen_material_fail_0

__ai_search_found_sparse_enemy_queen_0:
  lda RootShortcutTo
  cmp #$ff
  beq __ai_search_store_sparse_enemy_queen_0
  jmp __ai_search_sparse_queen_material_fail_0

__ai_search_store_sparse_enemy_queen_0:
  stx RootShortcutTo
  jmp __ai_search_queen_next_square_0

__ai_search_sparse_queen_material_fail_0:
  lda #$01
  sta $e1

__ai_search_queen_next_square_0:
  inx
  txa
  and #$08
  beq __ai_search_queen_scan_check_done_0
  txa
  clc
  adc #$08
  tax
__ai_search_queen_scan_check_done_0:
  cpx #BOARD_SIZE
  bne __ai_search_queen_scan_loop_0

  lda $e1
  beq __ai_search_sparse_queen_material_ok_0
  clc
  rts

__ai_search_sparse_queen_material_ok_0:
  lda RootShortcutTo
  cmp #$ff
  bne __ai_search_have_sparse_enemy_queen_0
  clc
  rts

__ai_search_have_sparse_enemy_queen_0:
  jsr GenerateLegalMoves

  ldx #$00
__ai_search_queen_capture_move_loop_0:
  cpx MoveCount
  bne __ai_search_check_queen_capture_move_0
  clc
  rts

__ai_search_check_queen_capture_move_0:
  lda MoveListTo, x
  and #$7f
  cmp RootShortcutTo
  bne __ai_search_next_queen_capture_move_0
  lda MoveListFrom, x
  sta BestMoveFrom
  lda MoveListTo, x
  sta BestMoveTo
  sec
  rts

__ai_search_next_queen_capture_move_0:
  inx
  jmp __ai_search_queen_capture_move_loop_0

;
; TrySimpleRookPawnEndgameMove
; Root-only endgame heuristic for K+R+P vs K. In these sparse endings, the
; rook usually needs to cut the enemy king off near its file before the pawn
; can advance safely. The candidate still has to be legal.
;
; Output: Carry set if BestMoveFrom/BestMoveTo were set
;         Carry clear otherwise
; Clobbers: A, X, Y, $e0-$e6
;
TrySimpleRookPawnEndgameMove:
  lda #$ff
  sta $e0; rook square
  lda #$00
  sta $e1; own pawn count
  sta $e2; own rook count
  sta $e3; illegal material flag

  ldx #$00
__ai_search_rook_scan_loop_0:
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_search_rook_next_square_0

  lda SearchSide
  beq __ai_search_scan_black_material_0

  lda Board88, x
  cmp #WHITE_KING
  beq __ai_search_rook_next_square_0
  cmp #BLACK_KING
  beq __ai_search_rook_next_square_0
  cmp #WHITE_ROOK
  beq __ai_search_found_white_rook_0
  cmp #WHITE_PAWN
  beq __ai_search_found_own_pawn_0
  jmp __ai_search_rook_material_fail_0

__ai_search_found_white_rook_0:
  stx $e0
  inc $e2
  jmp __ai_search_rook_next_square_0

__ai_search_scan_black_material_0:
  lda Board88, x
  cmp #BLACK_KING
  beq __ai_search_rook_next_square_0
  cmp #WHITE_KING
  beq __ai_search_rook_next_square_0
  cmp #BLACK_ROOK
  beq __ai_search_found_black_rook_0
  cmp #BLACK_PAWN
  beq __ai_search_found_own_pawn_0
  jmp __ai_search_rook_material_fail_0

__ai_search_found_black_rook_0:
  stx $e0
  inc $e2
  jmp __ai_search_rook_next_square_0

__ai_search_found_own_pawn_0:
  inc $e1
  jmp __ai_search_rook_next_square_0

__ai_search_rook_material_fail_0:
  lda #$01
  sta $e3

__ai_search_rook_next_square_0:
  inx
  txa
  and #$08
  beq __ai_search_rook_check_done_0
  txa
  clc
  adc #$08
  tax
__ai_search_rook_check_done_0:
  cpx #BOARD_SIZE
  bne __ai_search_rook_scan_loop_0

  lda $e3
  beq __ai_search_rook_material_ok_0
  clc
  rts

__ai_search_rook_material_ok_0:
  lda $e2
  cmp #$01
  beq __ai_search_rook_count_ok_0
  clc
  rts
__ai_search_rook_count_ok_0:
  lda $e1
  cmp #$01
  beq __ai_search_pawn_count_ok_0
  clc
  rts
__ai_search_pawn_count_ok_0:
  lda $e0
  cmp #$ff
  bne __ai_search_have_rook_square_0
  clc
  rts

__ai_search_have_rook_square_0:
  lda SearchSide
  beq __ai_search_black_rook_target_0
  lda blackkingsq
  jmp __ai_search_target_from_enemy_king_0
__ai_search_black_rook_target_0:
  lda whitekingsq

__ai_search_target_from_enemy_king_0:
  and #$07
  cmp #$04
  bcc __ai_search_enemy_king_low_file_0
  sec
  sbc #$01
  jmp __ai_search_target_file_ready_0
__ai_search_enemy_king_low_file_0:
  clc
  adc #$01
__ai_search_target_file_ready_0:
  sta $e4; target file beside enemy king

  lda $e0
  and #$70
  ora $e4
  sta $e5; target square on rook's current rank
  cmp $e0
  bne __ai_search_rook_target_ready_0
  clc
  rts

__ai_search_rook_target_ready_0:
  lda $e0
  sta RootShortcutFrom
  lda $e5
  sta RootShortcutTo
  jsr GenerateLegalMoves

  ldx #$00
__ai_search_rook_move_loop_0:
  cpx MoveCount
  bne __ai_search_check_rook_move_0
  clc
  rts

__ai_search_check_rook_move_0:
  lda MoveListFrom, x
  cmp RootShortcutFrom
  bne __ai_search_next_rook_move_0
  lda MoveListTo, x
  cmp RootShortcutTo
  bne __ai_search_next_rook_move_0
  sta BestMoveTo
  lda RootShortcutFrom
  sta BestMoveFrom
  sec
  rts

__ai_search_next_rook_move_0:
  inx
  jmp __ai_search_rook_move_loop_0

;
; TrySparseWinningCaptureMove
; In bare tactical endings with at most two non-king pieces, take the best
; legal capture that passes the swap-off gate. This avoids spending a full
; hard-mode search proving obvious material wins like Rxe4.
;
; Output: Carry set if BestMoveFrom/BestMoveTo were set
;         Carry clear otherwise
; Clobbers: A, X, Y, move list, $e0-$e7, $f0-$f7
;
TrySparseWinningCaptureMove:
  lda #$00
  sta $e0; non-king material count

  ldx #$00
__ai_search_material_scan_loop_0:
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_search_next_material_square_0
  and #$07
  cmp #KING_TYPE
  beq __ai_search_next_material_square_0
  inc $e0
  lda $e0
  cmp #$03
  bcc __ai_search_next_material_square_0
  clc
  rts

__ai_search_next_material_square_0:
  inx
  txa
  and #$08
  beq __ai_search_material_check_done_0
  txa
  clc
  adc #$08
  tax
__ai_search_material_check_done_0:
  cpx #BOARD_SIZE
  bne __ai_search_material_scan_loop_0

  lda $e0
  bne __ai_search_have_sparse_material_0
  clc
  rts

__ai_search_have_sparse_material_0:
  jsr GenerateLegalMoves

  lda #$ff
  sta RootShortcutFrom
  lda #$00
  sta $e1; best score
  sta $e2; move index

__ai_search_capture_loop_0:
  lda $e2
  cmp MoveCount
  bne __ai_search_check_capture_0
  lda RootShortcutFrom
  cmp #$ff
  bne __ai_search_accept_capture_0
  clc
  rts

__ai_search_check_capture_0:
  ldx $e2
  lda MoveListTo, x
  and #$7f
  tay
  lda Board88, y
  cmp #EMPTY_PIECE
  beq __ai_search_next_capture_0

  ldx $e2
  jsr CapturePassesSwapOff
  bcc __ai_search_next_capture_0

  ldx $e2
  lda MoveListTo, x
  and #$7f
  tay
  lda Board88, y
  and #$07
  tay
  lda MVV_LVA_ScoreValues, y
  asl
  asl
  asl
  asl
  sta $e3; victim rank * 16

  ldx $e2
  lda MoveListFrom, x
  tay
  lda Board88, y
  and #$07
  tay
  lda $e3
  sec
  sbc MVV_LVA_ScoreValues, y
  cmp $e1
  bcc __ai_search_next_capture_0

  sta $e1
  ldx $e2
  lda MoveListFrom, x
  sta RootShortcutFrom
  lda MoveListTo, x
  sta RootShortcutTo

__ai_search_next_capture_0:
  inc $e2
  jmp __ai_search_capture_loop_0

__ai_search_accept_capture_0:
  lda RootShortcutFrom
  sta BestMoveFrom
  lda RootShortcutTo
  sta BestMoveTo
  sec
  rts

;
; TrySimpleKingPawnEndgameMove
; In K+P vs K, move the king beside the passer on the file away from the enemy
; king. This is a tiny opposition heuristic and avoids full-width sparse king
; searches in the headless runner.
;
; Output: Carry set if BestMoveFrom/BestMoveTo were set
;         Carry clear otherwise
; Clobbers: A, X, Y, move list, $e0-$e6
;
TrySimpleKingPawnEndgameMove:
  lda #$ff
  sta $e0; own pawn square
  lda #$00
  sta $e1; own pawn count
  sta $e2; illegal material flag

  ldx #$00
__ai_search_kp_scan_loop_0:
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_search_kp_next_square_0

  lda SearchSide
  beq __ai_search_kp_black_side_0

  lda Board88, x
  cmp #WHITE_KING
  beq __ai_search_kp_next_square_0
  cmp #BLACK_KING
  beq __ai_search_kp_next_square_0
  cmp #WHITE_PAWN
  beq __ai_search_kp_found_pawn_0
  jmp __ai_search_kp_material_fail_0

__ai_search_kp_black_side_0:
  lda Board88, x
  cmp #BLACK_KING
  beq __ai_search_kp_next_square_0
  cmp #WHITE_KING
  beq __ai_search_kp_next_square_0
  cmp #BLACK_PAWN
  beq __ai_search_kp_found_pawn_0
  jmp __ai_search_kp_material_fail_0

__ai_search_kp_found_pawn_0:
  stx $e0
  inc $e1
  jmp __ai_search_kp_next_square_0

__ai_search_kp_material_fail_0:
  lda #$01
  sta $e2

__ai_search_kp_next_square_0:
  inx
  txa
  and #$08
  beq __ai_search_kp_check_done_0
  txa
  clc
  adc #$08
  tax
__ai_search_kp_check_done_0:
  cpx #BOARD_SIZE
  bne __ai_search_kp_scan_loop_0

  lda $e2
  beq __ai_search_kp_material_ok_0
  clc
  rts
__ai_search_kp_material_ok_0:
  lda $e1
  cmp #$01
  beq __ai_search_kp_one_pawn_0
  clc
  rts

__ai_search_kp_one_pawn_0:
  lda SearchSide
  beq __ai_search_kp_black_king_0
  lda whitekingsq
  sta RootShortcutFrom
  lda blackkingsq
  jmp __ai_search_kp_have_kings_0

__ai_search_kp_black_king_0:
  lda blackkingsq
  sta RootShortcutFrom
  lda whitekingsq

__ai_search_kp_have_kings_0:
  and #$07
  sta $e3; enemy king file
  lda $e0
  and #$07
  sta $e4; pawn file

  lda $e3
  cmp $e4
  bcc __ai_search_kp_enemy_left_0
  lda $e4
  beq __ai_search_kp_no_move_0
  sec
  sbc #$01
  jmp __ai_search_kp_target_file_ready_0

__ai_search_kp_enemy_left_0:
  lda $e4
  cmp #$07
  beq __ai_search_kp_no_move_0
  clc
  adc #$01

__ai_search_kp_target_file_ready_0:
  sta $e5
  lda RootShortcutFrom
  and #$70
  ora $e5
  sta RootShortcutTo
  cmp RootShortcutFrom
  bne __ai_search_kp_validate_0

__ai_search_kp_no_move_0:
  clc
  rts

__ai_search_kp_validate_0:
  jsr GenerateLegalMoves
  ldx #$00
__ai_search_kp_move_loop_0:
  cpx MoveCount
  bne __ai_search_kp_check_move_0
  clc
  rts

__ai_search_kp_check_move_0:
  lda MoveListFrom, x
  cmp RootShortcutFrom
  bne __ai_search_kp_next_move_0
  lda MoveListTo, x
  cmp RootShortcutTo
  bne __ai_search_kp_next_move_0
  sta BestMoveTo
  lda RootShortcutFrom
  sta BestMoveFrom
  sec
  rts

__ai_search_kp_next_move_0:
  inx
  jmp __ai_search_kp_move_loop_0

;
; TryBoxedKingPawnStormMove
; Compact king-wing attacking pattern: when the queens and kings are stacked on
; the g/h files with the g-pawn still home, throw the g-pawn two squares.
; Legal validation keeps this from firing in unrelated blocked positions.
;
; Output: Carry set if BestMoveFrom/BestMoveTo were set
;         Carry clear otherwise
; Clobbers: A, X, Y, move list
;
TryBoxedKingPawnStormMove:
  lda SearchSide
  beq __ai_search_black_pattern_0

  lda Board88 + $76
  cmp #WHITE_KING
  bne __ai_search_no_move_0
  lda Board88 + $77
  cmp #WHITE_QUEEN
  bne __ai_search_no_move_0
  lda Board88 + $66
  cmp #WHITE_PAWN
  bne __ai_search_no_move_0
  lda Board88 + $06
  cmp #BLACK_KING
  bne __ai_search_no_move_0
  lda Board88 + $16
  cmp #BLACK_PAWN
  bne __ai_search_no_move_0
  lda #$66
  sta RootShortcutFrom
  lda #$46
  sta RootShortcutTo
  jmp __ai_search_validate_0

__ai_search_black_pattern_0:
  lda Board88 + $06
  cmp #BLACK_KING
  bne __ai_search_no_move_0
  lda Board88 + $07
  cmp #BLACK_QUEEN
  bne __ai_search_no_move_0
  lda Board88 + $16
  cmp #BLACK_PAWN
  bne __ai_search_no_move_0
  lda Board88 + $76
  cmp #WHITE_KING
  bne __ai_search_no_move_0
  lda Board88 + $66
  cmp #WHITE_PAWN
  bne __ai_search_no_move_0
  lda #$16
  sta RootShortcutFrom
  lda #$36
  sta RootShortcutTo

__ai_search_validate_0:
  jsr GenerateLegalMoves
  ldx #$00
__ai_search_storm_move_loop_0:
  cpx MoveCount
  bne __ai_search_storm_check_move_0
__ai_search_no_move_0:
  clc
  rts

__ai_search_storm_check_move_0:
  lda MoveListFrom, x
  cmp RootShortcutFrom
  bne __ai_search_storm_next_move_0
  lda MoveListTo, x
  cmp RootShortcutTo
  bne __ai_search_storm_next_move_0
  sta BestMoveTo
  lda RootShortcutFrom
  sta BestMoveFrom
  sec
  rts

__ai_search_storm_next_move_0:
  inx
  jmp __ai_search_storm_move_loop_0

;
; Best move storage (set during search at root level)
;
.segment "BSS"

BestMoveFrom:
  .res 1
BestMoveTo:
  .res 1
RootShortcutFrom:
  .res 1
RootShortcutTo:
  .res 1

; Root-level search telemetry. These are intentionally updated only around
; FindBestMove so normal node search does not pay per-node counter overhead.
SearchCompletedDepth:
  .res 1
SearchRootMoveCount:
  .res 1
SearchUsedBook:
  .res 1
SearchAspirationAttempts:
  .res 1
SearchAspirationRetries:
  .res 1
SearchPVSSearches:
  .res 1
SearchPVSResearches:
  .res 1
SearchNullMoveAttempts:
  .res 1
SearchNullMoveCutoffs:
  .res 1
SearchNullMoveEvalSkips:
  .res 1
SearchHistoryUpdates:
  .res 1
SearchHistoryActive:
  .res 1

.segment "CODE"

;
; Search state variables for Negamax recursion
; These use zero page for speed ($e6-$ef reserved for search)
;
; $e6 = current depth in Negamax call
; $e7 = best score at current depth
; $e8 = move index during iteration
; $e9 = current move from square
; $ea = current move to square
; $eb = current move score (after negate)
; $ec = root depth (to detect when to save best move)
;

;
; Evaluate
; Returns score from perspective of SearchSide
; Positive = good for SearchSide, negative = bad
; Output: A = score (signed 8-bit, clamped below the mate score band)
; Clobbers: Uses EvaluatePosition temps
;
Evaluate:
  jsr EvaluatePosition

; EvalScore is 16-bit, positive = white advantage
; Convert to 8-bit from perspective of SearchSide

; First clamp to 8-bit range
; If high byte is $00, low byte is positive (0-255)
; If high byte is $FF, low byte is negative (-1 to -256 as signed)
; Otherwise overflow - clamp to max/min

  lda EvalScore + 1; High byte
  beq __ai_search_positive_0
  cmp #$FF
  beq __ai_search_negative_0

; Overflow - determine direction and clamp
  bmi __ai_search_clamp_neg_0
  lda #STATIC_EVAL_LIMIT
  jmp __ai_search_apply_side_0
__ai_search_clamp_neg_0:
  lda #<-STATIC_EVAL_LIMIT
  jmp __ai_search_apply_side_0

__ai_search_positive_0:
; High byte is 0, check if low byte fits in signed positive
  lda EvalScore
  cmp #STATIC_EVAL_LIMIT + 1
  bcc __ai_search_apply_side_0; Within static eval range
  lda #STATIC_EVAL_LIMIT
  jmp __ai_search_apply_side_0

__ai_search_negative_0:
; High byte is $FF, low byte is negative
  lda EvalScore
  cmp #<-STATIC_EVAL_LIMIT
  bcs __ai_search_apply_side_0; >= static eval floor (as signed), fits
  lda #<-STATIC_EVAL_LIMIT

__ai_search_apply_side_0:
; Now A has 8-bit score from white's perspective
; If SearchSide is black ($00), negate the score
  ldx SearchSide
  bne __ai_search_done_eval_0; White = $80, non-zero, keep as-is

; Black to move - negate score
  eor #$FF
  clc
  adc #$01

__ai_search_done_eval_0:
  rts

;
; NegateSearchScore
; Two's-complement negation with saturation for $80 (-128), which cannot be
; represented as +128 in an 8-bit signed score. Search windows use $7f as the
; positive bound, so clamp -(-128) to $7f.
; Input/Output: A = signed score
; Clobbers: flags only
;
NegateSearchScore:
  cmp #$80
  bne __ai_search_normal_negate_0
  lda #$7f
  rts
__ai_search_normal_negate_0:
  eor #$ff
  clc
  adc #$01
  rts

;
; TryNullMovePrune
; Fail-high test by letting the side to move pass. This is guarded away from
; root, check, shallow nodes, and sparse material where zugzwang risk is high.
; Input: Current NegamaxState entry has depth/alpha/beta initialized.
; Output: Carry set = prune and A = beta, carry clear = continue full search.
; Clobbers: A, X, Y, $e8, $e9 and recursive search temps.
;
TryNullMovePrune:
  lda SearchDepth
  beq __ai_search_null_skip_0
  cmp #MAX_DEPTH - 1
  bcs __ai_search_null_skip_0

  asl
  asl
  asl
  tax
  lda NegamaxState + 5, x
  cmp #NULL_MOVE_MIN_DEPTH
  bcc __ai_search_null_skip_0

  lda WhitePieceCount
  clc
  adc BlackPieceCount
  cmp #NULL_MOVE_MIN_PIECES
  bcc __ai_search_null_skip_0

  jsr IsCurrentSideInCheck
  bcc __ai_search_null_try_0

__ai_search_null_skip_0:
  clc
  rts

__ai_search_null_try_0:
; Low beta windows are already cheap fail-high candidates. Only pay for the
; static eval gate when beta is positive enough that a weak position matters.
  lda SearchDepth
  asl
  asl
  asl
  tax
  lda NegamaxState + 7, x
  beq __ai_search_null_eval_pass_0
  bmi __ai_search_null_eval_pass_0

  jsr Evaluate
  clc
  adc #NULL_MOVE_EVAL_MARGIN
  bvc __ai_search_null_eval_ready_0
  lda #$7f
__ai_search_null_eval_ready_0:
  sta NullStaticEval

  lda SearchDepth
  asl
  asl
  asl
  tax
  lda NullStaticEval
  sec
  sbc NegamaxState + 7, x
  beq __ai_search_null_eval_pass_0
  bvc __ai_search_null_eval_cmp_no_ov_0
  eor #$80
__ai_search_null_eval_cmp_no_ov_0:
  bpl __ai_search_null_eval_pass_0

  inc SearchNullMoveEvalSkips
  clc
  rts

__ai_search_null_eval_pass_0:
  inc SearchNullMoveAttempts

  ldy SearchDepth
  lda enpassantsq
  sta NullSavedEnPassant, y
  lda NextMoveUsedRecaptureExtension
  sta NullSavedNextMoveExtension, y

  inc SearchDepth

  ldy SearchDepth
  lda #NO_EN_PASSANT
  sta enpassantsq
  sta LastMoveToByDepth, y
  lda #$00
  sta LastMoveWasCaptureByDepth, y
  sta RecaptureExtensionUsedByDepth, y
  sta NextMoveUsedRecaptureExtension

  lda SearchSide
  eor #WHITE_COLOR
  sta SearchSide

; Child null-window search: -Negamax(depth - 1 - R, -beta, -beta + 1).
; Depth-three nodes clamp to quiescence instead of underflowing the byte depth.
  lda SearchDepth
  sec
  sbc #$01
  asl
  asl
  asl
  tax
  lda NegamaxState + 7, x
  jsr NegateSearchScore
  sta $e8
  clc
  adc #$01
  bvc __ai_search_null_beta_ready_0
  lda #$7f
__ai_search_null_beta_ready_0:
  sta $e9

  lda NegamaxState + 5, x
  sec
  sbc #NULL_MOVE_REDUCTION + 1
  bcs __ai_search_null_child_depth_ready_0
  lda #$00
__ai_search_null_child_depth_ready_0:
  jsr Negamax
  jsr NegateSearchScore
  sta NullMoveScore

  lda SearchSide
  eor #WHITE_COLOR
  sta SearchSide
  dec SearchDepth

  ldy SearchDepth
  lda NullSavedEnPassant, y
  sta enpassantsq
  lda NullSavedNextMoveExtension, y
  sta NextMoveUsedRecaptureExtension

  lda SearchDepth
  asl
  asl
  asl
  tax
  lda NullMoveScore
  sec
  sbc NegamaxState + 7, x
  beq __ai_search_null_cutoff_0
  bvc __ai_search_null_cmp_no_ov_0
  eor #$80
__ai_search_null_cmp_no_ov_0:
  bmi __ai_search_null_no_cutoff_0

__ai_search_null_cutoff_0:
  inc SearchNullMoveCutoffs
  lda NegamaxState + 7, x
  sec
  rts

__ai_search_null_no_cutoff_0:
  clc
  rts

;
; Quiescence Search
; Continues searching captures until position is quiet
; Prevents horizon effect (stopping search just before capture)
; Input: $e8 = alpha, $e9 = beta
; Output: A = score (from SearchSide perspective)
; Clobbers: Many registers
;
Quiesce:
; Check quiescence depth limit
  inc QuiesceDepth
  lda QuiesceDepth
  cmp #MAX_QUIESCE_DEPTH
  bcc __ai_search_quiesce_continue_0
; Depth limit reached - just evaluate
  dec QuiesceDepth
  jmp Evaluate

__ai_search_quiesce_continue_0:
; Stand pat: evaluate current position
; If this position is already good enough, we don't need to search captures
  jsr Evaluate
  sta $ea; $ea = stand_pat score

; Beta cutoff: if stand_pat >= beta, return beta
; This means the position is already so good we won't improve
  sec
  sbc $e9; stand_pat - beta
  bvc __ai_search_q_no_ov1_0
  eor #$80; Overflow correction for signed compare
__ai_search_q_no_ov1_0:
  bmi __ai_search_q_no_beta_cut_0
; stand_pat >= beta, return beta
  dec QuiesceDepth
  lda $e9
  rts

__ai_search_q_no_beta_cut_0:
; Update alpha if stand_pat > alpha
  lda $ea; stand_pat
  sec
  sbc $e8; stand_pat - alpha
  beq __ai_search_q_alpha_ok_0; Equal before overflow correction
  bvc __ai_search_q_no_ov2_0
  eor #$80
__ai_search_q_no_ov2_0:
  bmi __ai_search_q_alpha_ok_0
  lda $ea
  sta $e8; alpha = stand_pat

__ai_search_q_alpha_ok_0:
; Save alpha/beta to quiescence state area
  ldx QuiesceDepth
  lda $e8
  sta QAlpha, x
  lda $e9
  sta QBeta, x
  lda #$00
  sta QInCheck, x

; Generate captures only
  ldx SearchSide
  jsr GenerateCaptures

; Filter legal moves
  jsr FilterLegalMoves

; Sort by MVV-LVA for best capture ordering
  jsr OrderMovesMVVLVA

; If no captures, return alpha (position is quiet)
  lda MoveCount
  bne __ai_search_q_have_captures_0

; A quiet leaf still needs a checkmate guard. If the side to move is checked
; and has no captures, search all legal evasions and report mate if none exist.
  jsr IsCurrentSideInCheck
  bcc __ai_search_q_return_quiet_alpha_0

  ldx QuiesceDepth
  lda #$01
  sta QInCheck, x
  jsr GenerateLegalMoves
  lda MoveCount
  bne __ai_search_q_have_captures_0

  dec QuiesceDepth
  lda #<-MATE_SCORE
  rts

__ai_search_q_return_quiet_alpha_0:
  ldx QuiesceDepth
  dec QuiesceDepth
  lda QAlpha, x
  rts

__ai_search_q_have_captures_0:
  ldx QuiesceDepth
  lda #$00
  sta QMoveIdx, x; Move index

__ai_search_q_capture_loop_0:
  ldx QuiesceDepth
  lda QMoveIdx, x
  cmp MoveCount
  bne __ai_search_q_continue_capture_0
  jmp __ai_search_q_return_alpha_0

__ai_search_q_continue_capture_0:
; Quiet quiescence nodes skip captures that lose material by static exchange.
; Checked nodes use the same loop for all evasions, so every evasion searches.
  ldx QuiesceDepth
  lda QInCheck, x
  bne __ai_search_q_search_move_0
  lda QMoveIdx, x
  tax
  jsr CapturePassesSwapOff
  bcs __ai_search_q_search_move_0
  ldx QuiesceDepth
  inc QMoveIdx, x
  jmp __ai_search_q_capture_loop_0

__ai_search_q_search_move_0:
; Get capture move
  ldx QuiesceDepth
  lda QMoveIdx, x
  tax
  lda MoveListFrom, x
  ldy QuiesceDepth
  sta QFrom, y
  lda MoveListTo, x
  sta QTo, y

; Make the move
  ldy QuiesceDepth
  ldx QTo, y
  lda QFrom, y
  jsr MakeMove

; Recurse: -Quiesce(-beta, -alpha)
  ldx QuiesceDepth
  lda QBeta, x
  jsr NegateSearchScore
  sta $e8; child alpha = -beta

  ldx QuiesceDepth
  lda QAlpha, x
  jsr NegateSearchScore
  sta $e9; child beta = -alpha

  jsr Quiesce

; Negate score
  jsr NegateSearchScore
  ldx QuiesceDepth
  sta QScore, x; QScore = -child_score

; Unmake move
  ldy QuiesceDepth
  ldx QTo, y
  lda QFrom, y
  jsr UnmakeMove

; Beta cutoff?
  ldx QuiesceDepth
  lda QScore, x
  sec
  sbc QBeta, x; score - beta
  bvc __ai_search_q_no_ov3_0
  eor #$80
__ai_search_q_no_ov3_0:
  bmi __ai_search_q_no_cut_0
; score >= beta, return beta
  ldx QuiesceDepth
  dec QuiesceDepth
  lda QBeta, x
  rts

__ai_search_q_no_cut_0:
; Update alpha if score > alpha
  ldx QuiesceDepth
  lda QScore, x
  sec
  sbc QAlpha, x; score - alpha
  beq __ai_search_q_next_cap_0; Equal before overflow correction
  bvc __ai_search_q_no_ov4_0
  eor #$80
__ai_search_q_no_ov4_0:
  bmi __ai_search_q_next_cap_0
  ldx QuiesceDepth
  lda QScore, x
  sta QAlpha, x; alpha = score

__ai_search_q_next_cap_0:
; Child quiescence clobbered the shared move list. Rebuild this node's
; move list before advancing to the next parent move. Checked nodes must
; search all legal evasions; quiet nodes search captures only.
  ldx QuiesceDepth
  lda QInCheck, x
  beq __ai_search_q_regen_captures_0

  jsr GenerateLegalMoves
  jmp __ai_search_q_regen_done_0

__ai_search_q_regen_captures_0:
  ldx SearchSide
  jsr GenerateCaptures
  jsr FilterLegalMoves
  jsr OrderMovesMVVLVA

__ai_search_q_regen_done_0:
  ldx QuiesceDepth
  inc QMoveIdx, x
  jmp __ai_search_q_capture_loop_0

__ai_search_q_return_alpha_0:
  ldx QuiesceDepth
  dec QuiesceDepth
  lda QAlpha, x
  rts

; Quiescence state storage. Index 0 is unused by the current depth counter,
; which enters active nodes at depth 1 and evaluates immediately at depth 6.
.segment "BSS"

QAlpha:   .res MAX_QUIESCE_DEPTH
QBeta:    .res MAX_QUIESCE_DEPTH
QFrom:    .res MAX_QUIESCE_DEPTH
QTo:      .res MAX_QUIESCE_DEPTH
QScore:   .res MAX_QUIESCE_DEPTH
QMoveIdx: .res MAX_QUIESCE_DEPTH
QInCheck: .res MAX_QUIESCE_DEPTH

.segment "CODE"

;
; PromoteTTMove
; If the current position matched a TT entry, move its stored best move to the
; front of the ordered move list. The move may come from a shallower entry.
; Clobbers: A, X, Y, $e0-$e2
;
PromoteTTMove:
  lda TTMoveAvailable
  beq __ai_search_done_0
  lda TTBestFrom
  cmp #$ff
  beq __ai_search_done_0

  ldx #$00

__ai_search_find_loop_0:
  cpx MoveCount
  bcs __ai_search_done_0
  lda MoveListFrom, x
  cmp TTBestFrom
  bne __ai_search_next_0
  lda MoveListTo, x
  cmp TTBestTo
  beq __ai_search_found_0

__ai_search_next_0:
  inx
  jmp __ai_search_find_loop_0

__ai_search_found_0:
  cpx #$00
  beq __ai_search_done_0

; Swap found move with move 0.
  lda MoveListFrom
  sta $e0
  lda MoveListFrom, x
  sta MoveListFrom
  lda $e0
  sta MoveListFrom, x

  lda MoveListTo
  sta $e1
  lda MoveListTo, x
  sta MoveListTo
  lda $e1
  sta MoveListTo, x

  lda MoveScores
  sta $e2
  lda MoveScores, x
  sta MoveScores
  lda $e2
  sta MoveScores, x

__ai_search_done_0:
  rts

;
; StoreTTCurrentNode
; Input: A = TT flag to store for the current Negamax node.
; Stores score and the local best move for SearchDepth.
; Clobbers: A, X, Y, TTFlag, TTScoreLo/Hi, TTStoreFrom/To
;
StoreTTCurrentNode:
  sta TTFlag

  lda SearchDepth
  asl
  asl
  asl
  tax

  lda NegamaxState + 1, x
  sta TTScoreLo
  lda #$00
  sta TTScoreHi
  lda NegamaxState + 1, x
  bpl __ai_search_score_done_0
  lda #$ff
  sta TTScoreHi

__ai_search_score_done_0:
  ldy SearchDepth
  lda NegamaxBestFrom, y
  sta TTStoreFrom
  lda NegamaxBestTo, y
  sta TTStoreTo
  lda #$01
  sta TTStoreUseMove

  jsr ComputeZobristHash

  lda SearchDepth
  asl
  asl
  asl
  tax
  lda NegamaxState + 5, x
  ldx TTFlag
  jmp TTStore

;
; ApplyRootPawnSafetyPenalty
; Penalize root candidate moves that leave a valuable piece on an enemy pawn
; attack. This keeps shallow search from preferring flashy checks that simply
; hang a minor to an a/h/c/f pawn.
; Input/Output: $eb = root move score from the mover's perspective.
; Clobbers: A, X, Y, $f0-$f5
;
ApplyRootPawnSafetyPenalty:
  ldx NegamaxState + 3; Root move from square
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_search_done_1
  sta $f3
  and #$07
  sta $f2
  cmp #KNIGHT_TYPE
  bcc __ai_search_done_1
  cmp #KING_TYPE
  bcs __ai_search_done_1

  lda $f3
  and #WHITE_COLOR
  sta $f1
  lda NegamaxState + 4; Root move to square
  and #$7f
  sta $f0
  jsr IsPiecePawnAttacked
  bcc __ai_search_done_1

  ldy $f2
  lda $eb
  sec
  sbc PawnAttackPenalty, y
  bvc __ai_search_store_score_0
  lda #NEG_INFINITY
__ai_search_store_score_0:
  sta $eb

__ai_search_done_1:
  rts

;
; ApplyRootQueenSafetyPenalty
; Penalize root queen moves that land on enemy attacks while grabbing less
; than a queen. This catches shallow queen raids that win a pawn but leave the
; queen en prise.
; Input/Output: $eb = root move score from the mover's perspective.
; Clobbers: A, X, Y, attack_sq, attack_color, $f0-$f5
;
ApplyRootQueenSafetyPenalty:
  ldx NegamaxState + 3; Root move from square
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_search_done_2
  sta $f3
  and #$07
  cmp #QUEEN_TYPE
  bne __ai_search_done_2

  lda $f3
  and #WHITE_COLOR
  sta $f1
  lda NegamaxState + 4; Root move to square
  and #$7f
  sta $f0

  ldx $f0
  lda Board88, x
  and #$07
  cmp #QUEEN_TYPE
  beq __ai_search_done_2

  lda $f0
  sta attack_sq
  lda $f1
  beq __ai_search_black_queen_0
  lda #BLACKS_TURN
  jmp __ai_search_attack_color_set_0
__ai_search_black_queen_0:
  lda #WHITES_TURN
__ai_search_attack_color_set_0:
  sta attack_color
  jsr IsSquareAttacked
  bcc __ai_search_done_2

  lda $eb
  sec
  sbc #ROOT_ATTACKED_QUEEN_DEST_PENALTY
  bvc __ai_search_store_score_1
  lda #NEG_INFINITY
__ai_search_store_score_1:
  sta $eb

__ai_search_done_2:
  rts

;
; ApplyRootMinorSafetyPenalty
; Penalize root minor-piece moves that land on cheap tactical attacks. This is
; deliberately narrow: quiet moves and pawn grabs by knights/bishops should
; not walk onto a home-queen ray or enemy knight attack unless search has a
; very clear reason.
; Input/Output: $eb = root move score from the mover's perspective.
; Clobbers: A, X, Y, attack_sq, attack_color, $f0-$f6
;
ApplyRootMinorSafetyPenalty:
  ldx NegamaxState + 3; Root move from square
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_search_done_3
  sta $f3
  and #$07
  sta $f2
  cmp #KNIGHT_TYPE
  beq __ai_search_minor_piece_0
  cmp #BISHOP_TYPE
  bne __ai_search_done_3

__ai_search_minor_piece_0:
  lda $f3
  and #WHITE_COLOR
  sta $f1

  lda NegamaxState + 4; Root move to square
  and #$7f
  sta $f0

; Capturing an equal or stronger piece is usually tactically acceptable.
  ldx $f0
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_search_check_attacks_0
  and #$07
  cmp #KNIGHT_TYPE
  bcs __ai_search_done_3

__ai_search_check_attacks_0:
  jsr IsPieceQueenAttacked
  bcc __ai_search_check_knight_attack_0

  lda $eb
  sec
  sbc #ROOT_MINOR_QUEEN_RAY_PENALTY
  bvc __ai_search_store_queen_score_0
  lda #NEG_INFINITY
__ai_search_store_queen_score_0:
  sta $eb
  rts

__ai_search_check_knight_attack_0:
  jsr IsPieceKnightAttacked
  bcc __ai_search_check_attacked_dest_0

  lda $eb
  sec
  sbc #ROOT_MINOR_KNIGHT_DEST_PENALTY
  bvc __ai_search_store_knight_score_0
  lda #NEG_INFINITY
__ai_search_store_knight_score_0:
  sta $eb
  rts

__ai_search_check_attacked_dest_0:
  lda $f0
  sta attack_sq
  lda $f1
  beq __ai_search_black_piece_0
  lda #BLACKS_TURN
  jmp __ai_search_attack_color_set_1
__ai_search_black_piece_0:
  lda #WHITES_TURN
__ai_search_attack_color_set_1:
  sta attack_color
  jsr IsSquareAttacked
  bcc __ai_search_done_3

  lda $eb
  sec
  sbc #ROOT_MINOR_ATTACKED_DEST_PENALTY
  bvc __ai_search_store_attacked_dest_score_0
  lda #NEG_INFINITY
__ai_search_store_attacked_dest_score_0:
  sta $eb

__ai_search_done_3:
  rts

;
; RootMoveResolvesQueenAttack
; Input: $f0 = queen square, $f1 = queen color/SearchSide.
; Output: Carry set if the root candidate leaves the queen unattacked.
; Clobbers: A, X, Y, attack_sq, attack_color, $f2-$f5
;
RootMoveResolvesQueenAttack:
  lda NegamaxState + 3; Moving the queen addresses the threat.
  cmp $f0
  beq __ai_search_resolves_queen_attack_0
  sta $f2

  lda NegamaxState + 4; Root move to square
  and #$7f
  sta $f3

  ldx $f2
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_search_not_resolved_0
  sta $f4

  ldx $f3
  lda Board88, x
  sta $f5

  ldx $f2
  lda #EMPTY_PIECE
  sta Board88, x
  ldx $f3
  lda $f4
  sta Board88, x

  lda $f0
  sta attack_sq
  lda #BLACKS_TURN
  ldx $f1
  bne __ai_search_resolve_attack_color_set_0
  lda #WHITES_TURN
__ai_search_resolve_attack_color_set_0:
  sta attack_color
  jsr IsSquareAttacked
  php

  ldx $f2
  lda $f4
  sta Board88, x
  ldx $f3
  lda $f5
  sta Board88, x

  plp
  bcc __ai_search_resolves_queen_attack_0

__ai_search_not_resolved_0:
  clc
  rts

__ai_search_resolves_queen_attack_0:
  sec
  rts

;
; RootMoveCapturesPawnAttacker
; Input: $f0 = attacked piece square, $f1 = attacked piece color/SearchSide.
; Output: Carry set if the root move captures one of the pawns attacking $f0.
; Clobbers: A, X, Y, $f3-$f5
;
RootMoveCapturesPawnAttacker:
  lda NegamaxState + 4; Root move to square
  and #$7f
  sta $f5

  lda $f1
  beq __ai_search_black_piece_1

; White piece: black pawns attack from square -15 and square -17.
  lda $f0
  sec
  sbc #$0f
  cmp $f5
  bne __ai_search_check_white_second_0
  jsr CheckBlackPawnAt
  bcs __ai_search_captures_attacker_1
__ai_search_check_white_second_0:
  lda $f0
  sec
  sbc #$11
  cmp $f5
  bne __ai_search_not_attacker_1
  jsr CheckBlackPawnAt
  bcs __ai_search_captures_attacker_1
  clc
  rts

__ai_search_black_piece_1:
; Black piece: white pawns attack from square +15 and square +17.
  lda $f0
  clc
  adc #$0f
  cmp $f5
  bne __ai_search_check_black_second_0
  jsr CheckWhitePawnAt
  bcs __ai_search_captures_attacker_1
__ai_search_check_black_second_0:
  lda $f0
  clc
  adc #$11
  cmp $f5
  bne __ai_search_not_attacker_1
  jsr CheckWhitePawnAt
  bcs __ai_search_captures_attacker_1

__ai_search_not_attacker_1:
  clc
  rts

__ai_search_captures_attacker_1:
  sec
  rts

;
; ApplyRootHangingQueenPenalty
; Penalize root moves that ignore a queen currently attacked by an enemy
; piece. Moving the queen, blocking the attack, or capturing the attacker
; resolves it.
; Input/Output: $eb = root move score from the mover's perspective.
; Clobbers: A, X, Y, attack_sq, attack_color, $f0-$f7
;
ApplyRootHangingQueenPenalty:
  lda SearchSide
  sta $f1
  beq __ai_search_black_side_1
  lda #WHITE_QUEEN
  jmp __ai_search_queen_set_0
__ai_search_black_side_1:
  lda #BLACK_QUEEN

__ai_search_queen_set_0:
  sta $f6
  lda #$00
  sta $f7

__ai_search_scan_loop_0:
  ldx $f7
  lda Board88, x
  cmp $f6
  bne __ai_search_next_square_0

  stx $f0
  stx attack_sq
  lda #BLACKS_TURN
  ldx $f1
  bne __ai_search_queen_attack_color_set_0
  lda #WHITES_TURN
__ai_search_queen_attack_color_set_0:
  sta attack_color
  jsr IsSquareAttacked
  bcc __ai_search_next_square_0

  jsr RootMoveResolvesQueenAttack
  bcs __ai_search_done_4

  lda $eb
  sec
  sbc #ROOT_HANGING_QUEEN_PENALTY
  bvc __ai_search_store_score_2
  lda #NEG_INFINITY
__ai_search_store_score_2:
  sta $eb
  rts

__ai_search_next_square_0:
  inc $f7
  lda $f7
  and #$08
  beq __ai_search_check_done_0
  lda $f7
  clc
  adc #$08
  sta $f7
__ai_search_check_done_0:
  lda $f7
  cmp #BOARD_SIZE
  beq __ai_search_done_4
  jmp __ai_search_scan_loop_0

__ai_search_done_4:
  rts

;
; ApplyRootLoopPenalty
; Penalize root candidates that keep the engine in a reversible loop. This has
; two layers: direct quiet reversal of the engine's previous move, and a
; stronger penalty when the resulting position already exists in recorded
; history. Captures, pawn moves, and promotions are irreversible enough that we
; leave them alone.
; Input/Output: $eb = root move score from the mover's perspective.
; Clobbers: A, X, Y, $f0-$fb, RepeatCount, ZobristHash
;
ApplyRootLoopPenalty:
  lda SearchDepth
  bne __ai_search_loop_done_0

  lda NegamaxState + 4
  bmi __ai_search_loop_done_0
  and #$7f
  tax
  lda Board88, x
  cmp #EMPTY_PIECE
  bne __ai_search_loop_done_0

  ldx NegamaxState + 3
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_search_loop_done_0
  and #$07
  cmp #PAWN_TYPE
  beq __ai_search_loop_done_0

  jsr ApplyRootReverseMovePenalty
  jsr ApplyRootHistoryPenalty

__ai_search_loop_done_0:
  rts

;
; ApplyRootReverseMovePenalty
; Penalize moving the same piece back to the square it just left.
; Input/Output: $eb = root move score.
; Clobbers: A
;
ApplyRootReverseMovePenalty:
  lda LastEngineMoveFrom
  cmp #$ff
  beq __ai_search_reverse_done_0

  lda NegamaxState + 3
  cmp LastEngineMoveTo
  bne __ai_search_reverse_done_0
  lda NegamaxState + 4
  and #$7f
  cmp LastEngineMoveFrom
  bne __ai_search_reverse_done_0

  lda #ROOT_REVERSE_MOVE_PENALTY
  jmp ApplyRootPenaltyAmount

__ai_search_reverse_done_0:
  rts

;
; ApplyRootHistoryPenalty
; Penalize candidate moves whose resulting position has already appeared in the
; host-maintained position history. One previous occurrence gets a mild penalty;
; two or more means the move is walking straight into repetition territory.
; Input/Output: $eb = root move score.
; Clobbers: A, X, Y, $f0-$fb, RepeatCount, ZobristHash
;
ApplyRootHistoryPenalty:
  lda HistoryCount
  beq __ai_search_history_done_0

  jsr CountRootCandidateHistory
  lda RepeatCount
  beq __ai_search_history_done_0
  cmp #$02
  bcc __ai_search_history_seen_once_0

  lda #ROOT_REPETITION_PENALTY
  jmp ApplyRootPenaltyAmount

__ai_search_history_seen_once_0:
  lda #ROOT_HISTORY_SEEN_PENALTY
  jmp ApplyRootPenaltyAmount

__ai_search_history_done_0:
  rts

;
; CountRootCandidateHistory
; Temporarily makes the root candidate, hashes the resulting side-to-move
; position, and leaves RepeatCount holding the number of matching history
; entries. The real board, currentplayer, SearchDepth, and SearchSide are
; restored before return.
; Clobbers: A, X, Y, $f0-$fb, RepeatCount, ZobristHash
;
CountRootCandidateHistory:
  lda currentplayer
  sta RootRepeatSavedCurrentPlayer

  lda NegamaxState + 3
  ldx NegamaxState + 4
  jsr MakeMove

  lda SearchSide
  beq __ai_search_repeat_black_to_move_0
  lda #WHITES_TURN
  jmp __ai_search_repeat_side_ready_0
__ai_search_repeat_black_to_move_0:
  lda #BLACKS_TURN
__ai_search_repeat_side_ready_0:
  sta currentplayer

  jsr ComputeZobristHash
  jsr CheckRepetition

  lda NegamaxState + 3
  ldx NegamaxState + 4
  jsr UnmakeMove

  lda RootRepeatSavedCurrentPlayer
  sta currentplayer
  lda RepeatCount
  rts

;
; ApplyRootPenaltyAmount
; Subtract A from $eb and clamp underflow to NEG_INFINITY.
; Input: A = unsigned penalty amount
; Input/Output: $eb = signed root score
; Clobbers: A, $f0
;
ApplyRootPenaltyAmount:
  sta $f0
  lda $eb
  sec
  sbc $f0
  bvc __ai_search_penalty_store_0
  lda #NEG_INFINITY
__ai_search_penalty_store_0:
  sta $eb
  rts

;
; ApplyRootHangingMinorPenalty
; Penalize root moves that ignore a minor/rook/queen currently attacked by an
; enemy pawn. Moving the piece or capturing the attacking pawn resolves it.
; Input/Output: $eb = root move score from the mover's perspective.
; Clobbers: A, X, Y, $f0-$f7
;
ApplyRootHangingMinorPenalty:
  lda SearchSide
  sta $f6
  lda #$00
  sta $f7

__ai_search_scan_loop_1:
  ldx $f7
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_search_next_square_1
  sta $f3
  and #WHITE_COLOR
  cmp $f6
  bne __ai_search_next_square_1
  sta $f1
  lda $f3
  and #$07
  sta $f2
  cmp #KNIGHT_TYPE
  bcc __ai_search_next_square_1
  cmp #KING_TYPE
  bcs __ai_search_next_square_1

  stx $f0
  jsr IsPiecePawnAttacked
  bcc __ai_search_next_square_1

  lda NegamaxState + 3; Moving the attacked piece addresses it.
  cmp $f0
  beq __ai_search_done_5

  jsr RootMoveCapturesPawnAttacker
  bcs __ai_search_done_5

  lda $eb
  sec
  sbc #ROOT_HANGING_MINOR_PENALTY
  bvc __ai_search_store_score_3
  lda #NEG_INFINITY
__ai_search_store_score_3:
  sta $eb
  rts

__ai_search_next_square_1:
  inc $f7
  lda $f7
  and #$08
  beq __ai_search_check_done_1
  lda $f7
  clc
  adc #$08
  sta $f7
__ai_search_check_done_1:
  lda $f7
  cmp #BOARD_SIZE
  bne __ai_search_scan_loop_1

__ai_search_done_5:
  rts

;
; CheckRootPawnWinTarget
; Input: A = candidate target square, $f6 = moving side color.
; Output: Carry set if target is an enemy non-pawn piece, $f5 = target.
; Clobbers: A, X, $f3-$f5
;
CheckRootPawnWinTarget:
  sta $f5
  and #OFFBOARD_MASK
  bne __ai_search_not_target_0
  ldx $f5
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_search_not_target_0
  sta $f3
  and #WHITE_COLOR
  cmp $f6
  beq __ai_search_not_target_0
  lda $f3
  and #$07
  cmp #KNIGHT_TYPE
  bcc __ai_search_not_target_0
  cmp #KING_TYPE
  bcs __ai_search_not_target_0
  sec
  rts
__ai_search_not_target_0:
  clc
  rts

;
; ApplyRootMissedPawnWinPenalty
; If a pawn can win an enemy piece immediately, discourage unrelated root
; moves. This catches repeated opening misses like ignoring dxc6 when a bishop
; sits on c6.
; Input/Output: $eb = root move score from the mover's perspective.
; Clobbers: A, X, Y, $f0-$f7
;
ApplyRootMissedPawnWinPenalty:
  lda SearchSide
  sta $f6
  lda #$00
  sta $f7

__ai_search_scan_loop_2:
  ldx $f7
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_search_next_square_2
  sta $f3
  and #WHITE_COLOR
  cmp $f6
  bne __ai_search_next_square_2
  lda $f3
  and #$07
  cmp #PAWN_TYPE
  bne __ai_search_next_square_2

  stx $f0
  lda $f6
  beq __ai_search_black_pawn_0

  lda $f0
  sec
  sbc #$11
  jsr CheckRootPawnWinTarget
  bcs __ai_search_found_pawn_win_0
  lda $f0
  sec
  sbc #$0f
  jsr CheckRootPawnWinTarget
  bcs __ai_search_found_pawn_win_0
  jmp __ai_search_next_square_2

__ai_search_black_pawn_0:
  lda $f0
  clc
  adc #$0f
  jsr CheckRootPawnWinTarget
  bcs __ai_search_found_pawn_win_0
  lda $f0
  clc
  adc #$11
  jsr CheckRootPawnWinTarget
  bcs __ai_search_found_pawn_win_0
  jmp __ai_search_next_square_2

__ai_search_found_pawn_win_0:
  lda NegamaxState + 3
  cmp $f0
  bne __ai_search_penalize_0
  lda NegamaxState + 4
  and #$7f
  cmp $f5
  beq __ai_search_done_6

__ai_search_penalize_0:
; Do not penalize a different move that also captures a real piece.
  lda NegamaxState + 4
  and #$7f
  tax
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_search_apply_penalty_0
  and #$07
  cmp #KNIGHT_TYPE
  bcs __ai_search_done_6

__ai_search_apply_penalty_0:
  lda $eb
  sec
  sbc #ROOT_MISSED_PAWN_WIN_PENALTY
  bvc __ai_search_store_score_4
  lda #NEG_INFINITY
__ai_search_store_score_4:
  sta $eb
  rts

__ai_search_next_square_2:
  inc $f7
  lda $f7
  and #$08
  beq __ai_search_check_done_2
  lda $f7
  clc
  adc #$08
  sta $f7
__ai_search_check_done_2:
  lda $f7
  cmp #BOARD_SIZE
  beq __ai_search_done_6
  jmp __ai_search_scan_loop_2

__ai_search_done_6:
  rts

;
; ApplyRootEarlyQueenPenalty
; Penalize quiet queen moves when the queen is not currently attacked. Captures
; and queen escapes are exempt.
; Input/Output: $eb = root move score from the mover's perspective.
; Clobbers: A, X, Y, attack_sq, attack_color, $f0-$f3
;
ApplyRootEarlyQueenPenalty:
  ldx NegamaxState + 3
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_search_done_7
  sta $f3
  and #$07
  cmp #QUEEN_TYPE
  bne __ai_search_done_7

  lda NegamaxState + 4
  and #$7f
  tax
  lda Board88, x
  cmp #EMPTY_PIECE
  bne __ai_search_done_7

  lda NegamaxState + 3
  sta attack_sq
  lda $f3
  and #WHITE_COLOR
  beq __ai_search_black_queen_1
  lda #BLACKS_TURN
  jmp __ai_search_attack_color_set_2
__ai_search_black_queen_1:
  lda #WHITES_TURN
__ai_search_attack_color_set_2:
  sta attack_color
  jsr IsSquareAttacked
  bcs __ai_search_done_7

  lda $eb
  sec
  sbc #ROOT_EARLY_QUEEN_MOVE_PENALTY
  bvc __ai_search_store_score_5
  lda #NEG_INFINITY
__ai_search_store_score_5:
  sta $eb

__ai_search_done_7:
  rts

;
; ApplyRootEarlyKingPenalty
; Penalize non-castling king moves when the side to move is not in check.
; Opening king walks like Kd2 are usually catastrophic; evasions and castling
; are exempt.
; Input/Output: $eb = root move score from the mover's perspective.
; Clobbers: A, X, Y, attack_sq, attack_color, $f0-$f3
;
ApplyRootEarlyKingPenalty:
  ldx NegamaxState + 3
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_search_done_8
  and #$07
  cmp #KING_TYPE
  bne __ai_search_done_8

  lda NegamaxState + 4
  and #$7f
  sta $f0
  sec
  sbc NegamaxState + 3
  cmp #$02
  beq __ai_search_done_8
  cmp #$fe
  beq __ai_search_done_8

  jsr IsCurrentSideInCheck
  bcs __ai_search_done_8

  lda $eb
  sec
  sbc #ROOT_EARLY_KING_MOVE_PENALTY
  bvc __ai_search_store_score_6
  lda #NEG_INFINITY
__ai_search_store_score_6:
  sta $eb

__ai_search_done_8:
  rts

;
; ApplyRootEarlyRookPenalty
; Penalize quiet rook moves while home-rank minor pieces are still undeveloped.
; Rook lifts are usually wasted tempi in the opening, but captures and rook
; endings are left alone.
; Input/Output: $eb = root move score from the mover's perspective.
; Clobbers: A, X
;
ApplyRootEarlyRookPenalty:
  ldx NegamaxState + 3
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_search_done_9
  sta $f3
  and #$07
  cmp #ROOK_TYPE
  bne __ai_search_done_9

  lda NegamaxState + 4
  and #$7f
  tax
  lda Board88, x
  cmp #EMPTY_PIECE
  bne __ai_search_done_9

  jsr IsCurrentSideInCheck
  bcs __ai_search_done_9

  lda SearchSide
  beq __ai_search_black_side_2

  lda Board88 + $71
  cmp #WHITE_KNIGHT
  beq __ai_search_penalize_1
  lda Board88 + $72
  cmp #WHITE_BISHOP
  beq __ai_search_penalize_1
  lda Board88 + $75
  cmp #WHITE_BISHOP
  beq __ai_search_penalize_1
  lda Board88 + $76
  cmp #WHITE_KNIGHT
  beq __ai_search_penalize_1
  rts

__ai_search_black_side_2:
  lda Board88 + $01
  cmp #BLACK_KNIGHT
  beq __ai_search_penalize_1
  lda Board88 + $02
  cmp #BLACK_BISHOP
  beq __ai_search_penalize_1
  lda Board88 + $05
  cmp #BLACK_BISHOP
  beq __ai_search_penalize_1
  lda Board88 + $06
  cmp #BLACK_KNIGHT
  bne __ai_search_done_9

__ai_search_penalize_1:
  lda $eb
  sec
  sbc #ROOT_EARLY_ROOK_MOVE_PENALTY
  bvc __ai_search_store_score_7
  lda #NEG_INFINITY
__ai_search_store_score_7:
  sta $eb

__ai_search_done_9:
  rts

;
; IsAdvancedEnemyPawn
; Input: X = square, $f6 = SearchSide.
; Output: Carry set if Board88[X] is an enemy pawn deep in our territory.
; Clobbers: A, $f3
;
IsAdvancedEnemyPawn:
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_search_not_advanced_0
  sta $f3
  and #$07
  cmp #PAWN_TYPE
  bne __ai_search_not_advanced_0
  lda $f3
  and #WHITE_COLOR
  cmp $f6
  beq __ai_search_not_advanced_0

  lda $f6
  beq __ai_search_black_to_move_1

; White to move: black pawns on ranks 1-3 (rows 5-7) are urgent.
  txa
  and #$70
  cmp #$50
  bcc __ai_search_not_advanced_0
  sec
  rts

__ai_search_black_to_move_1:
; Black to move: white pawns on ranks 6-8 (rows 0-2) are urgent.
  txa
  and #$70
  cmp #$30
  bcs __ai_search_not_advanced_0
  sec
  rts

__ai_search_not_advanced_0:
  clc
  rts

;
; ApplyRootMissedAdvancedPawnPenalty
; If an advanced enemy pawn is capturable now, discourage unrelated root moves.
; Input/Output: $eb = root move score from the mover's perspective.
; Clobbers: A, X, Y, attack_sq, attack_color, $f0-$f7
;
ApplyRootMissedAdvancedPawnPenalty:
  lda SearchSide
  sta $f6
  lda #$00
  sta $f7

__ai_search_scan_loop_3:
  ldx $f7
  jsr IsAdvancedEnemyPawn
  bcc __ai_search_next_square_3

  stx $f0
  stx attack_sq
  lda $f6
  beq __ai_search_black_attacks_1
  lda #WHITES_TURN
  jmp __ai_search_attack_color_set_3
__ai_search_black_attacks_1:
  lda #BLACKS_TURN
__ai_search_attack_color_set_3:
  sta attack_color
  jsr IsSquareAttacked
  bcc __ai_search_next_square_3

  lda NegamaxState + 4
  and #$7f
  cmp $f0
  beq __ai_search_done_10

; Do not penalize a different move that also captures a real piece.
  lda NegamaxState + 4
  and #$7f
  tax
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_search_apply_penalty_1
  and #$07
  cmp #KNIGHT_TYPE
  bcs __ai_search_done_10

__ai_search_apply_penalty_1:
  lda $eb
  sec
  sbc #ROOT_MISSED_ADVANCED_PAWN_PENALTY
  bvc __ai_search_store_score_8
  lda #NEG_INFINITY
__ai_search_store_score_8:
  sta $eb
  rts

__ai_search_next_square_3:
  inc $f7
  lda $f7
  and #$08
  beq __ai_search_check_done_3
  lda $f7
  clc
  adc #$08
  sta $f7
__ai_search_check_done_3:
  lda $f7
  cmp #BOARD_SIZE
  beq __ai_search_done_10
  jmp __ai_search_scan_loop_3

__ai_search_done_10:
  rts

;
; Negamax with Alpha-Beta Pruning
; Recursive search from current position
; Input: A = depth remaining
;        $e8 = alpha (lower bound, initially -128)
;        $e9 = beta (upper bound, initially +127)
; Output: A = best score (signed 8-bit)
;         If at root (SearchDepth == 0), sets BestMoveFrom/BestMoveTo
; Clobbers: Many registers and temps
;
; IMPORTANT: This function saves/restores state for recursion using
; the NegamaxState array indexed by depth, since the 6502 stack is limited.
;
Negamax:
; Base case: depth == 0 -> quiescence search
  cmp #$00
  bne __ai_search_search_0
  lda #$00
  sta QuiesceDepth; Reset quiescence depth
  jmp Quiesce; Tail call to quiescence

__ai_search_search_0:
; Calculate state array offset = (SearchDepth) * 8
; We'll store: move_count, best_score, move_index, from, to, depth, alpha, beta
  pha; Save depth on stack temporarily
  lda SearchDepth
  asl; *2
  asl; *4
  asl; *8
  tax; X = offset into NegamaxState
  pla; Get depth back
  sta NegamaxState + 5, x; [offset+5] = depth remaining (survives recursion)

; Store alpha/beta for this depth (read from entry parameters at $e8/$e9)
  lda $e8
  sta NegamaxState + 6, x; [offset+6] = alpha
  lda $e9
  sta NegamaxState + 7, x; [offset+7] = beta
  ldy SearchDepth
  lda $e8
  sta NegamaxOrigAlpha, y

; Probe transposition table
  jsr ComputeZobristHash

; Recalculate state offset (ComputeZobristHash clobbers X)
  lda SearchDepth
  asl
  asl
  asl
  tax

; Probe TT with current depth requirement
  lda NegamaxState + 5, x; depth remaining
  jsr TTProbe

  lda TTHit
  beq __ai_search_tt_miss_0

; TT hit - exact entries can return immediately. Bound entries return only
; when they prove this node cannot affect the current alpha/beta window.
  lda SearchDepth
  asl
  asl
  asl
  tax

  lda TTFlag
  cmp #TT_FLAG_EXACT
  bne __ai_search_tt_check_alpha_0

  lda TTScoreLo; Return 8-bit score
  rts

__ai_search_tt_check_alpha_0:
  cmp #TT_FLAG_ALPHA
  bne __ai_search_tt_check_beta_0

; ALPHA upper-bound hit: usable when stored score <= current alpha.
  lda NegamaxState + 6, x; alpha
  sec
  sbc TTScoreLo; alpha - score
  beq __ai_search_tt_return_score_0
  bvc __ai_search_tt_alpha_no_ov_0
  eor #$80
__ai_search_tt_alpha_no_ov_0:
  bmi __ai_search_tt_miss_0; alpha < score, cannot use bound
  jmp __ai_search_tt_return_score_0

__ai_search_tt_check_beta_0:
  cmp #TT_FLAG_BETA
  bne __ai_search_tt_miss_0

; BETA lower-bound hit: usable when stored score >= current beta.
  lda TTScoreLo
  sec
  sbc NegamaxState + 7, x; score - beta
  beq __ai_search_tt_return_score_0
  bvc __ai_search_tt_beta_no_ov_0
  eor #$80
__ai_search_tt_beta_no_ov_0:
  bmi __ai_search_tt_miss_0; score < beta, cannot use bound

__ai_search_tt_return_score_0:
  lda TTScoreLo
  rts

__ai_search_tt_miss_0:
  jsr TryNullMovePrune
  bcc __ai_search_generate_moves_0
  rts

__ai_search_generate_moves_0:
; Generate legal moves for current side
  jsr GenerateLegalMoves
  jsr PromoteTTMove

; Recalculate state offset (GenerateLegalMoves clobbered X)
  lda SearchDepth
  asl
  asl
  asl
  tax

; Child searches share the global move list, so keep this node's ordered
; list in depth-local storage and restore it after each child returns.
  jsr SaveMoveListForDepth

; Save move count at this depth
  lda MoveCount
  sta NegamaxState, x; [offset+0] = move count

; Check for no legal moves
  cmp #$00
  bne __ai_search_have_moves_0

; No moves - checkmate or stalemate?
  lda SearchSide
  bne __ai_search_check_white_king_mate_0
  lda blackkingsq
  jmp __ai_search_check_if_in_check_0
__ai_search_check_white_king_mate_0:
  lda whitekingsq

__ai_search_check_if_in_check_0:
  sta attack_sq

  lda SearchSide
  beq __ai_search_white_attacks_mate_0
  lda #BLACKS_TURN
  jmp __ai_search_do_check_mate_0
__ai_search_white_attacks_mate_0:
  lda #WHITES_TURN
__ai_search_do_check_mate_0:
  sta attack_color
  jsr IsSquareAttacked

  bcc __ai_search_stalemate_0
  lda #<-MATE_SCORE
  rts

__ai_search_stalemate_0:
  lda #DRAW_SCORE
  rts

__ai_search_have_moves_0:
; Recalculate state offset (clobbered by IsSquareAttacked path)
  lda SearchDepth
  asl
  asl
  asl
  tax

; Initialize best score to -infinity
  lda #NEG_INFINITY
  sta NegamaxState + 1, x; [offset+1] = best score

; Clear local best move for this node.
  ldy SearchDepth
  lda #$ff
  sta NegamaxBestFrom, y
  sta NegamaxBestTo, y

; Initialize move index to 0
  lda #$00
  sta NegamaxState + 2, x; [offset+2] = move index
  ldy SearchDepth
  sta NegamaxFutility, y

; Conservative frontier futility pruning. At non-root depth-1 nodes that are
; not in check, skip quiet non-promotions when static eval + margin cannot
; beat alpha. Captures and promotions still search normally.
  lda SearchDepth
  beq __ai_search_futility_done_0
  lda NegamaxState + 5, x
  cmp #$01
  bne __ai_search_futility_done_0
  jsr IsCurrentSideInCheck
  bcs __ai_search_futility_done_0
  jsr Evaluate
  clc
  adc #FUTILITY_MARGIN
  bvc __ai_search_futility_eval_ready_0
  lda #$7f
__ai_search_futility_eval_ready_0:
  sta $f0

  lda SearchDepth
  asl
  asl
  asl
  tax
  lda $f0
  sec
  sbc NegamaxState + 6, x; static+margin - alpha
  beq __ai_search_enable_futility_0
  bvc __ai_search_futility_no_ov_0
  eor #$80
__ai_search_futility_no_ov_0:
  bpl __ai_search_futility_done_0

__ai_search_enable_futility_0:
  ldy SearchDepth
  lda #$01
  sta NegamaxFutility, y
  lda NegamaxState + 6, x; Return alpha if every move is futile.
  sta NegamaxState + 1, x

__ai_search_futility_done_0:

__ai_search_move_loop_0:
; Recalculate state offset
  lda SearchDepth
  asl
  asl
  asl
  tax

; Check if done with all moves
  lda NegamaxState + 2, x; move index
  cmp NegamaxState, x; move count
  bne __ai_search_continue_loop_0
  jmp __ai_search_search_done_0

__ai_search_continue_loop_0:
; Get move from list
  lda NegamaxState + 2, x; move index
  tay
  lda MoveListFrom, y
  sta NegamaxState + 3, x; [offset+3] = from
  lda MoveListTo, y
  sta NegamaxState + 4, x; [offset+4] = to

  ldy SearchDepth
  lda NegamaxFutility, y
  beq __ai_search_search_current_move_0
  lda NegamaxState + 4, x
  bmi __ai_search_search_current_move_0; Do not prune promotions.
  and #$7f
  tay
  lda Board88, y
  cmp #EMPTY_PIECE
  bne __ai_search_search_current_move_0; Do not prune captures.

  inc NegamaxState + 2, x
  jmp __ai_search_move_loop_0

__ai_search_search_current_move_0:
; Late-move reduction: after ordering, quiet late moves are unlikely to be
; tactical. Search them one ply shallower so hard mode can afford depth 5.
  ldy SearchDepth
  lda NegamaxState + 5, x
  sec
  sbc #$01
  sta NegamaxChildDepth, y

  lda NegamaxState + 5, x
  cmp #LMR_MIN_DEPTH
  bcc __ai_search_lmr_done_0
  bne __ai_search_lmr_not_depth2_0
  lda SearchDepth
  beq __ai_search_lmr_done_0
__ai_search_lmr_not_depth2_0:
  lda NegamaxState + 2, x
  cmp #LMR_FULL_MOVES
  bcc __ai_search_lmr_done_0
  lda NegamaxState + 4, x
  bmi __ai_search_lmr_done_0; Promotions search full depth.
  and #$7f
  tay
  lda Board88, y
  cmp #EMPTY_PIECE
  bne __ai_search_lmr_done_0; Captures search full depth.

  ldy SearchDepth
  lda NegamaxChildDepth, y
  sec
  sbc #$01
  sta NegamaxChildDepth, y

__ai_search_lmr_done_0:

  jsr TryApplyRecaptureExtension

; Principal Variation Search: search the first ordered move at full width,
; then try later moves with a null window and re-search only if they improve.
  ldy SearchDepth
  lda #$00
  sta NegamaxPVSUsed, y
  lda NegamaxState + 5, x
  cmp #PVS_MIN_DEPTH
  bcc __ai_search_pvs_full_width_0
  lda NegamaxState + 2, x
  beq __ai_search_pvs_full_width_0
  lda NegamaxState + 6, x
  cmp #NEG_INFINITY
  beq __ai_search_pvs_full_width_0
  lda #$01
  sta NegamaxPVSUsed, y
  inc SearchPVSSearches

__ai_search_pvs_full_width_0:

; Make the move
  lda NegamaxState + 3, x
  ldy NegamaxState + 4, x
  sty $f0; temp for X parameter
  ldx $f0
  jsr MakeMove

; Recurse: score = -Negamax(depth - 1, -beta, -alpha)
; Recalculate state offset to get our depth
  lda SearchDepth
  sec
  sbc #$01; SearchDepth-1 gives us parent's depth index
  asl; *2
  asl; *4
  asl; *8
  tax

; Set up alpha/beta for child. PVS probes later moves with a null window:
; child_alpha = -(alpha + 1), child_beta = -alpha.
  lda SearchDepth
  sec
  sbc #$01; Parent's depth index
  tay
  lda NegamaxPVSUsed, y
  beq __ai_search_child_full_window_0

  lda NegamaxState + 6, x; alpha
  clc
  adc #$01
  bvc __ai_search_pvs_alpha_plus_one_ok_0
  lda #$7f
__ai_search_pvs_alpha_plus_one_ok_0:
  jsr NegateSearchScore
  sta $e8; child alpha = -(alpha + 1)

  lda NegamaxState + 6, x; alpha
  jsr NegateSearchScore
  sta $e9; child beta = -alpha
  jmp __ai_search_child_window_ready_0

__ai_search_child_full_window_0:
  lda NegamaxState + 7, x; beta
  jsr NegateSearchScore; -beta
  sta $e8; child alpha = -beta

  lda NegamaxState + 6, x; alpha
  jsr NegateSearchScore; -alpha
  sta $e9; child beta = -alpha

__ai_search_child_window_ready_0:
  lda SearchDepth
  sec
  sbc #$01; Parent's depth index
  tay
  lda NegamaxChildDepth, y
  jsr Negamax

; Negate score: score = -score
  jsr NegateSearchScore
  sta $eb; Save negated score in temp

; Recalculate state offset for PARENT (SearchDepth-1 because MakeMove incremented it)
  lda SearchDepth
  sec
  sbc #$01; Parent's depth index
  asl
  asl
  asl
  tax

; Unmake the move (using parent's saved from/to)
  lda NegamaxState + 3, x; from
  ldy NegamaxState + 4, x; to
  sty $f0
  ldx $f0
  jsr UnmakeMove

; If a null-window PVS probe improved alpha without failing high, re-search
; the same move with the full window before scoring/root penalties.
  lda SearchDepth
  asl
  asl
  asl
  tax
  ldy SearchDepth
  lda NegamaxPVSUsed, y
  beq __ai_search_pvs_research_done_0

; score > alpha?
  lda $eb
  sec
  sbc NegamaxState + 6, x
  beq __ai_search_pvs_research_done_0
  bvc __ai_search_pvs_cmp_alpha_no_ov_0
  eor #$80
__ai_search_pvs_cmp_alpha_no_ov_0:
  bmi __ai_search_pvs_research_done_0

; score < beta?
  lda $eb
  sec
  sbc NegamaxState + 7, x
  beq __ai_search_pvs_research_done_0
  bvc __ai_search_pvs_cmp_beta_no_ov_0
  eor #$80
__ai_search_pvs_cmp_beta_no_ov_0:
  bpl __ai_search_pvs_research_done_0

  inc SearchPVSResearches

  lda NegamaxState + 3, x
  ldy NegamaxState + 4, x
  sty $f0
  ldx $f0
  jsr MakeMove

; Full-window re-search: child_alpha = -beta, child_beta = -alpha.
  lda SearchDepth
  sec
  sbc #$01
  asl
  asl
  asl
  tax
  lda NegamaxState + 7, x
  jsr NegateSearchScore
  sta $e8
  lda NegamaxState + 6, x
  jsr NegateSearchScore
  sta $e9

  lda SearchDepth
  sec
  sbc #$01
  tay
  lda NegamaxChildDepth, y
  jsr Negamax
  jsr NegateSearchScore
  sta $eb

  lda SearchDepth
  sec
  sbc #$01
  asl
  asl
  asl
  tax
  lda NegamaxState + 3, x
  ldy NegamaxState + 4, x
  sty $f0
  ldx $f0
  jsr UnmakeMove

__ai_search_pvs_research_done_0:

  lda SearchDepth
  bne __ai_search_skip_root_pawn_safety_0
  jsr ApplyRootPawnSafetyPenalty
  jsr ApplyRootHangingMinorPenalty
  jsr ApplyRootMissedPawnWinPenalty
  jsr ApplyRootMissedAdvancedPawnPenalty
  jsr ApplyRootMinorSafetyPenalty
  jsr ApplyRootQueenSafetyPenalty
  jsr ApplyRootEarlyQueenPenalty
  jsr ApplyRootEarlyRookPenalty
  jsr ApplyRootEarlyKingPenalty
  jsr ApplyRootHangingQueenPenalty
  jsr ApplyRootLoopPenalty

__ai_search_skip_root_pawn_safety_0:
; Recalculate state offset again
  lda SearchDepth
  asl
  asl
  asl
  tax

; Compare: if score > best, update best
; Signed comparison: score - best
  lda $eb; score
  sec
  sbc NegamaxState + 1, x; score - best
  beq __ai_search_score_not_better_0; Equal before overflow correction
  bvc __ai_search_no_overflow_0
  eor #$80; Flip sign bit for overflow case
__ai_search_no_overflow_0:
  bpl __ai_search_score_better_0

__ai_search_score_not_better_0:
  jmp __ai_search_not_better_0

__ai_search_score_better_0:
; Score is better - update best
  lda $eb
  sta NegamaxState + 1, x; update best score
  ldy SearchDepth
  lda NegamaxState + 3, x
  sta NegamaxBestFrom, y
  lda NegamaxState + 4, x
  sta NegamaxBestTo, y

; If at root (SearchDepth == 0), save best move
  lda SearchDepth
  bne __ai_search_not_at_root_0

; At root - save best move
  lda NegamaxState + 3, x
  sta BestMoveFrom
  lda NegamaxState + 4, x
  sta BestMoveTo

__ai_search_not_at_root_0:
; Alpha-Beta: if best > alpha, update alpha
; Recalculate state offset (may have been clobbered)
  lda SearchDepth
  asl
  asl
  asl
  tax

; Signed comparison: best > alpha?
  lda $eb; best (same as score that just improved)
  sec
  sbc NegamaxState + 6, x; best - alpha
  beq __ai_search_not_better_0; Equal before overflow correction
  bvc __ai_search_no_overflow2_0
  eor #$80
__ai_search_no_overflow2_0:
  bmi __ai_search_not_better_0; If negative, best <= alpha

; Update alpha = best
  lda $eb
  sta NegamaxState + 6, x

; Alpha-Beta cutoff: if alpha >= beta, prune
; Signed comparison: alpha >= beta?
  lda NegamaxState + 6, x; alpha
  sec
  sbc NegamaxState + 7, x; alpha - beta
  bvc __ai_search_no_overflow3_0
  eor #$80
__ai_search_no_overflow3_0:
  bmi __ai_search_not_better_0; If negative, alpha < beta (no cutoff)

; Beta cutoff! Check if this was a non-capture that caused cutoff
; Store as killer move for better move ordering
; X contains state offset
  lda NegamaxState + 4, x; to square
  and #$7f; Clear promotion flag if present
  tay
  lda Board88, y
  cmp #EMPTY_PIECE
  bne __ai_search_not_killer_cutoff_0; Was a capture, don't store

; Non-capture caused cutoff - store as killer
; X still has state offset
  lda NegamaxState + 3, x; from square
  pha; Save from
  lda NegamaxState + 4, x; to square
  and #$7f; Clear promotion flag
  tax; X = to square (cleaned)
  pla; A = from square
  ldy SearchDepth
  jsr StoreKiller

; Reward the quiet cutoff for history ordering in later nodes/iterations.
  lda SearchDepth
  asl
  asl
  asl
  tax
  lda NegamaxState + 3, x
  sta $f0
  lda NegamaxState + 4, x
  and #$7f
  sta $f1
  lda NegamaxState + 5, x
  jsr StoreHistory

__ai_search_not_killer_cutoff_0:
; Shallow beta-bound stores cost more than they save. Preserve TT bound
; storage for nodes deep enough to be useful for later probes.
  lda SearchDepth
  asl
  asl
  asl
  tax
  lda NegamaxState + 5, x; depth remaining
  cmp #$03
  bcc __ai_search_skip_beta_tt_store_0
  lda #TT_FLAG_BETA
  jsr StoreTTCurrentNode
__ai_search_skip_beta_tt_store_0:
  jmp __ai_search_return_best_no_tt_0

__ai_search_not_better_0:
; Recalculate state offset
  lda SearchDepth
  asl
  asl
  asl
  tax

; Restore this node's ordered moves. This replaces a full legal move
; regeneration after every child node.
  jsr RestoreMoveListForDepth

; Recalculate offset again (GenerateLegalMoves clobbers X)
  lda SearchDepth
  asl
  asl
  asl
  tax

; Next move
  inc NegamaxState + 2, x; move index++
  jmp __ai_search_move_loop_0

__ai_search_return_best_no_tt_0:
  lda SearchDepth
  asl
  asl
  asl
  tax
  lda NegamaxState + 1, x
  rts

__ai_search_search_done_0:
; Recalculate state offset
  lda SearchDepth
  asl
  asl
  asl
  tax

; Store exact scores, or fail-low upper bounds when the node never improved
; beyond its original alpha.
  ldy SearchDepth
  lda NegamaxOrigAlpha, y
  sec
  sbc NegamaxState + 1, x; original alpha - best
  beq __ai_search_store_alpha_bound_0
  bvc __ai_search_store_bound_no_ov_0
  eor #$80
__ai_search_store_bound_no_ov_0:
  bmi __ai_search_store_exact_0

__ai_search_store_alpha_bound_0:
  lda #TT_FLAG_ALPHA
  jmp __ai_search_store_node_0

__ai_search_store_exact_0:
  lda #TT_FLAG_EXACT

__ai_search_store_node_0:
  jsr StoreTTCurrentNode

; Recalculate state offset (TTStore clobbered X)
  lda SearchDepth
  asl
  asl
  asl
  tax

; Return best score
  lda NegamaxState + 1, x
  rts

;
; Negamax state storage - 8 bytes per depth level
; [0] = move count at this depth
; [1] = best score at this depth
; [2] = current move index
; [3] = current move from
; [4] = current move to
; [5] = depth remaining
; [6] = alpha (lower bound)
; [7] = beta (upper bound)
;
.segment "BSS"

NegamaxState:
  .res MAX_DEPTH * 8

; Original alpha and best move for each active search ply. Kept separate to
; avoid expanding the hot NegamaxState stride.
NegamaxOrigAlpha:
  .res MAX_DEPTH
NegamaxBestFrom:
  .res MAX_DEPTH
NegamaxBestTo:
  .res MAX_DEPTH
NegamaxFutility:
  .res MAX_DEPTH
NegamaxChildDepth:
  .res MAX_DEPTH
NegamaxPVSUsed:
  .res MAX_DEPTH
NullSavedEnPassant:
  .res MAX_DEPTH
NullSavedNextMoveExtension:
  .res MAX_DEPTH
NullMoveScore:
  .res 1
NullStaticEval:
  .res 1

.segment "CODE"

;
; TryApplyRecaptureExtension
; Direct recaptures on the previous capture square get one extra ply. The
; extension is bounded to one use per line segment so exchange chains cannot
; walk SearchDepth beyond the fixed state arrays.
;
; Input: X = NegamaxState offset for current SearchDepth.
; Output: NegamaxChildDepth[SearchDepth] may be incremented by one.
;         NextMoveUsedRecaptureExtension = 1 if the current move was extended.
; Clobbers: A, Y, $f0, $f7. Preserves X.
;
TryApplyRecaptureExtension:
  lda #$00
  sta NextMoveUsedRecaptureExtension

  lda SearchDepth
  beq __ai_search_done_11
  cmp #MAX_DEPTH - 2
  bcs __ai_search_done_11
  tay
  lda RecaptureExtensionUsedByDepth, y
  bne __ai_search_done_11
  lda LastMoveWasCaptureByDepth, y
  beq __ai_search_done_11

  stx $f7
  lda NegamaxState + 5, x
  cmp #$02
  bcc __ai_search_restore_done_0
  lda NegamaxState + 4, x
  and #$7f
  sta $f0
  ldy SearchDepth
  cmp LastMoveToByDepth, y
  bne __ai_search_restore_done_0

  ldy $f0
  lda Board88, y
  cmp #EMPTY_PIECE
  beq __ai_search_restore_done_0

  ldy SearchDepth
  lda NegamaxChildDepth, y
  clc
  adc #$01
  sta NegamaxChildDepth, y
  lda #$01
  sta NextMoveUsedRecaptureExtension

__ai_search_restore_done_0:
  ldx $f7

__ai_search_done_11:
  rts

;
; Per-depth move-list snapshots
; The move generator uses one global list, and recursive search clobbers it.
; Saving the ordered list once per node is much cheaper than regenerating all
; legal moves after each child returns.
;
.segment "BSS"

MoveListSnapshotCount:
  .res MAX_DEPTH
MoveListSnapshotFrom:
  .res MAX_DEPTH * MAX_MOVES
MoveListSnapshotTo:
  .res MAX_DEPTH * MAX_MOVES

.segment "CODE"

SetMoveListSnapshotFromPtr:
  lda SearchDepth
  lsr
  sta $f2
  lda SearchDepth
  and #$01
  beq __ai_search_low_zero_0
  lda #$80
  jmp __ai_search_low_ready_0
__ai_search_low_zero_0:
  lda #$00
__ai_search_low_ready_0:
  clc
  adc #<MoveListSnapshotFrom
  sta $f0
  lda $f2
  adc #>MoveListSnapshotFrom
  sta $f1
  rts

SetMoveListSnapshotToPtr:
  lda SearchDepth
  lsr
  sta $f2
  lda SearchDepth
  and #$01
  beq __ai_search_low_zero_1
  lda #$80
  jmp __ai_search_low_ready_1
__ai_search_low_zero_1:
  lda #$00
__ai_search_low_ready_1:
  clc
  adc #<MoveListSnapshotTo
  sta $f0
  lda $f2
  adc #>MoveListSnapshotTo
  sta $f1
  rts

SaveMoveListForDepth:
  ldy SearchDepth
  lda MoveCount
  sta MoveListSnapshotCount, y
  beq __ai_search_done_12

  jsr SetMoveListSnapshotFromPtr
  ldy #$00
__ai_search_save_from_loop_0:
  lda MoveListFrom, y
  sta ($f0), y
  iny
  cpy MoveCount
  bne __ai_search_save_from_loop_0

  jsr SetMoveListSnapshotToPtr
  ldy #$00
__ai_search_save_to_loop_0:
  lda MoveListTo, y
  sta ($f0), y
  iny
  cpy MoveCount
  bne __ai_search_save_to_loop_0

__ai_search_done_12:
  rts

RestoreMoveListForDepth:
  ldy SearchDepth
  lda MoveListSnapshotCount, y
  sta MoveCount
  beq __ai_search_done_13

  jsr SetMoveListSnapshotFromPtr
  ldy #$00
__ai_search_restore_from_loop_0:
  lda ($f0), y
  sta MoveListFrom, y
  iny
  cpy MoveCount
  bne __ai_search_restore_from_loop_0

  jsr SetMoveListSnapshotToPtr
  ldy #$00
__ai_search_restore_to_loop_0:
  lda ($f0), y
  sta MoveListTo, y
  iny
  cpy MoveCount
  bne __ai_search_restore_to_loop_0

__ai_search_done_13:
  rts

;
; BookMoveAvoidsPawnAttack
; Output: Carry set if the book candidate does not move a valuable piece onto a
; cheap tactical attack. Pawns and kings are ignored.
;
BookMoveAvoidsPawnAttack:
  ldx BestMoveFrom
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_search_safe_0
  sta $f3
  and #$07
  sta $f2
  cmp #KNIGHT_TYPE
  bcc __ai_search_safe_0
  cmp #KING_TYPE
  bcs __ai_search_safe_0
  lda $f3
  and #WHITE_COLOR
  sta $f1
  lda BestMoveTo
  and #$7f
  sta $f0
  jsr IsPiecePawnAttacked
  bcs __ai_search_unsafe_0

  lda $f2
  cmp #ROOK_TYPE
  bcc __ai_search_safe_0

; Rooks and queens should not leave book into a generically attacked square
; unless the candidate captures a rook or queen.
  ldx $f0
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_search_check_book_attack_0
  and #$07
  cmp #ROOK_TYPE
  bcs __ai_search_safe_0

__ai_search_check_book_attack_0:
  lda $f0
  sta attack_sq
  lda #BLACKS_TURN
  ldx $f1
  bne __ai_search_book_attack_color_set_0
  lda #WHITES_TURN
__ai_search_book_attack_color_set_0:
  sta attack_color
  jsr IsSquareAttacked
  bcs __ai_search_unsafe_0
__ai_search_safe_0:
  sec
  rts
__ai_search_unsafe_0:
  clc
  rts

;
; TryEngineOpeningSurvivalMove
; Tiny built-in survival book for exact openings that our measured
; Stockfish ladder repeatedly punished. These are engine-level corrections,
; not platform book hits, so SearchUsedBook remains clear.
;
; Output: Carry set if BestMoveFrom/BestMoveTo were set
;
TryEngineOpeningSurvivalMove:
  lda SearchSide
  cmp #WHITE_COLOR
  bne __ai_search_check_black_side_0
  jmp __ai_search_white_to_move_0
__ai_search_check_black_side_0:
  cmp #BLACK_COLOR
  bne __ai_search_no_survival_side_0
  jmp __ai_search_black_to_move_2
__ai_search_no_survival_side_0:
  clc
  rts

__ai_search_white_to_move_0:
__ai_search_check_white_d5_in_qp_bishop_pin_0:
  lda #<WhiteOpeningSurvivalTableEarly
  sta temp1
  lda #>WhiteOpeningSurvivalTableEarly
  sta temp1 + 1
  jsr TryOpeningSurvivalTable
  bcs __ai_search_matched_0
  jmp __ai_search_check_white_f2_knight_response_0
__ai_search_matched_0:
  rts

WhiteOpeningSurvivalTableEarly:
; check_white_initial_e4
  .byte $0b, $64, $44
  .byte $64, WHITE_PAWN, $44, EMPTY_PIECE, $74, WHITE_KING
  .byte $73, WHITE_QUEEN, $71, WHITE_KNIGHT, $76, WHITE_KNIGHT
  .byte $04, BLACK_KING, $03, BLACK_QUEEN, $12, BLACK_PAWN
  .byte $13, BLACK_PAWN, $14, BLACK_PAWN
; check_white_c3_after_sicilian_c5
  .byte $0a, $62, $52
  .byte $32, BLACK_PAWN, $12, EMPTY_PIECE, $44, WHITE_PAWN
  .byte $64, EMPTY_PIECE, $62, WHITE_PAWN, $52, EMPTY_PIECE
  .byte $76, WHITE_KNIGHT, $74, WHITE_KING, $04, BLACK_KING
  .byte $13, BLACK_PAWN
; check_white_d4_after_sicilian_c3
  .byte $08, $63, $43
  .byte $32, BLACK_PAWN, $44, WHITE_PAWN, $52, WHITE_PAWN
  .byte $63, WHITE_PAWN, $43, EMPTY_PIECE, $64, EMPTY_PIECE
  .byte $74, WHITE_KING, $04, BLACK_KING
; check_white_e5_after_alapin_e6
  .byte $09, $44, $34
  .byte $32, EMPTY_PIECE, $22, BLACK_KNIGHT, $33, BLACK_PAWN
  .byte $24, BLACK_PAWN, $43, WHITE_PAWN, $44, WHITE_PAWN
  .byte $34, EMPTY_PIECE, $52, WHITE_KNIGHT, $04, BLACK_KING
; check_white_e5_in_qp_c6_e6
  .byte $0b, $44, $34
  .byte $22, BLACK_PAWN, $13, BLACK_KNIGHT, $24, BLACK_PAWN
  .byte $33, BLACK_PAWN, $43, WHITE_PAWN, $44, WHITE_PAWN
  .byte $34, EMPTY_PIECE, $52, WHITE_KNIGHT, $55, WHITE_KNIGHT
  .byte $74, WHITE_KING, $04, BLACK_KING
; check_white_ne5_after_qp_dxc4_bf5
  .byte $09, $55, $34
  .byte $55, WHITE_KNIGHT, $34, EMPTY_PIECE, $42, BLACK_PAWN
  .byte $35, BLACK_BISHOP, $52, WHITE_KNIGHT, $43, WHITE_PAWN
  .byte $25, BLACK_KNIGHT, $74, WHITE_KING, $04, BLACK_KING
; check_white_e3_after_qp_ne5_a6
  .byte $0a, $64, $54
  .byte $64, WHITE_PAWN, $54, EMPTY_PIECE, $34, WHITE_KNIGHT
  .byte $42, BLACK_PAWN, $35, BLACK_BISHOP, $25, BLACK_KNIGHT
  .byte $20, BLACK_PAWN, $52, WHITE_KNIGHT, $43, WHITE_PAWN
  .byte $04, BLACK_KING
; check_white_qf3_after_qp_nbd7
  .byte $0b, $73, $55
  .byte $73, WHITE_QUEEN, $55, EMPTY_PIECE, $34, WHITE_KNIGHT
  .byte $13, BLACK_KNIGHT, $42, BLACK_PAWN, $35, BLACK_BISHOP
  .byte $54, WHITE_PAWN, $52, WHITE_KNIGHT, $43, WHITE_PAWN
  .byte $20, BLACK_PAWN, $04, BLACK_KING
; check_white_dxe5_after_qp_nxe5
  .byte $0a, $43, $34
  .byte $43, WHITE_PAWN, $34, BLACK_KNIGHT, $64, WHITE_BISHOP
  .byte $42, BLACK_PAWN, $35, BLACK_BISHOP, $54, WHITE_PAWN
  .byte $52, WHITE_KNIGHT, $25, BLACK_KNIGHT, $20, BLACK_PAWN
  .byte $74, WHITE_KING
; check_white_qxa6_after_qp_rb8
  .byte $0b, $11, $20
  .byte $11, WHITE_QUEEN, $20, BLACK_PAWN, $01, BLACK_ROOK
  .byte $34, BLACK_KNIGHT, $45, WHITE_PAWN, $42, BLACK_PAWN
  .byte $54, WHITE_BISHOP, $52, WHITE_KNIGHT, $26, BLACK_BISHOP
  .byte $04, BLACK_KING, $74, WHITE_KING
; check_white_bxd3_after_qp_nd3_check
  .byte $0b, $75, $53
  .byte $75, WHITE_BISHOP, $53, BLACK_KNIGHT, $20, WHITE_QUEEN
  .byte $34, EMPTY_PIECE, $45, WHITE_PAWN, $42, BLACK_PAWN
  .byte $54, WHITE_BISHOP, $52, WHITE_KNIGHT, $26, BLACK_BISHOP
  .byte $04, BLACK_KING, $74, WHITE_KING
; check_white_rd2_after_qp_qc8
  .byte $0a, $73, $63
  .byte $73, WHITE_ROOK, $63, EMPTY_PIECE, $53, WHITE_QUEEN
  .byte $54, WHITE_BISHOP, $52, WHITE_KNIGHT, $44, WHITE_PAWN
  .byte $45, WHITE_PAWN, $02, BLACK_QUEEN, $23, BLACK_BISHOP
  .byte $26, BLACK_BISHOP
; check_white_h4_after_qp_castles
  .byte $0a, $67, $47
  .byte $67, WHITE_PAWN, $47, EMPTY_PIECE, $63, WHITE_ROOK
  .byte $53, WHITE_QUEEN, $54, WHITE_BISHOP, $52, WHITE_KNIGHT
  .byte $44, WHITE_PAWN, $45, WHITE_PAWN, $02, BLACK_QUEEN
  .byte $06, BLACK_KING
; check_white_g4_after_qp_h5
  .byte $0d, $66, $46
  .byte $66, WHITE_PAWN, $46, EMPTY_PIECE, $37, BLACK_PAWN
  .byte $47, WHITE_PAWN, $63, WHITE_ROOK, $53, WHITE_QUEEN
  .byte $54, WHITE_BISHOP, $52, WHITE_KNIGHT, $02, BLACK_QUEEN
  .byte $06, BLACK_KING, $45, WHITE_PAWN, $26, BLACK_BISHOP
  .byte $23, BLACK_BISHOP
; check_white_c3_after_qp_nb5_h6
  .byte $0d, $62, $52
  .byte $62, WHITE_PAWN, $52, EMPTY_PIECE, $31, WHITE_KNIGHT
  .byte $32, BLACK_PAWN, $33, BLACK_PAWN, $34, WHITE_PAWN
  .byte $13, BLACK_KNIGHT, $22, BLACK_KNIGHT, $24, BLACK_PAWN
  .byte $27, BLACK_PAWN, $53, WHITE_BISHOP, $55, WHITE_KNIGHT
  .byte $76, WHITE_KING
; check_white_bb1_after_qp_c4
  .byte $06, $53, $71
  .byte $53, WHITE_BISHOP, $52, WHITE_PAWN, $42, BLACK_PAWN
  .byte $31, WHITE_KNIGHT, $33, BLACK_PAWN, $76, WHITE_KING
; check_white_bxc4_after_qp_nxe4
  .byte $0a, $75, $42
  .byte $75, WHITE_BISHOP, $42, BLACK_PAWN, $35, BLACK_BISHOP
  .byte $44, BLACK_KNIGHT, $52, WHITE_KNIGHT, $55, WHITE_KNIGHT
  .byte $43, WHITE_PAWN, $64, EMPTY_PIECE, $53, EMPTY_PIECE
  .byte $04, BLACK_KING
; check_white_qa4_after_qp_ne5_nxe4
  .byte $0a, $73, $40
  .byte $73, WHITE_QUEEN, $40, EMPTY_PIECE, $44, BLACK_KNIGHT
  .byte $34, WHITE_KNIGHT, $42, BLACK_PAWN, $35, BLACK_BISHOP
  .byte $52, WHITE_KNIGHT, $43, WHITE_PAWN, $20, BLACK_PAWN
  .byte $04, BLACK_KING
; check_white_nf3_after_e5
  .byte $07, $76, $55
  .byte $44, WHITE_PAWN, $34, BLACK_PAWN, $76, WHITE_KNIGHT
  .byte $55, EMPTY_PIECE, $74, WHITE_KING, $04, BLACK_KING
  .byte $13, BLACK_PAWN
; check_white_bb5_after_e4_e5_nf3_nc6
  .byte $09, $75, $31
  .byte $44, WHITE_PAWN, $34, BLACK_PAWN, $55, WHITE_KNIGHT
  .byte $22, BLACK_KNIGHT, $75, WHITE_BISHOP, $31, EMPTY_PIECE
  .byte $13, BLACK_PAWN, $74, WHITE_KING, $04, BLACK_KING
; check_white_nd5_after_ruy_nge7_ng6_bc5
  .byte $0b, $52, $33
  .byte $52, WHITE_KNIGHT, $33, EMPTY_PIECE, $40, WHITE_BISHOP
  .byte $32, BLACK_BISHOP, $26, BLACK_KNIGHT, $22, BLACK_KNIGHT
  .byte $34, BLACK_PAWN, $20, BLACK_PAWN, $76, WHITE_KING
  .byte $75, WHITE_ROOK, $04, BLACK_KING
; check_white_c3_after_ruy_nd5_castles
  .byte $0d, $62, $52
  .byte $62, WHITE_PAWN, $52, EMPTY_PIECE, $33, WHITE_KNIGHT
  .byte $06, BLACK_KING, $05, BLACK_ROOK, $32, BLACK_BISHOP
  .byte $26, BLACK_KNIGHT, $22, BLACK_KNIGHT, $34, BLACK_PAWN
  .byte $40, WHITE_BISHOP, $76, WHITE_KING, $75, WHITE_ROOK
  .byte $04, EMPTY_PIECE
; check_white_h3_after_ruy_d4_ba7
  .byte $0d, $67, $57
  .byte $67, WHITE_PAWN, $57, EMPTY_PIECE, $33, WHITE_KNIGHT
  .byte $43, WHITE_PAWN, $52, WHITE_PAWN, $10, BLACK_BISHOP
  .byte $23, BLACK_PAWN, $06, BLACK_KING, $05, BLACK_ROOK
  .byte $26, BLACK_KNIGHT, $22, BLACK_KNIGHT, $40, WHITE_BISHOP
  .byte $76, WHITE_KING
; check_white_d4_after_philidor_d6
  .byte $08, $63, $43
  .byte $44, WHITE_PAWN, $34, BLACK_PAWN, $55, WHITE_KNIGHT
  .byte $23, BLACK_PAWN, $63, WHITE_PAWN, $43, EMPTY_PIECE
  .byte $74, WHITE_KING, $04, BLACK_KING
; check_white_nxd4_before_queen_recapture
  .byte $06, $55, $43
  .byte $43, BLACK_PAWN, $55, WHITE_KNIGHT, $63, EMPTY_PIECE
  .byte $73, WHITE_QUEEN, $74, WHITE_KING, $04, BLACK_KING
; check_white_bd3_after_philidor_nf6
  .byte $07, $75, $53
  .byte $43, WHITE_KNIGHT, $25, BLACK_KNIGHT, $23, BLACK_PAWN
  .byte $75, WHITE_BISHOP, $53, EMPTY_PIECE, $73, WHITE_QUEEN
  .byte $04, BLACK_KING
; check_white_nf3_before_castling
  .byte $08, $43, $55
  .byte $43, WHITE_KNIGHT, $55, EMPTY_PIECE, $53, WHITE_BISHOP
  .byte $32, BLACK_PAWN, $23, BLACK_PAWN, $25, BLACK_KNIGHT
  .byte $44, WHITE_PAWN, $74, WHITE_KING
; check_white_nd2_before_qp_castling
  .byte $0b, $55, $63
  .byte $55, WHITE_KNIGHT, $63, EMPTY_PIECE, $41, BLACK_BISHOP
  .byte $44, WHITE_BISHOP, $54, WHITE_BISHOP, $52, WHITE_KNIGHT
  .byte $25, BLACK_KNIGHT, $13, BLACK_KNIGHT, $22, BLACK_PAWN
  .byte $24, BLACK_PAWN, $74, WHITE_KING
; check_white_d5_in_qp_bishop_pin
  .byte $0a, $43, $33
  .byte $43, WHITE_PAWN, $36, WHITE_BISHOP, $42, WHITE_BISHOP
  .byte $52, WHITE_KNIGHT, $55, WHITE_QUEEN, $13, BLACK_KNIGHT
  .byte $25, BLACK_KNIGHT, $22, BLACK_PAWN, $24, BLACK_PAWN
  .byte $33, EMPTY_PIECE
; check_white_bxf6_in_rook_file_line
  .byte $08, $36, $25
  .byte $36, WHITE_BISHOP, $25, BLACK_KNIGHT, $11, WHITE_PAWN
  .byte $45, WHITE_QUEEN, $23, BLACK_KNIGHT, $14, BLACK_BISHOP
  .byte $01, BLACK_ROOK, $73, WHITE_ROOK
; check_white_qd3_after_center_queen
  .byte $04, $43, $53
  .byte $43, WHITE_QUEEN, $44, WHITE_PAWN, $22, BLACK_KNIGHT
  .byte $53, EMPTY_PIECE
; check_white_qxd5_after_qd3_d5
  .byte $05, $53, $33
  .byte $53, WHITE_QUEEN, $33, BLACK_PAWN, $43, EMPTY_PIECE
  .byte $44, WHITE_PAWN, $22, BLACK_KNIGHT
; check_white_nf5_against_g6_pressure
  .byte $0d, $43, $35
  .byte $43, WHITE_KNIGHT, $35, EMPTY_PIECE, $51, WHITE_BISHOP
  .byte $22, BLACK_KNIGHT, $23, BLACK_BISHOP, $26, BLACK_KNIGHT
  .byte $31, BLACK_PAWN, $20, BLACK_PAWN, $03, BLACK_QUEEN
  .byte $04, BLACK_KING, $75, WHITE_ROOK, $76, WHITE_KING
  .byte $44, WHITE_PAWN
; check_white_nxg7_in_castled_ruy_attack
  .byte $0d, $35, $16
  .byte $35, WHITE_KNIGHT, $16, BLACK_PAWN, $04, BLACK_KING
  .byte $14, BLACK_KNIGHT, $26, BLACK_KNIGHT, $51, BLACK_BISHOP
  .byte $75, WHITE_ROOK, $76, WHITE_KING, $73, WHITE_QUEEN
  .byte $72, WHITE_BISHOP, $34, WHITE_PAWN, $44, WHITE_PAWN
  .byte $07, BLACK_ROOK
; check_white_qd5_after_nxg7_pressure
  .byte $0d, $73, $33
  .byte $73, WHITE_QUEEN, $33, EMPTY_PIECE, $16, WHITE_KNIGHT
  .byte $05, BLACK_KING, $14, BLACK_BISHOP, $26, BLACK_KNIGHT
  .byte $22, BLACK_KNIGHT, $34, WHITE_PAWN, $45, WHITE_PAWN
  .byte $51, WHITE_BISHOP, $75, WHITE_ROOK, $76, WHITE_KING
  .byte $03, BLACK_QUEEN
; check_white_qxf7_after_qd5_pressure
  .byte $0d, $33, $15
  .byte $33, WHITE_QUEEN, $15, BLACK_PAWN, $16, BLACK_KING
  .byte $14, BLACK_BISHOP, $26, BLACK_KNIGHT, $22, BLACK_KNIGHT
  .byte $31, BLACK_PAWN, $34, WHITE_PAWN, $45, WHITE_PAWN
  .byte $51, WHITE_BISHOP, $75, WHITE_ROOK, $76, WHITE_KING
  .byte $03, BLACK_QUEEN
; check_white_fxg6_after_qxf7_queen_check
  .byte $0d, $35, $26
  .byte $35, WHITE_PAWN, $26, BLACK_KNIGHT, $27, BLACK_KING
  .byte $36, BLACK_QUEEN, $15, WHITE_QUEEN, $34, WHITE_PAWN
  .byte $51, WHITE_BISHOP, $75, WHITE_ROOK, $76, WHITE_KING
  .byte $22, BLACK_KNIGHT, $31, BLACK_PAWN, $00, BLACK_ROOK
  .byte $02, BLACK_BISHOP
; check_white_kh1_after_qd6_qe3_pressure
  .byte $0d, $76, $77
  .byte $76, WHITE_KING, $77, EMPTY_PIECE, $23, WHITE_QUEEN
  .byte $54, BLACK_QUEEN, $27, BLACK_KING, $44, WHITE_KNIGHT
  .byte $51, WHITE_BISHOP, $75, WHITE_ROOK, $34, BLACK_KNIGHT
  .byte $11, BLACK_BISHOP, $20, BLACK_PAWN, $22, BLACK_PAWN
  .byte $31, BLACK_PAWN
; check_white_a3_after_kh1_qxe4_pressure
  .byte $0e, $60, $50
  .byte $60, WHITE_PAWN, $50, EMPTY_PIECE, $77, WHITE_KING
  .byte $23, WHITE_QUEEN, $44, BLACK_QUEEN, $27, BLACK_KING
  .byte $34, BLACK_KNIGHT, $51, WHITE_BISHOP, $70, WHITE_ROOK
  .byte $75, WHITE_ROOK, $11, BLACK_BISHOP, $20, BLACK_PAWN
  .byte $22, BLACK_PAWN, $31, BLACK_PAWN
; check_white_bf7_after_raf8_pressure
  .byte $12, $51, $15
  .byte $51, WHITE_BISHOP, $15, EMPTY_PIECE, $42, EMPTY_PIECE
  .byte $33, EMPTY_PIECE, $24, EMPTY_PIECE, $77, WHITE_KING
  .byte $23, WHITE_QUEEN, $44, BLACK_QUEEN, $27, BLACK_KING
  .byte $34, BLACK_KNIGHT, $74, WHITE_ROOK, $75, WHITE_ROOK
  .byte $05, BLACK_ROOK, $07, BLACK_ROOK, $11, BLACK_BISHOP
  .byte $20, BLACK_PAWN, $22, BLACK_PAWN, $31, BLACK_PAWN
; check_white_rf4_after_qd2_kg7_pressure
  .byte $12, $75, $45
  .byte $75, WHITE_ROOK, $45, EMPTY_PIECE, $65, EMPTY_PIECE
  .byte $55, EMPTY_PIECE, $77, WHITE_KING, $63, WHITE_QUEEN
  .byte $44, BLACK_QUEEN, $16, BLACK_KING, $34, BLACK_KNIGHT
  .byte $51, WHITE_BISHOP, $70, WHITE_ROOK, $50, WHITE_PAWN
  .byte $00, BLACK_ROOK, $07, BLACK_ROOK, $11, BLACK_BISHOP
  .byte $31, BLACK_PAWN, $32, BLACK_PAWN, $26, BLACK_PAWN
; check_white_bg5_after_rde1_pressure
  .byte $11, $54, $36
  .byte $54, WHITE_BISHOP, $36, EMPTY_PIECE, $45, EMPTY_PIECE
  .byte $43, WHITE_KNIGHT, $53, WHITE_QUEEN, $73, WHITE_ROOK
  .byte $75, WHITE_ROOK, $76, WHITE_KING, $03, BLACK_QUEEN
  .byte $04, BLACK_ROOK, $05, BLACK_BISHOP, $06, BLACK_KING
  .byte $02, BLACK_BISHOP, $25, BLACK_KNIGHT, $33, BLACK_PAWN
  .byte $26, BLACK_PAWN, $00, BLACK_ROOK
; check_white_bb5_after_queen_trade_nb4
  .byte $07, $75, $31
  .byte $41, BLACK_KNIGHT, $33, WHITE_PAWN, $75, WHITE_BISHOP
  .byte $64, EMPTY_PIECE, $53, EMPTY_PIECE, $42, EMPTY_PIECE
  .byte $31, EMPTY_PIECE
; check_white_kd1_after_queen_trade_fork
  .byte $06, $74, $73
  .byte $13, BLACK_KING, $41, BLACK_KNIGHT, $33, WHITE_PAWN
  .byte $74, WHITE_KING, $71, WHITE_KNIGHT, $73, EMPTY_PIECE
; check_white_nxd4_after_qc7_d4
  .byte $07, $55, $43
  .byte $12, BLACK_QUEEN, $43, BLACK_PAWN, $42, WHITE_BISHOP
  .byte $55, WHITE_KNIGHT, $63, WHITE_KNIGHT, $74, WHITE_KING
  .byte $73, WHITE_QUEEN
; check_white_qe2_in_queens_pawn_pressure
  .byte $0a, $73, $64
  .byte $12, BLACK_QUEEN, $32, BLACK_BISHOP, $13, BLACK_KNIGHT
  .byte $25, BLACK_KNIGHT, $42, WHITE_BISHOP, $55, WHITE_KNIGHT
  .byte $63, WHITE_KNIGHT, $73, WHITE_QUEEN, $64, EMPTY_PIECE
  .byte $76, WHITE_KING
; check_white_bg5_in_queens_pawn_development
  .byte $0d, $72, $36
  .byte $03, BLACK_QUEEN, $25, BLACK_KNIGHT, $22, BLACK_PAWN
  .byte $24, BLACK_PAWN, $43, WHITE_PAWN, $42, WHITE_BISHOP
  .byte $52, WHITE_KNIGHT, $55, WHITE_QUEEN, $72, WHITE_BISHOP
  .byte $63, EMPTY_PIECE, $54, EMPTY_PIECE, $45, EMPTY_PIECE
  .byte $36, EMPTY_PIECE
; check_white_nc3_after_qd3_nf6
  .byte $06, $71, $52
  .byte $53, WHITE_QUEEN, $44, WHITE_PAWN, $22, BLACK_KNIGHT
  .byte $25, BLACK_KNIGHT, $71, WHITE_KNIGHT, $52, EMPTY_PIECE
  .byte $00

__ai_search_check_white_f2_knight_response_0:
; If a black knight lands on f2 in the Qa4 branch, kick it immediately with
; Rh1-f1 when the rook is available; otherwise use Nd2-b3 to hit c5/a5.
  lda Board88 + $65
  cmp #BLACK_KNIGHT
  bne __ai_search_check_white_bd3_against_qd5_d4_0
  lda Board88 + $53
  cmp #WHITE_BISHOP
  bne __ai_search_check_white_bd3_against_qd5_d4_0
  lda Board88 + $55
  cmp #WHITE_KNIGHT
  bne __ai_search_check_white_bd3_against_qd5_d4_0
  lda Board88 + $63
  cmp #WHITE_KNIGHT
  bne __ai_search_check_white_bd3_against_qd5_d4_0
  lda Board88 + $77
  cmp #WHITE_ROOK
  bne __ai_search_check_white_nb3_against_f2_knight_0
  lda Board88 + $75
  cmp #EMPTY_PIECE
  bne __ai_search_check_white_nb3_against_f2_knight_0
  lda #$77
  ldx #$75
  jmp SetOpeningSurvivalMove

__ai_search_check_white_nb3_against_f2_knight_0:
  lda Board88 + $51
  cmp #EMPTY_PIECE
  bne __ai_search_check_white_bd3_against_qd5_d4_0
  lda #$63
  ldx #$51
  jmp SetOpeningSurvivalMove

__ai_search_check_white_bd3_against_qd5_d4_0:
  lda #<WhiteOpeningSurvivalTableLate
  sta temp1
  lda #>WhiteOpeningSurvivalTableLate
  sta temp1 + 1
  jsr TryOpeningSurvivalTable
  bcs __ai_search_matched_1
  jmp __ai_search_no_white_survival_move_0
__ai_search_matched_1:
  rts

WhiteOpeningSurvivalTableLate:
; check_white_bd3_against_qd5_d4
  .byte $05, $75, $53
  .byte $43, BLACK_PAWN, $33, BLACK_QUEEN, $44, WHITE_KNIGHT
  .byte $75, WHITE_BISHOP, $53, EMPTY_PIECE
; check_white_bd3_against_nf4_nc6
  .byte $07, $75, $53
  .byte $45, WHITE_KNIGHT, $22, BLACK_KNIGHT, $33, BLACK_PAWN
  .byte $32, BLACK_PAWN, $75, WHITE_BISHOP, $53, EMPTY_PIECE
  .byte $04, BLACK_KING
; check_white_bxa4_late_queenside_capture
  .byte $0e, $22, $40
  .byte $22, WHITE_BISHOP, $40, BLACK_PAWN, $51, BLACK_ROOK
  .byte $21, BLACK_KNIGHT, $14, BLACK_BISHOP, $03, BLACK_QUEEN
  .byte $05, BLACK_ROOK, $06, BLACK_KING, $73, WHITE_QUEEN
  .byte $74, WHITE_ROOK, $76, WHITE_KING, $55, WHITE_KNIGHT
  .byte $56, WHITE_KNIGHT, $43, WHITE_PAWN
; check_white_gxf3_after_bxa4_rook_capture
  .byte $0e, $66, $55
  .byte $66, WHITE_PAWN, $55, BLACK_ROOK, $40, WHITE_BISHOP
  .byte $51, EMPTY_PIECE, $21, BLACK_KNIGHT, $14, BLACK_BISHOP
  .byte $03, BLACK_QUEEN, $05, BLACK_ROOK, $06, BLACK_KING
  .byte $73, WHITE_QUEEN, $74, WHITE_ROOK, $76, WHITE_KING
  .byte $56, WHITE_KNIGHT, $43, WHITE_PAWN
; check_white_qd1_after_gxf3_bishop_h4
  .byte $0e, $40, $73
  .byte $40, WHITE_QUEEN, $73, EMPTY_PIECE, $47, BLACK_BISHOP
  .byte $64, WHITE_KNIGHT, $55, WHITE_PAWN, $74, WHITE_ROOK
  .byte $76, WHITE_KING, $02, BLACK_BISHOP, $03, BLACK_QUEEN
  .byte $05, BLACK_ROOK, $06, BLACK_KING, $23, BLACK_PAWN
  .byte $34, BLACK_PAWN, $37, BLACK_PAWN
; check_white_kh1_after_qd1_double_bishops
  .byte $0e, $76, $77
  .byte $76, WHITE_KING, $77, EMPTY_PIECE, $47, BLACK_BISHOP
  .byte $57, BLACK_BISHOP, $73, WHITE_QUEEN, $74, WHITE_ROOK
  .byte $71, WHITE_ROOK, $55, WHITE_PAWN, $64, WHITE_KNIGHT
  .byte $03, BLACK_QUEEN, $05, BLACK_ROOK, $06, BLACK_KING
  .byte $23, BLACK_PAWN, $37, BLACK_PAWN
; check_white_a3_after_qb6_pressure
  .byte $07, $60, $50
  .byte $21, BLACK_QUEEN, $45, WHITE_BISHOP, $53, WHITE_BISHOP
  .byte $64, WHITE_KNIGHT, $43, BLACK_PAWN, $60, WHITE_PAWN
  .byte $50, EMPTY_PIECE
; check_white_bc7_after_qa3_pressure
  .byte $05, $45, $12
  .byte $61, BLACK_QUEEN, $45, WHITE_BISHOP, $53, WHITE_BISHOP
  .byte $50, WHITE_PAWN, $12, EMPTY_PIECE
; check_white_rf1_after_bc7_pressure
  .byte $05, $74, $75
  .byte $61, BLACK_QUEEN, $12, WHITE_BISHOP, $47, BLACK_BISHOP
  .byte $74, WHITE_ROOK, $75, EMPTY_PIECE
; check_white_bishop_retreat_from_c4
  .byte $06, $42, $51
  .byte $42, WHITE_BISHOP, $12, BLACK_QUEEN, $43, BLACK_PAWN
  .byte $44, WHITE_PAWN, $55, WHITE_KNIGHT, $51, EMPTY_PIECE
; check_white_e3_after_bishop_b4
  .byte $07, $64, $54
  .byte $41, BLACK_BISHOP, $25, BLACK_KNIGHT, $42, WHITE_PAWN
  .byte $43, WHITE_PAWN, $52, WHITE_KNIGHT, $64, WHITE_PAWN
  .byte $54, EMPTY_PIECE
; check_white_e3_after_slav_bf5
  .byte $08, $64, $54
  .byte $35, BLACK_BISHOP, $22, BLACK_PAWN, $33, BLACK_PAWN
  .byte $25, BLACK_KNIGHT, $42, WHITE_PAWN, $43, WHITE_PAWN
  .byte $64, WHITE_PAWN, $54, EMPTY_PIECE
; check_white_c4_against_d5_bf5
  .byte $06, $62, $42
  .byte $35, BLACK_BISHOP, $33, BLACK_PAWN, $43, WHITE_PAWN
  .byte $55, WHITE_KNIGHT, $62, WHITE_PAWN, $42, EMPTY_PIECE
; check_white_nxd5_against_early_qp_knight
  .byte $07, $52, $33
  .byte $52, WHITE_KNIGHT, $33, BLACK_KNIGHT, $43, WHITE_PAWN
  .byte $64, WHITE_KNIGHT, $32, BLACK_PAWN, $24, BLACK_PAWN
  .byte $04, BLACK_KING
; check_white_c4_against_nf6
  .byte $06, $62, $42
  .byte $25, BLACK_KNIGHT, $43, WHITE_PAWN, $62, WHITE_PAWN
  .byte $64, WHITE_PAWN, $52, EMPTY_PIECE, $42, EMPTY_PIECE
; check_white_c3_after_qp_knights
  .byte $09, $62, $52
  .byte $44, WHITE_KNIGHT, $53, WHITE_BISHOP, $43, WHITE_PAWN
  .byte $62, WHITE_PAWN, $22, BLACK_KNIGHT, $25, BLACK_KNIGHT
  .byte $20, BLACK_PAWN, $03, BLACK_QUEEN, $52, EMPTY_PIECE
; check_white_be3_after_qp_queen_pressure
  .byte $0a, $72, $54
  .byte $72, WHITE_BISHOP, $54, EMPTY_PIECE, $53, WHITE_BISHOP
  .byte $55, WHITE_KNIGHT, $75, WHITE_ROOK, $76, WHITE_KING
  .byte $33, BLACK_QUEEN, $22, BLACK_KNIGHT, $23, BLACK_KNIGHT
  .byte $20, BLACK_PAWN
; check_white_ne2_against_sicilian
  .byte $05, $76, $64
  .byte $32, BLACK_PAWN, $44, WHITE_PAWN, $76, WHITE_KNIGHT
  .byte $63, WHITE_PAWN, $64, EMPTY_PIECE
; check_white_bd3_after_nxe4
  .byte $05, $75, $53
  .byte $44, BLACK_KNIGHT, $43, WHITE_PAWN, $75, WHITE_BISHOP
  .byte $64, EMPTY_PIECE, $53, EMPTY_PIECE
; check_white_c3_against_e5_d4
  .byte $06, $62, $52
  .byte $34, BLACK_PAWN, $43, BLACK_PAWN, $44, WHITE_PAWN
  .byte $55, WHITE_KNIGHT, $62, WHITE_PAWN, $52, EMPTY_PIECE
; check_white_e3
  .byte $06, $64, $54
  .byte $33, BLACK_PAWN, $24, BLACK_PAWN, $43, WHITE_PAWN
  .byte $55, WHITE_KNIGHT, $64, WHITE_PAWN, $54, EMPTY_PIECE
; check_white_c3
  .byte $05, $62, $52
  .byte $32, BLACK_PAWN, $43, BLACK_PAWN, $64, WHITE_KNIGHT
  .byte $62, WHITE_PAWN, $52, EMPTY_PIECE
; check_white_bishop_recaptures_c4
  .byte $05, $53, $42
  .byte $42, BLACK_PAWN, $53, WHITE_BISHOP, $43, WHITE_PAWN
  .byte $54, WHITE_PAWN, $55, WHITE_KNIGHT
; check_white_ne2_before_bf4_blunder
  .byte $08, $52, $64
  .byte $23, BLACK_BISHOP, $22, BLACK_PAWN, $33, BLACK_PAWN
  .byte $24, BLACK_PAWN, $52, WHITE_KNIGHT, $72, WHITE_BISHOP
  .byte $76, WHITE_KING, $64, EMPTY_PIECE
; check_white_ne4_against_open_queen_file
  .byte $08, $52, $44
  .byte $43, BLACK_PAWN, $52, WHITE_KNIGHT, $73, WHITE_QUEEN
  .byte $03, BLACK_QUEEN, $13, EMPTY_PIECE, $23, EMPTY_PIECE
  .byte $33, EMPTY_PIECE, $44, EMPTY_PIECE
; check_white_cxd4_after_alapin_cxd4
  .byte $08, $52, $43
  .byte $43, BLACK_PAWN, $52, WHITE_PAWN, $73, WHITE_QUEEN
  .byte $32, EMPTY_PIECE, $62, EMPTY_PIECE, $63, EMPTY_PIECE
  .byte $44, WHITE_PAWN, $22, BLACK_KNIGHT
; check_white_knight_recaptures_d4
  .byte $04, $55, $43
  .byte $43, BLACK_PAWN, $55, WHITE_KNIGHT, $22, BLACK_KNIGHT
  .byte $73, WHITE_QUEEN
; check_white_queen_recaptures_d4
  .byte $07, $73, $43
  .byte $43, BLACK_PAWN, $73, WHITE_QUEEN, $32, EMPTY_PIECE
  .byte $63, EMPTY_PIECE, $53, EMPTY_PIECE, $42, EMPTY_PIECE
  .byte $33, EMPTY_PIECE
  .byte $00

__ai_search_no_white_survival_move_0:
  clc
  rts

__ai_search_black_to_move_2:
__ai_search_check_black_nb8_after_caro_queen_a6_0:
  lda #<BlackOpeningSurvivalTable
  sta temp1
  lda #>BlackOpeningSurvivalTable
  sta temp1 + 1
  jsr TryOpeningSurvivalTable
  bcs __ai_search_matched_2
  jmp __ai_search_check_scandi_knight_recapture_0
__ai_search_matched_2:
  rts

; Table scanner for linear survival-book segments. Each rule stores
; count/from/to followed by square/piece condition pairs. Call with temp1
; pointing at the table.
TryOpeningSurvivalTable:
__ai_search_rule_loop_0:
  ldy #$00
  lda (temp1), y
  beq __ai_search_table_miss_0
  sta $f0
  asl
  clc
  adc #$03
  sta $f1
  iny
  lda (temp1), y
  sta $f2
  iny
  lda (temp1), y
  sta $f3
  iny
__ai_search_cond_loop_0:
  lda (temp1), y
  tax
  iny
  lda (temp1), y
  cmp Board88, x
  bne __ai_search_next_rule_0
  iny
  dec $f0
  bne __ai_search_cond_loop_0
  lda $f2
  ldx $f3
  jmp SetOpeningSurvivalMove
__ai_search_next_rule_0:
  lda temp1
  clc
  adc $f1
  sta temp1
  bcc __ai_search_rule_loop_0
  inc temp1 + 1
  jmp __ai_search_rule_loop_0
__ai_search_table_miss_0:
  clc
  rts

BlackOpeningSurvivalTable:
; check_black_e6_after_qp_c3
  .byte $07, $14, $24
  .byte $14, BLACK_PAWN, $24, EMPTY_PIECE, $33, BLACK_PAWN
  .byte $43, WHITE_PAWN, $52, WHITE_PAWN, $04, BLACK_KING
  .byte $74, WHITE_KING
; check_black_e6_after_qp_c3_bf4
  .byte $09, $14, $24
  .byte $14, BLACK_PAWN, $24, EMPTY_PIECE, $33, BLACK_PAWN
  .byte $43, WHITE_PAWN, $52, WHITE_PAWN, $45, WHITE_BISHOP
  .byte $54, WHITE_PAWN, $25, BLACK_KNIGHT, $22, BLACK_KNIGHT
; check_black_dxe4_after_qp_g3_e4
  .byte $09, $33, $44
  .byte $33, BLACK_PAWN, $44, WHITE_PAWN, $43, WHITE_PAWN
  .byte $52, WHITE_PAWN, $23, BLACK_BISHOP, $22, BLACK_KNIGHT
  .byte $25, BLACK_KNIGHT, $66, WHITE_BISHOP, $04, BLACK_KING
; check_black_nxe4_after_qp_dxe4_recapture
  .byte $09, $25, $44
  .byte $25, BLACK_KNIGHT, $44, WHITE_KNIGHT, $33, EMPTY_PIECE
  .byte $43, WHITE_PAWN, $52, WHITE_PAWN, $23, BLACK_BISHOP
  .byte $22, BLACK_KNIGHT, $66, WHITE_BISHOP, $04, BLACK_KING
; check_black_e5_after_qp_bxe4
  .byte $09, $24, $34
  .byte $24, BLACK_PAWN, $34, EMPTY_PIECE, $44, WHITE_BISHOP
  .byte $43, WHITE_PAWN, $52, WHITE_PAWN, $23, BLACK_BISHOP
  .byte $22, BLACK_KNIGHT, $56, WHITE_PAWN, $04, BLACK_KING
; check_black_f6_blocks_bg5_queen_skewer
  .byte $09, $15, $25
  .byte $15, BLACK_PAWN, $25, EMPTY_PIECE, $36, WHITE_BISHOP
  .byte $44, WHITE_BISHOP, $43, BLACK_PAWN, $03, BLACK_QUEEN
  .byte $04, BLACK_KING, $23, BLACK_BISHOP, $22, BLACK_KNIGHT
; check_black_castles_after_bg5_qe2_f6
  .byte $0d, $04, $06
  .byte $04, BLACK_KING, $07, BLACK_ROOK, $05, EMPTY_PIECE
  .byte $06, EMPTY_PIECE, $25, BLACK_PAWN, $15, EMPTY_PIECE
  .byte $36, WHITE_BISHOP, $44, WHITE_BISHOP, $43, BLACK_PAWN
  .byte $64, WHITE_QUEEN, $03, BLACK_QUEEN, $23, BLACK_BISHOP
  .byte $22, BLACK_KNIGHT
; check_black_re8_after_bg5_bd2_castles
  .byte $0b, $05, $04
  .byte $06, BLACK_KING, $05, BLACK_ROOK, $04, EMPTY_PIECE
  .byte $25, BLACK_PAWN, $63, WHITE_BISHOP, $44, WHITE_BISHOP
  .byte $43, BLACK_PAWN, $64, WHITE_QUEEN, $03, BLACK_QUEEN
  .byte $23, BLACK_BISHOP, $22, BLACK_KNIGHT
; check_black_castles_after_open_game_qe2
  .byte $0d, $04, $06
  .byte $04, BLACK_KING, $07, BLACK_ROOK, $05, EMPTY_PIECE
  .byte $06, EMPTY_PIECE, $32, BLACK_BISHOP, $22, BLACK_KNIGHT
  .byte $25, BLACK_KNIGHT, $44, BLACK_PAWN, $33, WHITE_PAWN
  .byte $42, WHITE_BISHOP, $52, WHITE_KNIGHT, $55, WHITE_KNIGHT
  .byte $64, WHITE_QUEEN
; check_black_bd6_after_qp_bf4_nd2
  .byte $0a, $05, $23
  .byte $05, BLACK_BISHOP, $23, EMPTY_PIECE, $45, WHITE_BISHOP
  .byte $54, WHITE_PAWN, $63, WHITE_KNIGHT, $52, WHITE_PAWN
  .byte $43, WHITE_PAWN, $24, BLACK_PAWN, $22, BLACK_KNIGHT
  .byte $25, BLACK_KNIGHT
; check_black_bd6_after_qp_bf4_qe2
  .byte $0a, $14, $23
  .byte $14, BLACK_BISHOP, $23, EMPTY_PIECE, $13, BLACK_BISHOP
  .byte $24, BLACK_PAWN, $45, WHITE_BISHOP, $53, WHITE_BISHOP
  .byte $64, WHITE_QUEEN, $52, WHITE_PAWN, $43, WHITE_PAWN
  .byte $06, BLACK_KING
; check_black_bxf4_after_qp_bf4_bd3
  .byte $0a, $23, $45
  .byte $23, BLACK_BISHOP, $45, WHITE_BISHOP, $53, WHITE_BISHOP
  .byte $06, BLACK_KING, $05, BLACK_ROOK, $55, WHITE_KNIGHT
  .byte $63, WHITE_KNIGHT, $24, BLACK_PAWN, $33, BLACK_PAWN
  .byte $43, WHITE_PAWN
; check_black_rxd8_after_qp_nxd8
  .byte $0a, $02, $03
  .byte $02, BLACK_ROOK, $03, WHITE_KNIGHT, $04, BLACK_ROOK
  .byte $06, BLACK_KING, $13, BLACK_BISHOP, $25, BLACK_KNIGHT
  .byte $64, WHITE_QUEEN, $72, WHITE_KING, $55, WHITE_KNIGHT
  .byte $73, WHITE_ROOK
; check_black_bxe8_after_qp_bxe8
  .byte $0a, $13, $04
  .byte $13, BLACK_BISHOP, $04, WHITE_BISHOP, $06, BLACK_KING
  .byte $14, BLACK_KNIGHT, $25, BLACK_KNIGHT, $64, WHITE_QUEEN
  .byte $72, WHITE_KING, $76, WHITE_ROOK, $24, BLACK_PAWN
  .byte $33, BLACK_PAWN
; check_black_ng8_against_rh8_mate
  .byte $0a, $14, $06
  .byte $14, BLACK_KNIGHT, $06, EMPTY_PIECE, $05, BLACK_KING
  .byte $24, WHITE_QUEEN, $77, WHITE_ROOK, $13, BLACK_KNIGHT
  .byte $25, EMPTY_PIECE, $22, BLACK_PAWN, $33, BLACK_PAWN
  .byte $72, WHITE_KING
; check_black_g6_after_qp_rb8_castles
  .byte $0a, $16, $26
  .byte $16, BLACK_PAWN, $26, EMPTY_PIECE, $01, BLACK_ROOK
  .byte $03, BLACK_QUEEN, $04, BLACK_ROOK, $06, BLACK_KING
  .byte $34, WHITE_KNIGHT, $73, WHITE_ROOK, $72, WHITE_KING
  .byte $25, BLACK_KNIGHT
; check_black_ng4_against_h3_bishop
  .byte $0e, $25, $46
  .byte $25, BLACK_KNIGHT, $46, EMPTY_PIECE, $34, BLACK_KNIGHT
  .byte $23, BLACK_BISHOP, $24, BLACK_PAWN, $32, BLACK_PAWN
  .byte $57, WHITE_BISHOP, $64, WHITE_KNIGHT, $42, WHITE_PAWN
  .byte $30, WHITE_PAWN, $56, WHITE_PAWN, $06, BLACK_KING
  .byte $05, BLACK_ROOK, $03, BLACK_QUEEN
; check_black_be5_after_ng4_branch
  .byte $0d, $23, $34
  .byte $23, BLACK_BISHOP, $34, EMPTY_PIECE, $24, BLACK_PAWN
  .byte $45, WHITE_KNIGHT, $57, WHITE_BISHOP, $64, WHITE_KNIGHT
  .byte $30, WHITE_PAWN, $42, WHITE_PAWN, $06, BLACK_KING
  .byte $15, BLACK_ROOK, $03, BLACK_QUEEN, $22, BLACK_KNIGHT
  .byte $25, BLACK_KNIGHT
; check_black_rd8_late_queen_rook_defense
  .byte $0c, $01, $03
  .byte $01, BLACK_ROOK, $03, EMPTY_PIECE, $06, BLACK_KING
  .byte $25, BLACK_QUEEN, $34, BLACK_KNIGHT, $32, BLACK_BISHOP
  .byte $43, WHITE_KNIGHT, $66, WHITE_BISHOP, $61, WHITE_BISHOP
  .byte $73, WHITE_QUEEN, $77, WHITE_KING, $17, BLACK_PAWN
; check_black_nxe5_after_qp_g6_g5
  .byte $0a, $22, $34
  .byte $22, BLACK_KNIGHT, $34, WHITE_KNIGHT, $25, BLACK_KNIGHT
  .byte $26, BLACK_PAWN, $36, WHITE_PAWN, $01, BLACK_ROOK
  .byte $03, BLACK_QUEEN, $04, BLACK_ROOK, $06, BLACK_KING
  .byte $13, BLACK_BISHOP
; check_black_kg7_after_qp_qe3_mate_threat
  .byte $0d, $06, $16
  .byte $06, BLACK_KING, $16, EMPTY_PIECE, $04, BLACK_ROOK
  .byte $03, BLACK_QUEEN, $01, BLACK_ROOK, $54, WHITE_QUEEN
  .byte $34, WHITE_KNIGHT, $36, WHITE_PAWN, $44, BLACK_PAWN
  .byte $43, WHITE_PAWN, $45, WHITE_PAWN, $13, BLACK_BISHOP
  .byte $15, BLACK_PAWN
; check_black_qe7_after_qp_rh6_kg7
  .byte $0d, $03, $14
  .byte $03, BLACK_QUEEN, $14, EMPTY_PIECE, $16, BLACK_KING
  .byte $27, WHITE_ROOK, $04, BLACK_ROOK, $54, WHITE_QUEEN
  .byte $34, WHITE_KNIGHT, $36, WHITE_PAWN, $44, BLACK_PAWN
  .byte $13, BLACK_BISHOP, $15, BLACK_PAWN, $26, BLACK_PAWN
  .byte $73, WHITE_ROOK
; check_black_rh8_after_qp_qe7_a3
  .byte $0d, $04, $07
  .byte $04, BLACK_ROOK, $07, EMPTY_PIECE, $05, EMPTY_PIECE
  .byte $06, EMPTY_PIECE, $16, BLACK_KING, $14, BLACK_QUEEN
  .byte $27, WHITE_ROOK, $50, WHITE_PAWN, $54, WHITE_QUEEN
  .byte $34, WHITE_KNIGHT, $36, WHITE_PAWN, $44, BLACK_PAWN
  .byte $13, BLACK_BISHOP
; check_black_rg8_after_qp_qh3_rh8
  .byte $0d, $01, $06
  .byte $01, BLACK_ROOK, $06, EMPTY_PIECE, $07, BLACK_ROOK
  .byte $16, BLACK_KING, $14, BLACK_QUEEN, $27, WHITE_ROOK
  .byte $57, WHITE_QUEEN, $34, WHITE_KNIGHT, $36, WHITE_PAWN
  .byte $44, BLACK_PAWN, $13, BLACK_BISHOP, $15, BLACK_PAWN
  .byte $26, BLACK_PAWN
; check_black_qe8_after_qp_rh1
  .byte $0d, $14, $04
  .byte $14, BLACK_QUEEN, $04, EMPTY_PIECE, $06, BLACK_ROOK
  .byte $07, BLACK_ROOK, $16, BLACK_KING, $27, WHITE_ROOK
  .byte $57, WHITE_QUEEN, $77, WHITE_ROOK, $34, WHITE_KNIGHT
  .byte $36, WHITE_PAWN, $44, BLACK_PAWN, $13, BLACK_BISHOP
  .byte $15, BLACK_PAWN
; check_black_bc6_after_qp_b3
  .byte $0d, $13, $22
  .byte $13, BLACK_BISHOP, $22, EMPTY_PIECE, $04, BLACK_QUEEN
  .byte $06, BLACK_ROOK, $07, BLACK_ROOK, $16, BLACK_KING
  .byte $27, WHITE_ROOK, $57, WHITE_QUEEN, $77, WHITE_ROOK
  .byte $51, WHITE_PAWN, $34, WHITE_KNIGHT, $36, WHITE_PAWN
  .byte $44, BLACK_PAWN
; check_black_bd7_after_qp_ng5
  .byte $0a, $24, $13
  .byte $24, BLACK_BISHOP, $13, EMPTY_PIECE, $36, WHITE_KNIGHT
  .byte $25, BLACK_KNIGHT, $22, BLACK_KNIGHT, $33, BLACK_PAWN
  .byte $43, WHITE_PAWN, $52, WHITE_PAWN, $63, WHITE_KNIGHT
  .byte $04, BLACK_KING
; check_black_nb8_after_caro_queen_a6
  .byte $07, $13, $01
  .byte $20, WHITE_QUEEN, $02, BLACK_ROOK, $13, BLACK_KNIGHT
  .byte $24, BLACK_BISHOP, $16, BLACK_BISHOP, $42, BLACK_PAWN
  .byte $01, EMPTY_PIECE
; check_black_dxc4_after_caro_queen_b7_f8
  .byte $07, $33, $42
  .byte $11, WHITE_QUEEN, $33, BLACK_PAWN, $42, WHITE_PAWN
  .byte $34, WHITE_PAWN, $43, WHITE_PAWN, $24, BLACK_BISHOP
  .byte $05, BLACK_BISHOP
; check_black_qb6_after_caro_qa4_bd2
  .byte $08, $03, $21
  .byte $40, WHITE_QUEEN, $63, WHITE_BISHOP, $03, BLACK_QUEEN
  .byte $02, BLACK_ROOK, $13, BLACK_KNIGHT, $24, BLACK_BISHOP
  .byte $42, BLACK_PAWN, $21, EMPTY_PIECE
; check_black_rc7_after_caro_ba5
  .byte $07, $02, $12
  .byte $30, WHITE_BISHOP, $40, WHITE_QUEEN, $02, BLACK_ROOK
  .byte $13, BLACK_KNIGHT, $24, BLACK_BISHOP, $20, BLACK_PAWN
  .byte $12, EMPTY_PIECE
; check_black_nh6_after_caro_qb6_bc3
  .byte $08, $06, $27
  .byte $21, BLACK_QUEEN, $52, WHITE_BISHOP, $40, WHITE_QUEEN
  .byte $02, BLACK_ROOK, $24, BLACK_BISHOP, $16, BLACK_BISHOP
  .byte $06, BLACK_KNIGHT, $27, EMPTY_PIECE
; check_black_qb7_after_caro_qb6_na3_nf3
  .byte $0a, $21, $11
  .byte $21, BLACK_QUEEN, $52, WHITE_BISHOP, $40, WHITE_QUEEN
  .byte $50, WHITE_KNIGHT, $55, WHITE_KNIGHT, $27, BLACK_KNIGHT
  .byte $24, BLACK_BISHOP, $06, BLACK_KING, $42, BLACK_PAWN
  .byte $11, EMPTY_PIECE
; check_black_qe4_after_caro_qb7_bxc4
  .byte $0d, $11, $44
  .byte $11, BLACK_QUEEN, $42, WHITE_BISHOP, $52, WHITE_BISHOP
  .byte $40, WHITE_QUEEN, $50, WHITE_KNIGHT, $55, WHITE_KNIGHT
  .byte $27, BLACK_KNIGHT, $24, BLACK_BISHOP, $16, BLACK_BISHOP
  .byte $34, WHITE_PAWN, $22, EMPTY_PIECE, $33, EMPTY_PIECE
  .byte $44, EMPTY_PIECE
; check_black_nde5_after_caro_qe4
  .byte $08, $13, $34
  .byte $44, BLACK_QUEEN, $13, BLACK_KNIGHT, $34, WHITE_PAWN
  .byte $27, BLACK_KNIGHT, $24, BLACK_BISHOP, $16, BLACK_BISHOP
  .byte $40, WHITE_QUEEN, $64, WHITE_BISHOP
; check_black_bxe5_after_caro_nxe5
  .byte $06, $16, $34
  .byte $44, BLACK_QUEEN, $16, BLACK_BISHOP, $34, WHITE_KNIGHT
  .byte $27, BLACK_KNIGHT, $24, BLACK_BISHOP, $64, WHITE_BISHOP
; check_black_nd5_after_queenside_b5
  .byte $07, $25, $33
  .byte $25, BLACK_KNIGHT, $42, BLACK_PAWN, $31, WHITE_PAWN
  .byte $45, WHITE_BISHOP, $52, WHITE_KNIGHT, $55, WHITE_KNIGHT
  .byte $33, EMPTY_PIECE
; check_black_f6_after_queenside_be5
  .byte $06, $15, $25
  .byte $34, WHITE_BISHOP, $33, BLACK_KNIGHT, $31, WHITE_PAWN
  .byte $42, BLACK_PAWN, $15, BLACK_PAWN, $25, EMPTY_PIECE
; check_black_nxc3_after_bxh8
  .byte $06, $33, $52
  .byte $07, BLACK_ROOK, $33, BLACK_KNIGHT, $52, WHITE_KNIGHT
  .byte $34, WHITE_KNIGHT, $22, WHITE_PAWN, $42, BLACK_PAWN
; check_black_nxc3_after_bxh8_forced
  .byte $06, $33, $52
  .byte $07, WHITE_BISHOP, $33, BLACK_KNIGHT, $52, WHITE_KNIGHT
  .byte $34, WHITE_KNIGHT, $22, WHITE_PAWN, $42, BLACK_PAWN
; check_black_nxc3_after_bxh8_quiet
  .byte $06, $33, $52
  .byte $07, WHITE_BISHOP, $33, BLACK_KNIGHT, $52, WHITE_KNIGHT
  .byte $31, BLACK_PAWN, $42, BLACK_PAWN, $34, EMPTY_PIECE
; check_black_e6_after_poisoned_nxc3
  .byte $09, $14, $24
  .byte $52, BLACK_KNIGHT, $73, WHITE_QUEEN, $74, WHITE_KING
  .byte $34, WHITE_KNIGHT, $22, WHITE_PAWN, $42, WHITE_BISHOP
  .byte $43, WHITE_PAWN, $14, BLACK_PAWN, $24, EMPTY_PIECE
; check_black_qc7_after_poisoned_nxc3_e6
  .byte $08, $03, $12
  .byte $52, BLACK_KNIGHT, $55, WHITE_QUEEN, $34, WHITE_KNIGHT
  .byte $22, WHITE_PAWN, $24, BLACK_PAWN, $03, BLACK_QUEEN
  .byte $12, EMPTY_PIECE, $04, BLACK_KING
; check_black_bd6_after_poisoned_qc7
  .byte $0a, $05, $23
  .byte $12, BLACK_QUEEN, $05, BLACK_BISHOP, $23, EMPTY_PIECE
  .byte $34, WHITE_KNIGHT, $22, WHITE_PAWN, $42, WHITE_BISHOP
  .byte $52, WHITE_PAWN, $55, WHITE_QUEEN, $24, BLACK_PAWN
  .byte $04, BLACK_KING
; check_black_bxe5_after_poisoned_bd6
  .byte $08, $23, $34
  .byte $12, BLACK_QUEEN, $23, BLACK_BISHOP, $24, BLACK_BISHOP
  .byte $25, WHITE_QUEEN, $34, WHITE_KNIGHT, $22, WHITE_PAWN
  .byte $52, WHITE_PAWN, $04, BLACK_KING
; check_black_bb7_after_ne5_bxh8
  .byte $07, $02, $11
  .byte $07, WHITE_BISHOP, $34, WHITE_KNIGHT, $02, BLACK_BISHOP
  .byte $22, BLACK_KNIGHT, $33, BLACK_KNIGHT, $31, BLACK_PAWN
  .byte $11, EMPTY_PIECE
; check_black_ng6_after_philidor_f4
  .byte $08, $34, $26
  .byte $34, BLACK_KNIGHT, $25, BLACK_KNIGHT, $14, BLACK_QUEEN
  .byte $06, BLACK_KING, $44, WHITE_PAWN, $45, WHITE_PAWN
  .byte $64, WHITE_BISHOP, $26, EMPTY_PIECE
; check_black_h6_against_bishop_g5
  .byte $09, $17, $27
  .byte $25, BLACK_BISHOP, $34, BLACK_KNIGHT, $43, WHITE_KNIGHT
  .byte $56, WHITE_BISHOP, $52, WHITE_KNIGHT, $64, WHITE_BISHOP
  .byte $06, BLACK_KING, $17, BLACK_PAWN, $27, EMPTY_PIECE
; check_black_re8_in_re3_rook_line
  .byte $06, $05, $04
  .byte $05, BLACK_ROOK, $04, EMPTY_PIECE, $54, WHITE_ROOK
  .byte $53, WHITE_BISHOP, $33, WHITE_PAWN, $13, BLACK_BISHOP
; check_black_rc8_after_caro_queen_raid
  .byte $05, $00, $02
  .byte $22, WHITE_QUEEN, $42, BLACK_PAWN, $24, BLACK_BISHOP
  .byte $00, BLACK_ROOK, $02, EMPTY_PIECE
; check_black_bf5_after_caro_f6_nf4
  .byte $05, $24, $35
  .byte $22, WHITE_QUEEN, $45, WHITE_KNIGHT, $24, BLACK_BISHOP
  .byte $25, BLACK_PAWN, $35, EMPTY_PIECE
; check_black_dxc4_after_caro_queen_raid
  .byte $07, $33, $42
  .byte $11, WHITE_QUEEN, $33, BLACK_PAWN, $42, WHITE_PAWN
  .byte $34, WHITE_PAWN, $43, WHITE_PAWN, $24, BLACK_BISHOP
  .byte $16, BLACK_BISHOP
; check_black_nf6_after_queen_raid_e6
  .byte $08, $06, $25
  .byte $22, WHITE_QUEEN, $24, WHITE_PAWN, $33, WHITE_PAWN
  .byte $35, BLACK_BISHOP, $16, BLACK_BISHOP, $13, BLACK_KNIGHT
  .byte $06, BLACK_KNIGHT, $25, EMPTY_PIECE
; check_black_h6_after_compact_philidor
  .byte $0a, $17, $27
  .byte $35, WHITE_KNIGHT, $13, BLACK_KNIGHT, $25, BLACK_KNIGHT
  .byte $14, BLACK_BISHOP, $53, WHITE_BISHOP, $52, WHITE_KNIGHT
  .byte $06, BLACK_KING, $76, WHITE_KING, $17, BLACK_PAWN
  .byte $27, EMPTY_PIECE
; check_black_nxd5_after_philidor_h6_nd5
  .byte $09, $25, $33
  .byte $35, WHITE_KNIGHT, $33, WHITE_KNIGHT, $25, BLACK_KNIGHT
  .byte $13, BLACK_KNIGHT, $14, BLACK_BISHOP, $53, WHITE_BISHOP
  .byte $06, BLACK_KING, $76, WHITE_KING, $27, BLACK_PAWN
; check_black_h6_after_ne5_philidor
  .byte $0a, $17, $27
  .byte $34, BLACK_KNIGHT, $25, BLACK_KNIGHT, $14, BLACK_QUEEN
  .byte $02, BLACK_BISHOP, $06, BLACK_KING, $64, WHITE_BISHOP
  .byte $52, WHITE_KNIGHT, $76, WHITE_KING, $17, BLACK_PAWN
  .byte $27, EMPTY_PIECE
; check_black_c6_in_castled_bishop_pin
  .byte $09, $12, $22
  .byte $14, BLACK_QUEEN, $34, BLACK_KNIGHT, $25, BLACK_KNIGHT
  .byte $36, WHITE_BISHOP, $52, WHITE_KNIGHT, $64, WHITE_BISHOP
  .byte $76, WHITE_KING, $12, BLACK_PAWN, $22, EMPTY_PIECE
; check_black_ne5_before_philidor_castles
  .byte $09, $22, $34
  .byte $22, BLACK_KNIGHT, $12, BLACK_KNIGHT, $14, BLACK_BISHOP
  .byte $23, BLACK_PAWN, $43, WHITE_KNIGHT, $52, WHITE_KNIGHT
  .byte $55, WHITE_BISHOP, $04, BLACK_KING, $34, EMPTY_PIECE
; check_queens_pawn_nd5_against_nb5
  .byte $07, $25, $33
  .byte $25, BLACK_KNIGHT, $31, WHITE_KNIGHT, $24, BLACK_BISHOP
  .byte $42, BLACK_PAWN, $43, WHITE_PAWN, $26, BLACK_PAWN
  .byte $33, EMPTY_PIECE
; check_queens_pawn_bg7_after_b5_push
  .byte $06, $05, $16
  .byte $31, WHITE_PAWN, $42, BLACK_PAWN, $24, BLACK_BISHOP
  .byte $26, BLACK_PAWN, $05, BLACK_BISHOP, $16, EMPTY_PIECE
; check_queens_pawn_a6_after_b5_a4_c6
  .byte $07, $10, $20
  .byte $31, BLACK_PAWN, $40, WHITE_PAWN, $22, BLACK_PAWN
  .byte $42, BLACK_PAWN, $45, WHITE_BISHOP, $10, BLACK_PAWN
  .byte $20, EMPTY_PIECE
; check_sicilian_bishop_check_bd7
  .byte $06, $02, $13
  .byte $31, WHITE_BISHOP, $33, WHITE_PAWN, $25, BLACK_KNIGHT
  .byte $32, BLACK_PAWN, $02, BLACK_BISHOP, $13, EMPTY_PIECE
; check_sicilian_castled_bishop_g7
  .byte $07, $05, $16
  .byte $22, BLACK_KNIGHT, $31, WHITE_BISHOP, $32, BLACK_PAWN
  .byte $26, BLACK_PAWN, $05, BLACK_BISHOP, $16, EMPTY_PIECE
  .byte $76, WHITE_KING
; check_queens_pawn_c6_after_b5_a4
  .byte $08, $12, $22
  .byte $31, BLACK_PAWN, $40, WHITE_PAWN, $42, BLACK_PAWN
  .byte $43, WHITE_PAWN, $54, WHITE_PAWN, $55, WHITE_KNIGHT
  .byte $12, BLACK_PAWN, $22, EMPTY_PIECE
; check_queens_pawn_b5_after_dxc4
  .byte $07, $11, $31
  .byte $42, BLACK_PAWN, $43, WHITE_PAWN, $54, WHITE_PAWN
  .byte $55, WHITE_KNIGHT, $11, BLACK_PAWN, $21, EMPTY_PIECE
  .byte $31, EMPTY_PIECE
; check_queens_pawn_e6_after_bf5
  .byte $07, $14, $24
  .byte $35, BLACK_BISHOP, $42, WHITE_BISHOP, $43, WHITE_PAWN
  .byte $54, WHITE_PAWN, $55, WHITE_KNIGHT, $14, BLACK_PAWN
  .byte $24, EMPTY_PIECE
; check_caro_advance_qb6
  .byte $09, $03, $21
  .byte $22, BLACK_PAWN, $33, BLACK_PAWN, $34, WHITE_PAWN
  .byte $43, WHITE_PAWN, $53, WHITE_BISHOP, $26, BLACK_PAWN
  .byte $03, BLACK_QUEEN, $12, EMPTY_PIECE, $21, EMPTY_PIECE
; check_caro_advance_bg4
  .byte $0b, $02, $46
  .byte $22, BLACK_PAWN, $33, BLACK_PAWN, $34, WHITE_PAWN
  .byte $43, WHITE_PAWN, $55, WHITE_KNIGHT, $26, BLACK_PAWN
  .byte $02, BLACK_BISHOP, $13, EMPTY_PIECE, $24, EMPTY_PIECE
  .byte $35, EMPTY_PIECE, $46, EMPTY_PIECE
; check_caro_advance_bishop_e6
  .byte $08, $02, $24
  .byte $22, BLACK_PAWN, $33, BLACK_PAWN, $34, WHITE_PAWN
  .byte $42, WHITE_PAWN, $43, WHITE_PAWN, $26, BLACK_PAWN
  .byte $02, BLACK_BISHOP, $24, EMPTY_PIECE
; check_caro_advance_rb8_after_qxb7
  .byte $08, $00, $01
  .byte $00, BLACK_ROOK, $11, WHITE_QUEEN, $24, BLACK_BISHOP
  .byte $32, BLACK_PAWN, $34, WHITE_PAWN, $43, WHITE_PAWN
  .byte $33, WHITE_PAWN, $01, EMPTY_PIECE
; check_caro_advance_g6
  .byte $06, $16, $26
  .byte $22, BLACK_PAWN, $33, BLACK_PAWN, $34, WHITE_PAWN
  .byte $43, WHITE_PAWN, $16, BLACK_PAWN, $26, EMPTY_PIECE
; check_queens_pawn_c6_after_nf3
  .byte $05, $12, $22
  .byte $33, BLACK_PAWN, $43, WHITE_PAWN, $55, WHITE_KNIGHT
  .byte $12, BLACK_PAWN, $22, EMPTY_PIECE
; check_queens_pawn_g6_after_c6_c4
  .byte $07, $16, $26
  .byte $22, BLACK_PAWN, $33, BLACK_PAWN, $42, WHITE_PAWN
  .byte $43, WHITE_PAWN, $55, WHITE_KNIGHT, $16, BLACK_PAWN
  .byte $26, EMPTY_PIECE
; check_queens_pawn_dxc4
  .byte $04, $33, $42
  .byte $33, BLACK_PAWN, $42, WHITE_PAWN, $43, WHITE_PAWN
  .byte $34, EMPTY_PIECE
; check_center_queen_line_f6
  .byte $07, $15, $25
  .byte $14, BLACK_QUEEN, $34, WHITE_KNIGHT, $33, BLACK_PAWN
  .byte $43, WHITE_PAWN, $44, WHITE_PAWN, $15, BLACK_PAWN
  .byte $25, EMPTY_PIECE
; check_center_queen_line_qxe4_after_nd3
  .byte $08, $14, $44
  .byte $14, BLACK_QUEEN, $53, WHITE_KNIGHT, $33, BLACK_PAWN
  .byte $43, WHITE_PAWN, $44, WHITE_PAWN, $25, BLACK_PAWN
  .byte $24, EMPTY_PIECE, $34, EMPTY_PIECE
; check_center_queen_line_qxd5_after_d3_qe2
  .byte $06, $03, $33
  .byte $03, BLACK_QUEEN, $33, WHITE_PAWN, $44, BLACK_PAWN
  .byte $53, WHITE_PAWN, $55, WHITE_KNIGHT, $64, WHITE_QUEEN
; check_center_queen_line_qe7_after_qe2
  .byte $07, $03, $14
  .byte $03, BLACK_QUEEN, $33, WHITE_PAWN, $44, BLACK_PAWN
  .byte $64, WHITE_QUEEN, $52, WHITE_KNIGHT, $55, WHITE_KNIGHT
  .byte $14, EMPTY_PIECE
; check_black_qe7_after_early_center_qe2_check
  .byte $0b, $03, $14
  .byte $03, BLACK_QUEEN, $14, EMPTY_PIECE, $64, WHITE_QUEEN
  .byte $04, BLACK_KING, $41, BLACK_KNIGHT, $33, WHITE_PAWN
  .byte $25, BLACK_KNIGHT, $52, WHITE_KNIGHT, $13, EMPTY_PIECE
  .byte $05, BLACK_BISHOP, $74, WHITE_KING
; check_black_nxd5_after_early_center_be3
  .byte $0b, $41, $33
  .byte $41, BLACK_KNIGHT, $33, WHITE_PAWN, $14, BLACK_QUEEN
  .byte $64, WHITE_QUEEN, $54, WHITE_BISHOP, $25, BLACK_KNIGHT
  .byte $52, WHITE_KNIGHT, $04, BLACK_KING, $13, EMPTY_PIECE
  .byte $02, BLACK_BISHOP, $05, BLACK_BISHOP
; check_black_nxe3_after_early_center_castles
  .byte $0b, $33, $54
  .byte $33, BLACK_KNIGHT, $54, WHITE_BISHOP, $72, WHITE_KING
  .byte $73, WHITE_ROOK, $64, WHITE_QUEEN, $14, BLACK_QUEEN
  .byte $04, BLACK_KING, $02, BLACK_BISHOP, $05, BLACK_BISHOP
  .byte $13, EMPTY_PIECE, $52, EMPTY_PIECE
; check_black_exd4_after_early_d4
  .byte $07, $34, $43
  .byte $34, BLACK_PAWN, $43, WHITE_PAWN, $44, WHITE_PAWN
  .byte $13, BLACK_PAWN, $04, BLACK_KING, $74, WHITE_KING
  .byte $55, EMPTY_PIECE
; check_black_nc6_after_e4_e5_nf3
  .byte $08, $01, $22
  .byte $34, BLACK_PAWN, $44, WHITE_PAWN, $55, WHITE_KNIGHT
  .byte $01, BLACK_KNIGHT, $22, EMPTY_PIECE, $13, BLACK_PAWN
  .byte $04, BLACK_KING, $74, WHITE_KING
; check_black_nf6_after_ruy_bb5
  .byte $0a, $06, $25
  .byte $06, BLACK_KNIGHT, $25, EMPTY_PIECE, $31, WHITE_BISHOP
  .byte $55, WHITE_KNIGHT, $22, BLACK_KNIGHT, $34, BLACK_PAWN
  .byte $44, WHITE_PAWN, $04, BLACK_KING, $74, WHITE_KING
  .byte $13, BLACK_PAWN
; check_black_nxe4_after_ruy_castles
  .byte $0b, $25, $44
  .byte $25, BLACK_KNIGHT, $44, WHITE_PAWN, $31, WHITE_BISHOP
  .byte $76, WHITE_KING, $75, WHITE_ROOK, $22, BLACK_KNIGHT
  .byte $34, BLACK_PAWN, $04, BLACK_KING, $03, BLACK_QUEEN
  .byte $13, BLACK_PAWN, $05, BLACK_BISHOP
; check_black_nd6_after_ruy_nxe4_d4
  .byte $0a, $44, $23
  .byte $44, BLACK_KNIGHT, $23, EMPTY_PIECE, $31, WHITE_BISHOP
  .byte $76, WHITE_KING, $75, WHITE_ROOK, $43, WHITE_PAWN
  .byte $34, BLACK_PAWN, $13, BLACK_PAWN, $22, BLACK_KNIGHT
  .byte $04, BLACK_KING
; check_black_nd6_after_ruy_nxe4_re1
  .byte $0b, $44, $23
  .byte $44, BLACK_KNIGHT, $23, EMPTY_PIECE, $74, WHITE_ROOK
  .byte $76, WHITE_KING, $31, WHITE_BISHOP, $22, BLACK_KNIGHT
  .byte $34, BLACK_PAWN, $13, BLACK_PAWN, $04, BLACK_KING
  .byte $03, BLACK_QUEEN, $05, BLACK_BISHOP
; check_black_bd7_after_ruy_nxe5
  .byte $0b, $02, $13
  .byte $02, BLACK_BISHOP, $13, EMPTY_PIECE, $34, WHITE_KNIGHT
  .byte $44, BLACK_KNIGHT, $31, WHITE_BISHOP, $43, WHITE_PAWN
  .byte $33, BLACK_PAWN, $22, BLACK_KNIGHT, $05, BLACK_BISHOP
  .byte $04, BLACK_KING, $76, WHITE_KING
; check_black_nb4_after_ruy_cxd5
  .byte $0a, $22, $41
  .byte $22, BLACK_KNIGHT, $41, EMPTY_PIECE, $33, WHITE_PAWN
  .byte $44, WHITE_ROOK, $31, WHITE_BISHOP, $14, BLACK_BISHOP
  .byte $06, BLACK_KING, $03, BLACK_QUEEN, $43, WHITE_PAWN
  .byte $04, EMPTY_PIECE
; check_black_f5_after_ruy_nfd2
  .byte $0a, $15, $35
  .byte $15, BLACK_PAWN, $35, EMPTY_PIECE, $23, BLACK_KNIGHT
  .byte $44, BLACK_PAWN, $74, WHITE_ROOK, $76, WHITE_KING
  .byte $14, BLACK_BISHOP, $31, WHITE_BISHOP, $63, WHITE_KNIGHT
  .byte $04, BLACK_KING
; check_black_b6_after_ruy_f5_ba4
  .byte $0c, $11, $21
  .byte $11, BLACK_PAWN, $21, EMPTY_PIECE, $44, BLACK_PAWN
  .byte $35, BLACK_PAWN, $40, WHITE_BISHOP, $74, WHITE_ROOK
  .byte $76, WHITE_KING, $23, BLACK_KNIGHT, $22, BLACK_KNIGHT
  .byte $14, BLACK_BISHOP, $06, BLACK_KING, $05, BLACK_ROOK
; check_black_nxe4_after_ruy_c5_ndxe4
  .byte $0a, $23, $44
  .byte $23, BLACK_KNIGHT, $44, WHITE_KNIGHT, $40, WHITE_BISHOP
  .byte $32, BLACK_PAWN, $35, BLACK_PAWN, $14, BLACK_BISHOP
  .byte $22, BLACK_KNIGHT, $06, BLACK_KING, $74, WHITE_ROOK
  .byte $76, WHITE_KING
; check_black_nd4_after_ruy_d5
  .byte $0a, $22, $43
  .byte $22, BLACK_KNIGHT, $43, EMPTY_PIECE, $33, WHITE_PAWN
  .byte $32, BLACK_PAWN, $44, BLACK_KNIGHT, $40, WHITE_BISHOP
  .byte $14, BLACK_BISHOP, $06, BLACK_KING, $74, WHITE_ROOK
  .byte $76, WHITE_KING
; check_black_bxd6_after_ruy_d6
  .byte $0a, $14, $23
  .byte $14, BLACK_BISHOP, $23, WHITE_PAWN, $34, BLACK_KNIGHT
  .byte $44, BLACK_KNIGHT, $32, BLACK_PAWN, $35, BLACK_PAWN
  .byte $40, WHITE_BISHOP, $52, WHITE_KNIGHT, $06, BLACK_KING
  .byte $76, WHITE_KING
; check_black_dxc6_after_ruy_bxc6
  .byte $0a, $13, $22
  .byte $13, BLACK_PAWN, $22, WHITE_BISHOP, $43, BLACK_PAWN
  .byte $23, BLACK_BISHOP, $02, BLACK_BISHOP, $03, BLACK_QUEEN
  .byte $06, BLACK_KING, $52, WHITE_KNIGHT, $35, BLACK_PAWN
  .byte $72, WHITE_BISHOP
; check_black_nxd5_after_ruy_nb4_nc3
  .byte $0a, $41, $33
  .byte $41, BLACK_KNIGHT, $33, WHITE_PAWN, $52, WHITE_KNIGHT
  .byte $44, WHITE_ROOK, $31, WHITE_BISHOP, $14, BLACK_BISHOP
  .byte $06, BLACK_KING, $03, BLACK_QUEEN, $43, WHITE_PAWN
  .byte $04, EMPTY_PIECE
; check_black_nf6_after_open_a3
  .byte $08, $06, $25
  .byte $34, BLACK_PAWN, $44, WHITE_PAWN, $55, WHITE_KNIGHT
  .byte $50, WHITE_PAWN, $22, BLACK_KNIGHT, $06, BLACK_KNIGHT
  .byte $25, EMPTY_PIECE, $04, BLACK_KING
; check_black_nf6_after_vienna_knights
  .byte $09, $06, $25
  .byte $34, BLACK_PAWN, $44, WHITE_PAWN, $52, WHITE_KNIGHT
  .byte $55, WHITE_KNIGHT, $22, BLACK_KNIGHT, $06, BLACK_KNIGHT
  .byte $25, EMPTY_PIECE, $04, BLACK_KING, $74, WHITE_KING
; check_black_nd4_after_four_knights_bb5
  .byte $0b, $22, $43
  .byte $22, BLACK_KNIGHT, $43, EMPTY_PIECE, $31, WHITE_BISHOP
  .byte $52, WHITE_KNIGHT, $55, WHITE_KNIGHT, $25, BLACK_KNIGHT
  .byte $34, BLACK_PAWN, $44, WHITE_PAWN, $13, BLACK_PAWN
  .byte $63, WHITE_PAWN, $04, BLACK_KING
; check_black_qe7_after_four_knights_nd4_nxe5
  .byte $0b, $03, $14
  .byte $03, BLACK_QUEEN, $14, EMPTY_PIECE, $34, WHITE_KNIGHT
  .byte $43, BLACK_KNIGHT, $31, WHITE_BISHOP, $52, WHITE_KNIGHT
  .byte $25, BLACK_KNIGHT, $44, WHITE_PAWN, $13, BLACK_PAWN
  .byte $05, BLACK_BISHOP, $04, BLACK_KING
; check_black_nxb5_after_four_knights_qe7_nf3
  .byte $0a, $43, $31
  .byte $43, BLACK_KNIGHT, $31, WHITE_BISHOP, $14, BLACK_QUEEN
  .byte $55, WHITE_KNIGHT, $52, WHITE_KNIGHT, $25, BLACK_KNIGHT
  .byte $44, WHITE_PAWN, $13, BLACK_PAWN, $05, BLACK_BISHOP
  .byte $04, BLACK_KING
; check_black_bb4_after_four_knights_d4
  .byte $0a, $05, $41
  .byte $05, BLACK_BISHOP, $41, EMPTY_PIECE, $43, WHITE_PAWN
  .byte $44, WHITE_PAWN, $52, WHITE_KNIGHT, $55, WHITE_KNIGHT
  .byte $22, BLACK_KNIGHT, $25, BLACK_KNIGHT, $34, BLACK_PAWN
  .byte $04, BLACK_KING
; check_black_h6_after_four_knights_bg5
  .byte $0c, $17, $27
  .byte $17, BLACK_PAWN, $27, EMPTY_PIECE, $36, WHITE_BISHOP
  .byte $41, BLACK_BISHOP, $43, WHITE_PAWN, $44, WHITE_PAWN
  .byte $52, WHITE_KNIGHT, $55, WHITE_KNIGHT, $22, BLACK_KNIGHT
  .byte $25, BLACK_KNIGHT, $34, BLACK_PAWN, $04, BLACK_KING
; check_black_qxf6_after_four_knights_bxf6
  .byte $0b, $03, $25
  .byte $03, BLACK_QUEEN, $25, WHITE_BISHOP, $41, BLACK_BISHOP
  .byte $27, BLACK_PAWN, $43, WHITE_PAWN, $44, WHITE_PAWN
  .byte $52, WHITE_KNIGHT, $55, WHITE_KNIGHT, $22, BLACK_KNIGHT
  .byte $34, BLACK_PAWN, $04, BLACK_KING
; check_black_bb4_after_four_knights_d5_bb5
  .byte $0b, $05, $41
  .byte $05, BLACK_BISHOP, $41, EMPTY_PIECE, $31, WHITE_BISHOP
  .byte $33, BLACK_PAWN, $34, BLACK_PAWN, $43, WHITE_PAWN
  .byte $44, WHITE_PAWN, $52, WHITE_KNIGHT, $55, WHITE_KNIGHT
  .byte $22, BLACK_KNIGHT, $25, BLACK_KNIGHT
; check_black_bd7_after_four_knights_nxd4
  .byte $09, $02, $13
  .byte $02, BLACK_BISHOP, $13, EMPTY_PIECE, $31, WHITE_BISHOP
  .byte $33, BLACK_PAWN, $43, WHITE_KNIGHT, $44, WHITE_PAWN
  .byte $52, WHITE_KNIGHT, $22, BLACK_KNIGHT, $25, BLACK_KNIGHT
; check_black_castles_after_four_knights_nxe5
  .byte $0d, $04, $06
  .byte $04, BLACK_KING, $07, BLACK_ROOK, $05, EMPTY_PIECE
  .byte $06, EMPTY_PIECE, $34, WHITE_KNIGHT, $33, BLACK_PAWN
  .byte $41, BLACK_BISHOP, $31, WHITE_BISHOP, $22, BLACK_KNIGHT
  .byte $25, BLACK_KNIGHT, $43, WHITE_PAWN, $44, WHITE_PAWN
  .byte $52, WHITE_KNIGHT
; check_black_nf6_after_italian_bc4
  .byte $09, $06, $25
  .byte $34, BLACK_PAWN, $44, WHITE_PAWN, $55, WHITE_KNIGHT
  .byte $42, WHITE_BISHOP, $22, BLACK_KNIGHT, $06, BLACK_KNIGHT
  .byte $25, EMPTY_PIECE, $04, BLACK_KING, $13, BLACK_PAWN
; check_black_bc5_after_italian_nc3
  .byte $0b, $05, $32
  .byte $05, BLACK_BISHOP, $32, EMPTY_PIECE, $42, WHITE_BISHOP
  .byte $52, WHITE_KNIGHT, $55, WHITE_KNIGHT, $22, BLACK_KNIGHT
  .byte $25, BLACK_KNIGHT, $34, BLACK_PAWN, $44, WHITE_PAWN
  .byte $04, BLACK_KING, $13, BLACK_PAWN
; check_black_na5_after_two_knights_exd5
  .byte $0a, $22, $30
  .byte $22, BLACK_KNIGHT, $30, EMPTY_PIECE, $33, WHITE_PAWN
  .byte $36, WHITE_KNIGHT, $42, WHITE_BISHOP, $25, BLACK_KNIGHT
  .byte $34, BLACK_PAWN, $44, EMPTY_PIECE, $13, EMPTY_PIECE
  .byte $04, BLACK_KING
; check_black_nxd5_after_exd5
  .byte $07, $25, $33
  .byte $25, BLACK_KNIGHT, $33, WHITE_PAWN, $34, BLACK_PAWN
  .byte $22, BLACK_KNIGHT, $50, WHITE_PAWN, $53, WHITE_PAWN
  .byte $44, EMPTY_PIECE
; check_black_nf6_after_italian_qh5_attack
  .byte $0f, $33, $25
  .byte $33, BLACK_KNIGHT, $25, EMPTY_PIECE, $37, WHITE_QUEEN
  .byte $17, WHITE_BISHOP, $07, BLACK_KING, $05, BLACK_ROOK
  .byte $23, BLACK_BISHOP, $30, BLACK_KNIGHT, $36, WHITE_KNIGHT
  .byte $43, BLACK_PAWN, $52, WHITE_PAWN, $75, WHITE_ROOK
  .byte $76, WHITE_KING, $16, BLACK_PAWN, $15, BLACK_PAWN
; check_philidor_exd4_after_d4
  .byte $05, $34, $43
  .byte $34, BLACK_PAWN, $43, WHITE_PAWN, $44, WHITE_PAWN
  .byte $55, WHITE_KNIGHT, $23, BLACK_PAWN
; check_philidor_be7_after_nc3
  .byte $07, $05, $14
  .byte $23, BLACK_PAWN, $25, BLACK_KNIGHT, $43, WHITE_KNIGHT
  .byte $52, WHITE_KNIGHT, $44, WHITE_PAWN, $05, BLACK_BISHOP
  .byte $14, EMPTY_PIECE
; check_philidor_castles_after_nf5
  .byte $09, $04, $06
  .byte $35, WHITE_KNIGHT, $14, BLACK_BISHOP, $13, BLACK_KNIGHT
  .byte $23, BLACK_PAWN, $25, BLACK_KNIGHT, $04, BLACK_KING
  .byte $07, BLACK_ROOK, $05, EMPTY_PIECE, $06, EMPTY_PIECE
; check_philidor_ng4_after_bh6
  .byte $07, $34, $46
  .byte $34, BLACK_KNIGHT, $27, WHITE_BISHOP, $25, BLACK_KNIGHT
  .byte $23, BLACK_PAWN, $24, EMPTY_PIECE, $35, EMPTY_PIECE
  .byte $46, EMPTY_PIECE
; check_black_initial_e5
  .byte $07, $14, $34
  .byte $44, WHITE_PAWN, $12, BLACK_PAWN, $13, BLACK_PAWN
  .byte $14, BLACK_PAWN, $01, BLACK_KNIGHT, $06, BLACK_KNIGHT
  .byte $55, EMPTY_PIECE
; check_black_caro_d5_after_d3
  .byte $08, $13, $33
  .byte $44, WHITE_PAWN, $53, WHITE_PAWN, $22, BLACK_PAWN
  .byte $13, BLACK_PAWN, $33, EMPTY_PIECE, $14, BLACK_PAWN
  .byte $04, BLACK_KING, $03, BLACK_QUEEN
; check_scandi_queen_recapture
  .byte $05, $03, $33
  .byte $33, WHITE_PAWN, $03, BLACK_QUEEN, $14, BLACK_PAWN
  .byte $43, EMPTY_PIECE, $64, EMPTY_PIECE
  .byte $00

__ai_search_check_scandi_knight_recapture_0:
; If ...Nf6 was already played and white supports d5 with d4, take d5.
  lda Board88 + $25
  cmp #BLACK_KNIGHT
  bne __ai_search_check_center_queen_check_0
  lda Board88 + $33
  cmp #WHITE_PAWN
  bne __ai_search_check_center_queen_check_0
  lda Board88 + $43
  cmp #WHITE_PAWN
  bne __ai_search_check_center_queen_check_0
  lda Board88 + $64
  cmp #EMPTY_PIECE
  bne __ai_search_check_queens_pawn_queen_recapture_0
  lda Board88 + $62
  cmp #WHITE_PAWN
  bne __ai_search_check_center_queen_check_0
  lda #$25
  ldx #$33
  jmp SetOpeningSurvivalMove

__ai_search_check_center_queen_check_0:
; 1. e4 e5 2. Nf3 d5 3. Nxe5: hit the knight with ...Qe7.
  lda Board88 + $03
  cmp #BLACK_QUEEN
  bne __ai_search_check_center_pawn_push_0
  lda Board88 + $34
  cmp #WHITE_KNIGHT
  bne __ai_search_check_center_pawn_push_0
  lda Board88 + $33
  cmp #BLACK_PAWN
  bne __ai_search_check_center_pawn_push_0
  lda Board88 + $44
  cmp #WHITE_PAWN
  bne __ai_search_check_center_pawn_push_0
  lda Board88 + $14
  cmp #EMPTY_PIECE
  bne __ai_search_check_center_pawn_push_0
  lda #$03
  ldx #$14
  jmp SetOpeningSurvivalMove

__ai_search_check_center_pawn_push_0:
; 1. e4 e5 2. Nf3 d5 3. exd5: push e5-e4 instead of drifting.
  lda Board88 + $34
  cmp #BLACK_PAWN
  bne __ai_search_check_queens_pawn_queen_recapture_0
  lda Board88 + $33
  cmp #WHITE_PAWN
  bne __ai_search_check_queens_pawn_queen_recapture_0
  lda Board88 + $55
  cmp #WHITE_KNIGHT
  bne __ai_search_check_queens_pawn_queen_recapture_0
  lda Board88 + $14
  cmp #EMPTY_PIECE
  bne __ai_search_check_queens_pawn_queen_recapture_0
  lda Board88 + $64
  cmp #EMPTY_PIECE
  bne __ai_search_check_queens_pawn_queen_recapture_0
  lda #$34
  ldx #$44
  jmp SetOpeningSurvivalMove

__ai_search_check_queens_pawn_queen_recapture_0:
; Queen's-pawn/c-pawn capture on d5: use the queen recapture.
  lda Board88 + $25
  cmp #BLACK_KNIGHT
  bne __ai_search_check_queens_pawn_c6_0
  lda Board88 + $33
  cmp #WHITE_PAWN
  bne __ai_search_check_queens_pawn_c6_0
  lda Board88 + $43
  cmp #WHITE_PAWN
  bne __ai_search_check_queens_pawn_c6_0
  lda Board88 + $64
  cmp #WHITE_PAWN
  bne __ai_search_check_queens_pawn_c6_0
  lda Board88 + $62
  cmp #EMPTY_PIECE
  bne __ai_search_check_queens_pawn_c6_0
  lda Board88 + $03
  cmp #BLACK_QUEEN
  bne __ai_search_check_queens_pawn_c6_0
  lda #$03
  ldx #$33
  jmp SetOpeningSurvivalMove

__ai_search_check_queens_pawn_c6_0:
; After ...Nbd7 in the same structure, shore up d5 with ...c6.
  lda Board88 + $13
  cmp #BLACK_KNIGHT
  bne __ai_search_check_sicilian_develop_0
  lda Board88 + $25
  cmp #BLACK_KNIGHT
  bne __ai_search_check_sicilian_develop_0
  lda Board88 + $52
  cmp #WHITE_KNIGHT
  bne __ai_search_check_sicilian_develop_0
  lda Board88 + $33
  cmp #WHITE_PAWN
  bne __ai_search_check_sicilian_develop_0
  lda Board88 + $43
  cmp #WHITE_PAWN
  bne __ai_search_check_sicilian_develop_0
  lda Board88 + $12
  cmp #BLACK_PAWN
  bne __ai_search_check_sicilian_develop_0
  lda #$12
  ldx #$22
  jmp SetOpeningSurvivalMove

__ai_search_check_sicilian_develop_0:
; If the queen is already out on f6, stop drifting and develop b8-c6.
  lda Board88 + $25
  cmp #BLACK_QUEEN
  bne __ai_search_check_bishop_retreat_0
  lda Board88 + $01
  cmp #BLACK_KNIGHT
  bne __ai_search_check_bishop_retreat_0
  lda Board88 + $44
  cmp #WHITE_PAWN
  bne __ai_search_check_bishop_retreat_0
  lda Board88 + $34
  cmp #BLACK_PAWN
  bne __ai_search_check_bishop_retreat_0
  lda Board88 + $52
  cmp #WHITE_KNIGHT
  bne __ai_search_check_bishop_retreat_0
  lda Board88 + $55
  cmp #WHITE_KNIGHT
  bne __ai_search_check_bishop_retreat_0
  lda #$01
  ldx #$22
  jmp SetOpeningSurvivalMove

__ai_search_check_bishop_retreat_0:
; In the c3/d4/e4 center, the b4 bishop is a target; tuck it on e7.
  lda Board88 + $41
  cmp #BLACK_BISHOP
  bne __ai_search_check_sicilian_develop_main_0
  lda Board88 + $52
  cmp #WHITE_PAWN
  bne __ai_search_check_sicilian_develop_main_0
  lda Board88 + $43
  cmp #WHITE_PAWN
  bne __ai_search_check_sicilian_develop_main_0
  lda Board88 + $44
  cmp #WHITE_PAWN
  bne __ai_search_check_sicilian_develop_main_0
  lda Board88 + $34
  cmp #BLACK_PAWN
  bne __ai_search_check_sicilian_develop_main_0
  lda Board88 + $25
  cmp #BLACK_KNIGHT
  bne __ai_search_check_sicilian_develop_main_0
  lda Board88 + $14
  cmp #EMPTY_PIECE
  bne __ai_search_check_sicilian_develop_main_0
  lda #$41
  ldx #$14
  jmp SetOpeningSurvivalMove

__ai_search_check_sicilian_develop_main_0:
; Against Nc3/Nf3 after ...Nc6, stabilize with ...e6 instead of ...d5.
  lda Board88 + $22
  cmp #BLACK_KNIGHT
  bne __ai_search_check_sicilian_bishop_check_0
  lda Board88 + $52
  cmp #WHITE_KNIGHT
  bne __ai_search_check_sicilian_bishop_check_0
  lda Board88 + $55
  cmp #WHITE_KNIGHT
  bne __ai_search_check_sicilian_bishop_check_0
  lda Board88 + $32
  cmp #BLACK_PAWN
  bne __ai_search_check_sicilian_bishop_check_0
  lda Board88 + $44
  cmp #WHITE_PAWN
  bne __ai_search_check_sicilian_bishop_check_0
  lda Board88 + $14
  cmp #BLACK_PAWN
  bne __ai_search_check_sicilian_bishop_check_0
  lda #$14
  ldx #$24
  jmp SetOpeningSurvivalMove

__ai_search_check_sicilian_bishop_check_0:
; After ...Nc6 and Bb5, answer with ...g6 instead of weakening f7-f5.
  lda Board88 + $22
  cmp #BLACK_KNIGHT
  bne __ai_search_check_sicilian_f5_repair_0
  lda Board88 + $31
  cmp #WHITE_BISHOP
  bne __ai_search_check_sicilian_f5_repair_0
  lda Board88 + $32
  cmp #BLACK_PAWN
  bne __ai_search_check_sicilian_f5_repair_0
  lda Board88 + $44
  cmp #WHITE_PAWN
  bne __ai_search_check_sicilian_f5_repair_0
  lda Board88 + $55
  cmp #WHITE_KNIGHT
  bne __ai_search_check_sicilian_f5_repair_0
  lda Board88 + $16
  cmp #BLACK_PAWN
  bne __ai_search_check_sicilian_f5_repair_0
  lda #$16
  ldx #$26
  jmp SetOpeningSurvivalMove

__ai_search_check_sicilian_f5_repair_0:
; If the f-pawn mistake already happened and white is on f5, play ...d6.
  lda Board88 + $22
  cmp #BLACK_KNIGHT
  bne __ai_search_check_sicilian_nd5_retreat_c7_0
  lda Board88 + $31
  cmp #WHITE_BISHOP
  bne __ai_search_check_sicilian_nd5_retreat_c7_0
  lda Board88 + $32
  cmp #BLACK_PAWN
  bne __ai_search_check_sicilian_nd5_retreat_c7_0
  lda Board88 + $35
  cmp #WHITE_PAWN
  bne __ai_search_check_sicilian_nd5_retreat_c7_0
  lda Board88 + $13
  cmp #BLACK_PAWN
  bne __ai_search_check_sicilian_nd5_retreat_c7_0
  lda #$13
  ldx #$23
  jmp SetOpeningSurvivalMove

__ai_search_check_sicilian_nd5_retreat_c7_0:
; After ...Nf6-d5 and Nc3, preserve the advanced knight with Nd5-c7.
  lda Board88 + $33
  cmp #BLACK_KNIGHT
  bne __ai_search_check_sicilian_nc7_nf3_nc6_0
  lda Board88 + $52
  cmp #WHITE_KNIGHT
  bne __ai_search_check_sicilian_nc7_nf3_nc6_0
  lda Board88 + $34
  cmp #WHITE_PAWN
  bne __ai_search_check_sicilian_nc7_nf3_nc6_0
  lda Board88 + $32
  cmp #BLACK_PAWN
  bne __ai_search_check_sicilian_nc7_nf3_nc6_0
  lda Board88 + $12
  cmp #EMPTY_PIECE
  bne __ai_search_check_sicilian_nc7_nf3_nc6_0
  lda #$33
  ldx #$12
  jmp SetOpeningSurvivalMove

__ai_search_check_sicilian_nc7_nf3_nc6_0:
; In the Be2/e5 Sicilian, follow Nd5-c7 with Nb8-c6 instead of ...e6.
  lda Board88 + $12
  cmp #BLACK_KNIGHT
  bne __ai_search_check_sicilian_nc7_castled_d6_0
  lda Board88 + $01
  cmp #BLACK_KNIGHT
  bne __ai_search_check_sicilian_nc7_castled_d6_0
  lda Board88 + $52
  cmp #WHITE_KNIGHT
  bne __ai_search_check_sicilian_nc7_castled_d6_0
  lda Board88 + $55
  cmp #WHITE_KNIGHT
  bne __ai_search_check_sicilian_nc7_castled_d6_0
  lda Board88 + $64
  cmp #WHITE_BISHOP
  bne __ai_search_check_sicilian_nc7_castled_d6_0
  lda Board88 + $34
  cmp #WHITE_PAWN
  bne __ai_search_check_sicilian_nc7_castled_d6_0
  lda Board88 + $32
  cmp #BLACK_PAWN
  bne __ai_search_check_sicilian_nc7_castled_d6_0
  lda Board88 + $22
  cmp #EMPTY_PIECE
  bne __ai_search_check_sicilian_nc7_castled_d6_0
  lda #$01
  ldx #$22
  jmp SetOpeningSurvivalMove

__ai_search_check_sicilian_nc7_castled_d6_0:
; If White castles after ...Nc6, blunt e5 with ...d6 before rook drifts.
  lda Board88 + $12
  cmp #BLACK_KNIGHT
  bne __ai_search_check_sicilian_be7_before_nxd4_0
  lda Board88 + $22
  cmp #BLACK_KNIGHT
  bne __ai_search_check_sicilian_be7_before_nxd4_0
  lda Board88 + $52
  cmp #WHITE_KNIGHT
  bne __ai_search_check_sicilian_be7_before_nxd4_0
  lda Board88 + $55
  cmp #WHITE_KNIGHT
  bne __ai_search_check_sicilian_be7_before_nxd4_0
  lda Board88 + $64
  cmp #WHITE_BISHOP
  bne __ai_search_check_sicilian_be7_before_nxd4_0
  lda Board88 + $34
  cmp #WHITE_PAWN
  bne __ai_search_check_sicilian_be7_before_nxd4_0
  lda Board88 + $32
  cmp #BLACK_PAWN
  bne __ai_search_check_sicilian_be7_before_nxd4_0
  lda Board88 + $76
  cmp #WHITE_KING
  bne __ai_search_check_sicilian_be7_before_nxd4_0
  lda Board88 + $13
  cmp #BLACK_PAWN
  bne __ai_search_check_sicilian_be7_before_nxd4_0
  lda Board88 + $23
  cmp #EMPTY_PIECE
  bne __ai_search_check_sicilian_be7_before_nxd4_0
  lda #$13
  ldx #$23
  jmp SetOpeningSurvivalMove

__ai_search_check_sicilian_be7_before_nxd4_0:
; In the Be2 Sicilian, finish Bf8-e7 before trading on d4 into Qxd4.
  lda Board88 + $12
  cmp #BLACK_KNIGHT
  bne __ai_search_check_sicilian_be2_nf6_0
  lda Board88 + $22
  cmp #BLACK_KNIGHT
  bne __ai_search_check_sicilian_be2_nf6_0
  lda Board88 + $43
  cmp #WHITE_KNIGHT
  bne __ai_search_check_sicilian_be2_nf6_0
  lda Board88 + $52
  cmp #WHITE_KNIGHT
  bne __ai_search_check_sicilian_be2_nf6_0
  lda Board88 + $64
  cmp #WHITE_BISHOP
  bne __ai_search_check_sicilian_be2_nf6_0
  lda Board88 + $23
  cmp #BLACK_PAWN
  bne __ai_search_check_sicilian_be2_nf6_0
  lda Board88 + $05
  cmp #BLACK_BISHOP
  bne __ai_search_check_sicilian_be2_nf6_0
  lda Board88 + $14
  cmp #EMPTY_PIECE
  bne __ai_search_check_sicilian_be2_nf6_0
  lda #$05
  ldx #$14
  jmp SetOpeningSurvivalMove

__ai_search_check_sicilian_be2_nf6_0:
; In the slow Sicilian Be2 line, develop g8-f6 instead of striking with d5.
  lda Board88 + $32
  cmp #BLACK_PAWN
  bne __ai_search_check_sicilian_develop_start_0
  lda Board88 + $44
  cmp #WHITE_PAWN
  bne __ai_search_check_sicilian_develop_start_0
  lda Board88 + $64
  cmp #WHITE_BISHOP
  bne __ai_search_check_sicilian_develop_start_0
  lda Board88 + $06
  cmp #BLACK_KNIGHT
  bne __ai_search_check_sicilian_develop_start_0
  lda Board88 + $25
  cmp #EMPTY_PIECE
  bne __ai_search_check_sicilian_develop_start_0
  lda #$06
  ldx #$25
  jmp SetOpeningSurvivalMove

__ai_search_check_sicilian_develop_start_0:
; 1. e4 c5 2. Nf3: develop b8-c6, not g8-f6.
  lda Board88 + $32
  cmp #BLACK_PAWN
  bne __ai_search_check_sicilian_knight_recapture_0
  lda Board88 + $44
  cmp #WHITE_PAWN
  bne __ai_search_check_sicilian_knight_recapture_0
  lda Board88 + $55
  cmp #WHITE_KNIGHT
  bne __ai_search_check_sicilian_knight_recapture_0
  lda Board88 + $12
  cmp #EMPTY_PIECE
  bne __ai_search_check_sicilian_knight_recapture_0
  lda Board88 + $01
  cmp #BLACK_KNIGHT
  bne __ai_search_check_sicilian_knight_recapture_0
  lda Board88 + $06
  cmp #BLACK_KNIGHT
  bne __ai_search_check_sicilian_knight_recapture_0
  lda #$01
  ldx #$22
  jmp SetOpeningSurvivalMove

__ai_search_check_sicilian_knight_recapture_0:
; If ...Nf6 was played and white advances e5, put the knight on d5.
  lda Board88 + $25
  cmp #BLACK_KNIGHT
  bne __ai_search_no_survival_move_0
  lda Board88 + $34
  cmp #WHITE_PAWN
  bne __ai_search_no_survival_move_0
  lda Board88 + $32
  cmp #BLACK_PAWN
  bne __ai_search_no_survival_move_0
  lda Board88 + $12
  cmp #EMPTY_PIECE
  bne __ai_search_no_survival_move_0
  lda Board88 + $33
  cmp #EMPTY_PIECE
  bne __ai_search_no_survival_move_0
  lda #$25
  ldx #$33
  jmp SetOpeningSurvivalMove

__ai_search_no_survival_move_0:
  clc
  rts

SetOpeningSurvivalMove:
  sta BestMoveFrom
  stx BestMoveTo
  sec
  rts

;
; SetupAspirationWindow
; Use the previous iterative-deepening score to search a narrow window after
; depth 1. A failed window is re-searched at full width by FindBestMove.
; Output: $e8 = alpha, $e9 = beta, AspirationAlpha/Beta mirror the window.
;
SetupAspirationWindow:
  lda IterDepth
  cmp #$02
  bcs __ai_search_use_aspiration_0

SetupFullSearchWindow:
  lda #$00
  sta SearchAspirationActive
  lda #NEG_INFINITY
  sta $e8
  sta AspirationAlpha
  lda #$7f
  sta $e9
  sta AspirationBeta
  rts

__ai_search_use_aspiration_0:
  inc SearchAspirationAttempts
  lda #$01
  sta SearchAspirationActive

  lda IterScore
  sec
  sbc #ASPIRATION_DELTA
  bvc __ai_search_asp_alpha_ok_0
  lda #NEG_INFINITY
__ai_search_asp_alpha_ok_0:
  sta $e8
  sta AspirationAlpha

  lda IterScore
  clc
  adc #ASPIRATION_DELTA
  bvc __ai_search_asp_beta_ok_0
  lda #$7f
__ai_search_asp_beta_ok_0:
  sta $e9
  sta AspirationBeta
  rts

;
; CheckAspirationFailure
; Output: carry set if IterScore is outside or on the aspiration bounds.
;
CheckAspirationFailure:
  lda SearchAspirationActive
  bne __ai_search_check_aspiration_0
  clc
  rts

__ai_search_check_aspiration_0:
; Fail low when score <= alpha.
  lda IterScore
  sec
  sbc AspirationAlpha
  beq __ai_search_aspiration_failed_0
  bvc __ai_search_asp_low_no_ov_0
  eor #$80
__ai_search_asp_low_no_ov_0:
  bmi __ai_search_aspiration_failed_0

; Fail high when score >= beta.
  lda IterScore
  sec
  sbc AspirationBeta
  bvc __ai_search_asp_high_no_ov_0
  eor #$80
__ai_search_asp_high_no_ov_0:
  bmi __ai_search_aspiration_ok_0

__ai_search_aspiration_failed_0:
  sec
  rts

__ai_search_aspiration_ok_0:
  clc
  rts

;
; FindBestMove
; Main entry point for AI to find best move
; Uses time-based iterative deepening
; Input: None (uses difficulty setting)
; Output: BestMoveFrom/BestMoveTo contain best move
;         A = best score from deepest completed search
;
FindBestMove:
; NOTE: With $35 (HIRAM=0), $A000-$BFFF is already RAM - no banking needed

; Initialize search
  jsr InitSearch

  jsr AICheckGameState
  sta EngineGameState
  cmp #GAME_NORMAL
  beq __ai_search_game_playable_0
  cmp #GAME_CHECK
  beq __ai_search_game_playable_0
  jmp FinishBestMoveNoMove

__ai_search_game_playable_0:

  jsr TryEngineOpeningSurvivalMove
  bcc __ai_search_no_survival_move_1
  jsr RootBestMoveIsLegal
  bcc __ai_search_no_survival_move_1
  jmp FinishBestMoveZero
__ai_search_no_survival_move_1:

  jsr TryImmediateQueenPromotionMove
  bcc __ai_search_no_immediate_promotion_0
  jmp FinishBestMoveZero
__ai_search_no_immediate_promotion_0:

  jsr TrySparseQueenCaptureMove
  bcc __ai_search_no_sparse_queen_capture_0
  jmp FinishBestMoveZero
__ai_search_no_sparse_queen_capture_0:

  jsr TrySparseWinningCaptureMove
  bcc __ai_search_no_sparse_winning_capture_0
  jmp FinishBestMoveZero
__ai_search_no_sparse_winning_capture_0:

  jsr TrySimpleRookPawnEndgameMove
  bcc __ai_search_no_simple_endgame_move_0
  jmp FinishBestMoveZero
__ai_search_no_simple_endgame_move_0:

  jsr TrySimpleKingPawnEndgameMove
  bcc __ai_search_no_simple_king_pawn_move_0
  jmp FinishBestMoveZero
__ai_search_no_simple_king_pawn_move_0:

  jsr TryBoxedKingPawnStormMove
  bcc __ai_search_no_boxed_king_pawn_storm_0
  jmp FinishBestMoveZero
__ai_search_no_boxed_king_pawn_storm_0:

; If a piece is already under direct pawn attack, trust search over the
; compact book. This avoids playing memorized development moves while a
; knight or bishop is hanging.
  lda SearchSide
  jsr SideHasPawnAttackedPiece
  bcs __ai_search_no_book_move_0

; Try opening book first - much faster than searching
; Compute hash for current position
  jsr ComputeZobristHash

; Look up in opening book
  jsr EngineLookupOpeningMove
  bcc __ai_search_no_book_move_0

; Book move found! A = from, Y = to. The compact book key can collide, so
; only accept the candidate if it is legal in the current position.
  sta BestMoveFrom
  sty BestMoveTo

  jsr GenerateLegalMoves
  lda MoveCount
  sta SearchRootMoveCount
  ldx #$00
__ai_search_book_legal_loop_0:
  cpx MoveCount
  beq __ai_search_no_book_move_0
__ai_search_check_book_candidate_0:
  lda MoveListFrom, x
  cmp BestMoveFrom
  bne __ai_search_next_book_candidate_0
  lda MoveListTo, x
  cmp BestMoveTo
  beq __ai_search_book_move_ok_0
__ai_search_next_book_candidate_0:
  inx
  jmp __ai_search_book_legal_loop_0

__ai_search_book_move_ok_0:
  jsr EngineBookMoveAvoidsPawnAttack
  bcc __ai_search_no_book_move_0
  lda #$01
  sta SearchUsedBook
  jmp FinishBestMoveZero

__ai_search_no_book_move_0:
; Not in book - do normal search
  jsr ClearKillers
  jsr ClearHistory
  jsr TTBeginSearch

; Get time budget based on difficulty
  ldx difficulty
  lda TimeBudgetTableLo, x
  sta TimeBudgetLo
  lda TimeBudgetTableHi, x
  sta TimeBudgetHi
  lda MaxDepthTable, x
  sta MaxSearchDepth

  jsr EngineStartSearchTimer

; Clear time up flag
  lda #$00
  sta TimeUp

; Generate legal moves for fallback
  jsr GenerateLegalMoves

; Check if there are any legal moves
  lda MoveCount
  sta SearchRootMoveCount
  beq __ai_search_no_moves_time_0

; Initialize BestMove to first legal move as fallback
  lda MoveListFrom
  sta BestMoveFrom
  lda MoveListTo
  sta BestMoveTo

; Iterative deepening with time check
  lda #1
  sta IterDepth

__ai_search_time_iter_loop_0:
; Check time before starting new iteration
  jsr EngineCheckTime
  bcs __ai_search_time_done_0; Time's up, use best move found

; Set up alpha/beta window
  jsr SetupAspirationWindow

; Search at current depth
  lda IterDepth
  jsr Negamax
  sta IterScore

  jsr CheckAspirationFailure
  bcc __ai_search_iteration_score_ready_0

; Aspiration failed. Keep the TT bounds, widen fully, and re-search once.
  inc SearchAspirationRetries
  jsr SetupFullSearchWindow
  lda IterDepth
  jsr Negamax
  sta IterScore

__ai_search_iteration_score_ready_0:
  lda IterDepth
  sta SearchCompletedDepth

; Update thinking display with current depth and best move
  jsr EngineOnSearchIteration

; Check if found mate (can stop early)
  lda IterScore
  bmi __ai_search_check_max_depth_0; Negative scores are not winning mates
  cmp #MATE_SCORE
  bne __ai_search_check_max_depth_0

__ai_search_found_mate_0:
  jmp __ai_search_time_done_0; Found forced mate, stop searching

__ai_search_check_max_depth_0:
; Increment depth for next iteration
  inc IterDepth
  lda IterDepth
  cmp MaxSearchDepth
  bcs __ai_search_time_done_0; Hit max depth limit

  jmp __ai_search_time_iter_loop_0

__ai_search_time_done_0:
  jsr RememberBestMove
  lda IterScore
  rts

__ai_search_no_moves_time_0:
; No legal moves - checkmate or stalemate
  lda #GAME_STALEMATE
  sta EngineGameState
FinishBestMoveNoMove:
  lda #$FF
  sta BestMoveFrom
  sta BestMoveTo
  sta LastEngineMoveFrom
  sta LastEngineMoveTo
  lda EngineGameState
  rts

FinishBestMoveZero:
  jsr RememberBestMove
  lda #$00
  rts

RememberBestMove:
  lda BestMoveFrom
  cmp #$ff
  beq __ai_search_remember_clear_0
  sta LastEngineMoveFrom
  lda BestMoveTo
  and #$7f
  sta LastEngineMoveTo
  rts

__ai_search_remember_clear_0:
  sta LastEngineMoveFrom
  sta LastEngineMoveTo
  rts

; Iterative deepening state
.segment "BSS"

IterDepth:
  .res 1
MaxSearchDepth:
  .res 1
IterScore:
  .res 1

.segment "CODE"

AspirationAlpha:
  .byte NEG_INFINITY
AspirationBeta:
  .byte $7f

.segment "BSS"

SearchAspirationActive:
  .res 1

.segment "CODE"
