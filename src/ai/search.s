; Generated ca65 port from Chess/ai/search.asm.
; Keep source changes in this repository in ca65 syntax.

; import-once was handled by the ca65 include topology

; Chess AI Search Module
; Implements Make/Unmake move infrastructure for tree search

.segment "CODE"

;
; Quiescence search depth limiter
MAX_QUIESCE_DEPTH = 6
CHECK_QUIESCE_MAX_DEPTH = 2
CHECK_QUIESCE_MIN_SEARCH_PLY = 2
CHECK_QUIESCE_MAX_SEARCH_PLY = 3
; Per-node move-list snapshots are indexed by SearchDepth. The deepest
; recursing main-search node is SearchDepth = MAX_DEPTH - 1 (the entry guard
; drops to quiescence at SearchDepth >= MAX_DEPTH), so the snapshot arrays must
; cover indices 0..MAX_DEPTH-1 -> MAX_DEPTH slots. Sizing this MAX_DEPTH-1 left
; the deepest ply writing one slice past the end; a forcing line that stacks
; two-plus extensions can reach that ply, and depth-6 beast makes it more
; likely. Cover the full recursing range.
MOVE_LIST_SNAPSHOT_DEPTH = MAX_DEPTH

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
TimeBudgetLo:
  .res 1
TimeBudgetHi:
  .res 1
TimeUp:
  .res 1
RootRepeatSavedCurrentPlayer:
  .res 1
PieceListUpdateDisabled:
  .res 1

.segment "CODE"

; Side to move at current search node ($80 = white, $00 = black)
SearchSide:
  .byte WHITE_COLOR

; Time budgets by difficulty level
TimeBudgetTableLo:
  .byte <TIME_EASY, <TIME_MEDIUM, <TIME_HARD, <TIME_BEAST

TimeBudgetTableHi:
  .byte >TIME_EASY, >TIME_MEDIUM, >TIME_HARD, >TIME_BEAST

; Exclusive iterative-deepening limits by difficulty (loop runs IterDepth
; 1..N-1 because N is an exclusive bound: `cmp MaxSearchDepth; bcc`).
; Easy searches depths 1-2, medium 1-3, hard 1-5. Hard depth 5 depends on
; selective pruning/reduction; brute force depth 5 is too slow.
; Beast diverges from hard with an extra ply (entry 7 -> IterDepth reaches 6).
; Beast is exempt from the headless depth cap (see platform_test.s
; EngineCheckTime); the host enforces a per-move cycle budget via the bridge,
; which commits the last completed iteration on overrun, so a depth-6 search
; that exceeds the budget safely returns the depth-5 result.
;
; SAFETY: deepening IterDepth does NOT change worst-case SearchDepth. The
; Negamax entry hard-caps recursion at SearchDepth >= MAX_DEPTH (drops to
; quiescence), and check/recapture extensions can only prolong a line up to --
; never past -- that ceiling. So MAX_DEPTH (8) and the depth-indexed arrays
; already bound the deepest extension chain at depth 5; depth 6 is identical.
MaxDepthTable:
  .byte 3, 4, 6, 7

; Keep static evaluation below the mate score band. Mate is reported as
; exactly +/-MATE_SCORE, so non-terminal scores must never look like mate.
; Part A: with 16-bit scores the eval is no longer truncated to a narrow 8-bit
; window; this limit only guards the (unreachable in practice) case where a
; pathological promotion swarm pushes static eval toward the mate band. The
; gap (MATE_SCORE - STATIC_EVAL_LIMIT = 1000) far exceeds any real eval, so no
; realistic position is clamped.
STATIC_EVAL_LIMIT = MATE_SCORE - 1000
; Part B centipawn rescale: ROOT_*_PENALTY values are applied to / compared
; against the negamax search score ($eb/$ec), which is in eval units (pawn=100
; after the rescale). They are therefore x10 of their pre-rescale magnitude to
; stay proportional. ROOT_MAJOR/WINNING_CAPTURE_MIN_SCORE are NOT eval units:
; they are thresholds on the MVV/LVA capture-ordering score (victim*16-attacker
; from MVV_LVA_ScoreValues), an independent scale, so they are left unchanged.
ROOT_MINOR_QUEEN_RAY_PENALTY = 900
ROOT_MINOR_KNIGHT_DEST_PENALTY = 450
ROOT_MINOR_ATTACKED_DEST_PENALTY = 800
ROOT_HANGING_MINOR_PENALTY = 650
ROOT_MISSED_PAWN_WIN_PENALTY = 700
ROOT_EARLY_QUEEN_MOVE_PENALTY = 450
ROOT_MISSED_ADVANCED_PAWN_PENALTY = 750
ROOT_MISSED_CENTER_BREAK_PENALTY = 600
ROOT_BLOCKED_BISHOP_RECAPTURE_PENALTY = 700
ROOT_EARLY_KING_MOVE_PENALTY = 850
ROOT_CHECKED_KING_MOVE_PENALTY = 600
ROOT_EARLY_ROOK_MOVE_PENALTY = 700
ROOT_EXPOSED_KING_FLANK_PAWN_PENALTY = 650
ROOT_REVERSE_MOVE_PENALTY = 750
ROOT_HISTORY_SEEN_PENALTY = 350
ROOT_REPETITION_PENALTY = 850
ROOT_MAJOR_CAPTURE_MIN_SCORE = 64; MVV/LVA ordering threshold (NOT eval units)
ROOT_WINNING_CAPTURE_MIN_SCORE = 32; MVV/LVA ordering threshold (NOT eval units)
FUTILITY_MARGIN = 300
LMR_MIN_DEPTH = 2
LMR_FULL_MOVES = 1
LMP_MAX_DEPTH = 2
LMP_FULL_MOVES = 8
ASPIRATION_DELTA = 200
PVS_MIN_DEPTH = 4
CHECK_EXTENSION_DEPTH = 2
NULL_MOVE_MIN_DEPTH = 3
NULL_MOVE_REDUCTION = 3
NULL_MOVE_MIN_PIECES = 8
NULL_MOVE_EVAL_MARGIN = 80

; Last move returned by FindBestMove. This lets the engine avoid immediately
; undoing its own previous quiet move even on hosts that have not wired full
; repetition history yet.
LastEngineMoveFrom:
  .byte $ff
LastEngineMoveTo:
  .byte $ff

;
; UpdatePieceListsAfterMake
; Keep compact piece lists synchronized with a just-made move.
; Input: X = UndoStack offset for current SearchDepth,
;        $f0 = from, $f1 = clean to, $f3 = moved piece after promotion.
; Clobbers: A, X, Y, piecelist helpers.
;
UpdatePieceListsAfterMake:
  stx $f6

; Remove any captured piece from its own list. En passant stores the captured
; pawn square in extra_to; normal captures use the destination square.
  ldx $f6
  lda UndoStack, x
  cmp #EMPTY_PIECE
  beq __ai_search_make_piece_move_0
  and #WHITE_COLOR
  bne __ai_search_make_remove_white_capture_0

  lda UndoStack + 3, x
  and #UNDO_FLAG_EP_CAPTURE
  beq __ai_search_make_remove_black_normal_0
  lda UndoStack + 5, x
  jmp __ai_search_make_remove_black_ready_0
__ai_search_make_remove_black_normal_0:
  lda $f1
__ai_search_make_remove_black_ready_0:
  jsr RemoveBlackPieceListSquare
  jmp __ai_search_make_piece_move_0

__ai_search_make_remove_white_capture_0:
  lda UndoStack + 3, x
  and #UNDO_FLAG_EP_CAPTURE
  beq __ai_search_make_remove_white_normal_0
  lda UndoStack + 5, x
  jmp __ai_search_make_remove_white_ready_0
__ai_search_make_remove_white_normal_0:
  lda $f1
__ai_search_make_remove_white_ready_0:
  jsr RemoveWhitePieceListSquare

__ai_search_make_piece_move_0:
; Move the active piece entry from source to destination.
  lda $f3
  and #WHITE_COLOR
  bne __ai_search_make_move_white_piece_0
  lda $f0
  ldx $f1
  jsr MoveBlackPieceListSquare
  jmp __ai_search_make_castle_list_0

__ai_search_make_move_white_piece_0:
  lda $f0
  ldx $f1
  jsr MoveWhitePieceListSquare

__ai_search_make_castle_list_0:
; Castling also moves the rook.
  ldx $f6
  lda UndoStack + 3, x
  and #UNDO_FLAG_CASTLING
  beq __ai_search_make_piece_lists_done_0

  lda $f3
  and #WHITE_COLOR
  bne __ai_search_make_castle_white_rook_0
  lda UndoStack + 5, x
  sta $f7
  lda UndoStack + 4, x
  ldx $f7
  jmp MoveBlackPieceListSquare

__ai_search_make_castle_white_rook_0:
  lda UndoStack + 5, x
  sta $f7
  lda UndoStack + 4, x
  ldx $f7
  jsr MoveWhitePieceListSquare

__ai_search_make_piece_lists_done_0:
  rts

;
; UpdatePieceListsAfterUnmake
; Reverses the piece-list changes made by UpdatePieceListsAfterMake.
; Input: X = UndoStack offset for restored parent SearchDepth,
;        $f0 = original from, $f1 = clean to, $f3 = moved piece as restored.
; Clobbers: A, X, Y, piecelist helpers.
;
UpdatePieceListsAfterUnmake:
  stx $f6

; Move the active piece entry from destination back to source.
  lda $f3
  and #WHITE_COLOR
  bne __ai_search_unmake_move_white_piece_0
  lda $f1
  ldx $f0
  jsr MoveBlackPieceListSquare
  jmp __ai_search_unmake_castle_list_0

__ai_search_unmake_move_white_piece_0:
  lda $f1
  ldx $f0
  jsr MoveWhitePieceListSquare

__ai_search_unmake_castle_list_0:
; Castling moves the rook back as well.
  ldx $f6
  lda UndoStack + 3, x
  and #UNDO_FLAG_CASTLING
  beq __ai_search_unmake_restore_capture_0

  lda $f3
  and #WHITE_COLOR
  bne __ai_search_unmake_castle_white_rook_0
  lda UndoStack + 4, x
  sta $f7
  lda UndoStack + 5, x
  ldx $f7
  jsr MoveBlackPieceListSquare
  jmp __ai_search_unmake_restore_capture_0

__ai_search_unmake_castle_white_rook_0:
  lda UndoStack + 4, x
  sta $f7
  lda UndoStack + 5, x
  ldx $f7
  jsr MoveWhitePieceListSquare

__ai_search_unmake_restore_capture_0:
; Add the captured piece back to the compact list. Exact order is intentionally
; not restored; membership and count are what move generation needs.
  ldx $f6
  lda UndoStack, x
  cmp #EMPTY_PIECE
  beq __ai_search_unmake_piece_lists_done_0
  and #WHITE_COLOR
  bne __ai_search_unmake_add_white_capture_0

  lda UndoStack + 3, x
  and #UNDO_FLAG_EP_CAPTURE
  beq __ai_search_unmake_add_black_normal_0
  lda UndoStack + 5, x
  jmp __ai_search_unmake_add_black_ready_0
__ai_search_unmake_add_black_normal_0:
  lda $f1
__ai_search_unmake_add_black_ready_0:
  jmp AddBlackPieceListSquare

__ai_search_unmake_add_white_capture_0:
  lda UndoStack + 3, x
  and #UNDO_FLAG_EP_CAPTURE
  beq __ai_search_unmake_add_white_normal_0
  lda UndoStack + 5, x
  jmp __ai_search_unmake_add_white_ready_0
__ai_search_unmake_add_white_normal_0:
  lda $f1
__ai_search_unmake_add_white_ready_0:
  jsr AddWhitePieceListSquare

__ai_search_unmake_piece_lists_done_0:
  rts

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

  lda PieceListUpdateDisabled
  bne __ai_search_skip_make_piece_lists_0
  jsr UpdatePieceListsAfterMake
__ai_search_skip_make_piece_lists_0:

; Increment search depth
  inc SearchDepth

; Flip side to move
  lda SearchSide
  eor #WHITE_COLOR
  sta SearchSide
  lda #$00
  sta ZobristHashValid

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
  lda PieceListUpdateDisabled
  bne __ai_search_skip_unmake_piece_lists_0
  jsr UpdatePieceListsAfterUnmake
__ai_search_skip_unmake_piece_lists_0:
  lda #$00
  sta ZobristHashValid
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
  lda #$01
  sta PieceListUpdateDisabled

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
  lda #$00
  sta PieceListUpdateDisabled
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

.ifndef CHESS_RULES_ONLY
; Order moves: captures first with MVV-LVA scoring (improves alpha-beta pruning)
  jsr OrderMovesMVVLVA
.endif

  lda MoveCount
  rts

;
; InitSearch
; Initialize search state before starting a new search
; Sets depth to 0 and side to current player
;
InitSearch:
  jsr InitPieceLists

  lda #$00
  sta SearchDepth
.ifndef CHESS_RULES_ONLY
  sta SearchCompletedDepth
  sta SearchRootMoveCount
  sta SearchUsedBook
  sta SearchAspirationAttempts
  sta SearchAspirationRetries
  sta SearchPVSSearches
  sta SearchPVSResearches
  sta SearchCheckExtensions
  sta SearchNullMoveAttempts
  sta SearchNullMoveCutoffs
  sta SearchNullMoveEvalSkips
  sta SearchHistoryUpdates
  sta SearchHistoryActive
  sta SearchCounterMoveActive
  sta SearchBestMoveRepairs
  lda #$ff
  sta CommittedBestFrom
  sta CommittedBestTo
  lda #$00
.endif
  sta PieceListUpdateDisabled
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

.ifndef CHESS_RULES_ONLY
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
  ldx #$7f
  lda #$ff
__ai_search_clear_counter_loop_0:
  sta CounterMoveFrom, x
  sta CounterMoveTo, x
  dex
  bpl __ai_search_clear_counter_loop_0
  lda #$00
  sta SearchHistoryActive
  sta SearchHistoryUpdates
  sta SearchCounterMoveActive
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
; StoreCounterMove
; Remember a quiet beta-cutoff as a reply to the previous move destination.
; Input: $f0 = from, $f1 = cleaned to
; Clobbers: A, Y
;
StoreCounterMove:
  lda SearchDepth
  beq __ai_search_counter_store_done_0
  tay
  lda LastMoveToByDepth, y
  cmp #$ff
  beq __ai_search_counter_store_done_0
  and #$7f
  tay
  lda $f0
  sta CounterMoveFrom, y
  lda $f1
  sta CounterMoveTo, y
  lda #$01
  sta SearchCounterMoveActive

__ai_search_counter_store_done_0:
  rts

;
; RootMoveGivesCheck
; Cheap prefilter for TryRootMateInOne. Temporarily applies a legal root move
; on Board88 only, then checks whether it attacks the opponent king. This lets
; the mate probe avoid full MakeMove/UnmakeMove work for non-checking moves.
; Input: X = move-list index.
; Output: Carry set if the move gives check, carry clear otherwise.
; Clobbers: A, X, Y, $f0-$f5, attack_sq, attack_color
;
RootMoveGivesCheck:
  lda MoveListFrom, x
  sta $f0; source
  lda MoveListTo, x
  sta $f5; original to, including promotion flag
  and #$7f
  sta $f1; clean destination

  ldy $f0
  lda Board88, y
  cmp #EMPTY_PIECE
  bne __ai_search_root_check_have_piece_0
  clc
  rts

__ai_search_root_check_have_piece_0:
  sta $f2; original moving piece
  sta $f3; piece to place on destination

; The temporary board move below does not move the rook, so skip castling.
  and #$07
  cmp #KING_TYPE
  bne __ai_search_root_check_promotion_0
  lda $f1
  sec
  sbc $f0
  cmp #$02
  beq __ai_search_root_check_reject_0
  cmp #$fe
  beq __ai_search_root_check_reject_0
  bne __ai_search_root_check_promotion_0

__ai_search_root_check_reject_0:
  jmp __ai_search_root_check_no_0

__ai_search_root_check_promotion_0:
  lda $f2
  and #$07
  cmp #PAWN_TYPE
  bne __ai_search_root_check_apply_0

  lda $f2
  and #WHITE_COLOR
  beq __ai_search_root_check_black_promo_0
  lda $f1
  and #$70
  cmp #WHITE_PROMO_ROW
  bne __ai_search_root_check_apply_0
  jmp __ai_search_root_check_promote_piece_0

__ai_search_root_check_black_promo_0:
  lda $f1
  and #$70
  cmp #BLACK_PROMO_ROW
  bne __ai_search_root_check_apply_0

__ai_search_root_check_promote_piece_0:
  lda $f5
  bmi __ai_search_root_check_knight_promo_0
  lda $f2
  and #WHITE_COLOR
  ora #QUEEN_SPR
  sta $f3
  jmp __ai_search_root_check_apply_0

__ai_search_root_check_knight_promo_0:
  lda $f2
  and #WHITE_COLOR
  ora #KNIGHT_SPR
  sta $f3

__ai_search_root_check_apply_0:
  ldy $f1
  lda Board88, y
  sta $f4; captured piece or empty

  ldy $f0
  lda #EMPTY_PIECE
  sta Board88, y
  ldy $f1
  lda $f3
  sta Board88, y

  lda SearchSide
  beq __ai_search_root_check_black_moved_0
  lda blackkingsq
  sta attack_sq
  lda #WHITES_TURN
  jmp __ai_search_root_check_attack_ready_0

__ai_search_root_check_black_moved_0:
  lda whitekingsq
  sta attack_sq
  lda #BLACKS_TURN

__ai_search_root_check_attack_ready_0:
  sta attack_color
  jsr IsSquareAttacked
  lda #$00
  rol
  sta $f5

  ldy $f0
  lda $f2
  sta Board88, y
  ldy $f1
  lda $f4
  sta Board88, y

  lda $f5
  bne __ai_search_root_check_yes_0

__ai_search_root_check_no_0:
  clc
  rts

__ai_search_root_check_yes_0:
  sec
  rts

;
; FilterCheckingMoves
; Keep only pseudo-legal moves that give check. This is intentionally applied
; before full legality filtering, so non-checking moves do not pay make/unmake
; king-safety costs in mate probes or check quiescence.
; Output: MoveList*/MoveCount compacted to checking moves only.
; Clobbers: A, X, Y, $e0-$e1, $f0-$f5, attack_sq, attack_color
;
FilterCheckingMoves:
  lda #$00
  sta $e0; read index
  sta $e1; write index

__ai_search_check_filter_loop_0:
  lda $e0
  cmp MoveCount
  bne __ai_search_check_filter_test_0
  lda $e1
  sta MoveCount
  rts

__ai_search_check_filter_test_0:
  ldx $e0
  jsr RootMoveGivesCheck
  bcc __ai_search_check_filter_next_0

  lda $e0
  cmp $e1
  beq __ai_search_check_filter_keep_0

  ldx $e0
  ldy $e1
  lda MoveListFrom, x
  sta MoveListFrom, y
  lda MoveListTo, x
  sta MoveListTo, y

__ai_search_check_filter_keep_0:
  inc $e1

__ai_search_check_filter_next_0:
  inc $e0
  jmp __ai_search_check_filter_loop_0

;
; GenerateCheckingMoves
; Generate legal checking moves for the current SearchSide.
; Output: MoveList*/MoveCount contain only legal checks.
; Clobbers: A, X, Y, many temps.
;
GenerateCheckingMoves:
  jsr ClearMoveList
  ldx SearchSide
  jsr GenerateAllMoves
  jsr FilterCheckingMoves
  jmp FilterLegalMoves

;
; TryRootMateInOne
; Root-only tactical shortcut. If any legal move leaves the opponent in check
; with no legal reply, play it immediately. This avoids iterative deepening
; proving the obvious and prevents non-mate shortcuts from stealing a forced
; mate.
;
; Output: Carry set if BestMoveFrom/BestMoveTo were set
;         Carry clear if no mate-in-one exists
; Clobbers: A, X, Y, move list, $e0-$e5
;
TryRootMateInOne:
  jsr GenerateCheckingMoves
  lda MoveCount
  bne __ai_search_mate_have_root_moves_0
  clc
  rts

__ai_search_mate_have_root_moves_0:
  jsr SaveMoveListForDepth

  lda #$00
  sta RootShortcutIndex

__ai_search_mate_loop_0:
  lda RootShortcutIndex
  cmp MoveCount
  bne __ai_search_mate_check_move_0
  clc
  rts

__ai_search_mate_check_move_0:
  tax
  lda MoveListFrom, x
  sta RootShortcutFrom
  lda MoveListTo, x
  sta RootShortcutTo

  ldx RootShortcutTo
  lda RootShortcutFrom
  jsr MakeMove

  jsr GenerateLegalMoves
  lda MoveCount
  beq __ai_search_mate_found_0

  lda RootShortcutFrom
  ldx RootShortcutTo
  jsr UnmakeMove
  jsr RestoreMoveListForDepth

  inc RootShortcutIndex
  jmp __ai_search_mate_loop_0

__ai_search_mate_found_0:
  lda RootShortcutFrom
  ldx RootShortcutTo
  jsr UnmakeMove

  lda RootShortcutFrom
  sta BestMoveFrom
  lda RootShortcutTo
  sta BestMoveTo
  sec
  rts

;
; TryRootShortcutCandidateLegal
; Accept RootShortcutFrom/RootShortcutTo if that exact move is legal.
; Output: Carry set if BestMoveFrom/BestMoveTo were set.
;         Carry clear otherwise.
; Clobbers: A, X, Y, move list
;
SetRootShortcutCandidateLegal:
  sta RootShortcutFrom
  stx RootShortcutTo
  jmp TryRootShortcutCandidateLegal

TryRootShortcutCandidateLegal:
  jsr GenerateLegalMoves
  ldx #$00

__ai_search_candidate_legal_loop_0:
  cpx MoveCount
  bne __ai_search_check_candidate_legal_0
  clc
  rts

__ai_search_check_candidate_legal_0:
  lda MoveListFrom, x
  cmp RootShortcutFrom
  bne __ai_search_next_candidate_legal_0
  lda MoveListTo, x
  cmp RootShortcutTo
  beq __ai_search_candidate_legal_0

__ai_search_next_candidate_legal_0:
  inx
  jmp __ai_search_candidate_legal_loop_0

__ai_search_candidate_legal_0:
  lda RootShortcutFrom
  sta BestMoveFrom
  lda RootShortcutTo
  sta BestMoveTo
  sec
  rts

;
; TryRootOpeningCenterPawnMove
; Before any home minor has developed, claim center space with a pawn rather
; than drifting into a knight move. This stays structural: from untouched minor
; setups prefer e-pawn space; after a quiet e3/e6 setup, use the c-pawn to fight
; for d5/d4.
; Output: Carry set if BestMoveFrom/BestMoveTo were set.
;         Carry clear otherwise.
; Clobbers: A, X, Y, move list
;
TryRootOpeningCenterPawnMove:
  jsr IsCurrentSideInCheck
  bcc __ai_search_opening_center_not_checked_0
  clc
  rts

__ai_search_opening_center_not_checked_0:
  lda SearchSide
  bne __ai_search_white_opening_center_0
  jmp __ai_search_black_opening_center_0

__ai_search_white_opening_center_0:
  lda Board88 + $44
  cmp #WHITE_PAWN
  bne __ai_search_white_e4_minor_support_0
  jmp __ai_search_white_opening_home_minor_check_0

__ai_search_white_e4_minor_support_0:
  cmp #WHITE_KNIGHT
  bne __ai_search_white_opening_home_minor_check_0
  lda Board88 + $47
  cmp #BLACK_QUEEN
  bne __ai_search_white_opening_home_minor_check_0
  lda Board88 + $46
  cmp #EMPTY_PIECE
  bne __ai_search_white_opening_home_minor_check_0
  lda Board88 + $45
  cmp #EMPTY_PIECE
  bne __ai_search_white_opening_home_minor_check_0
  lda Board88 + $63
  cmp #WHITE_PAWN
  bne __ai_search_white_opening_home_minor_check_0
  lda #$63
  ldx #$53
  jmp SetRootShortcutCandidateLegal

__ai_search_white_opening_home_minor_check_0:
; If a central enemy pawn is already established, challenge it with the
; home d-pawn even after one minor has developed. Flank pawn drift is handled
; later; do not force d4 when the f-pawn has already moved.
  jsr RootWhiteDPawnBreakAvailable
  bcc __ai_search_white_home_minor_gate_0
  lda Board88 + $65
  cmp #WHITE_PAWN
  bne __ai_search_white_home_minor_gate_0
  lda #$63
  ldx #$43
  jmp SetRootShortcutCandidateLegal

__ai_search_white_home_minor_gate_0:
; White home minors must still be undeveloped.
  lda Board88 + $71
  cmp #WHITE_KNIGHT
  bne __ai_search_no_white_opening_center_near_0
  lda Board88 + $72
  cmp #WHITE_BISHOP
  bne __ai_search_no_white_opening_center_near_0
  lda Board88 + $75
  cmp #WHITE_BISHOP
  bne __ai_search_no_white_opening_center_near_0
  lda Board88 + $76
  cmp #WHITE_KNIGHT
  bne __ai_search_no_white_opening_center_near_0
  jmp __ai_search_white_home_minors_ready_0

__ai_search_no_white_opening_center_near_0:
  jmp __ai_search_no_white_opening_center_0

__ai_search_white_home_minors_ready_0:
  lda Board88 + $63
  cmp #WHITE_PAWN
  bne __ai_search_no_white_opening_center_near_0
  lda Board88 + $65
  cmp #WHITE_PAWN
  beq __ai_search_white_f_pawn_home_0
  lda Board88 + $64
  cmp #WHITE_PAWN
  bne __ai_search_no_white_opening_center_0
  lda Board88 + $33
  cmp #BLACK_PAWN
  bne __ai_search_no_white_opening_center_0
  lda #$64
  ldx #$54
  jmp SetRootShortcutCandidateLegal

__ai_search_white_f_pawn_home_0:
  lda Board88 + $64
  cmp #WHITE_PAWN
  bne __ai_search_white_e3_center_claim_0
  lda Board88 + $52
  cmp #WHITE_PAWN
  bne __ai_search_white_c4_center_claim_0
  lda Board88 + $34
  cmp #BLACK_PAWN
  bne __ai_search_white_e_pawn_full_center_0
  lda #$63
  ldx #$43
  jmp SetRootShortcutCandidateLegal

__ai_search_white_c4_center_claim_0:
  lda Board88 + $42
  cmp #WHITE_PAWN
  bne __ai_search_white_e_pawn_full_center_0
  lda Board88 + $23
  cmp #BLACK_PAWN
  bne __ai_search_white_e_pawn_full_center_0
  lda #$63
  ldx #$43
  jmp SetRootShortcutCandidateLegal

__ai_search_white_e_pawn_full_center_0:
  lda #$64
  ldx #$44
  jmp SetRootShortcutCandidateLegal

__ai_search_white_e3_center_claim_0:
  lda Board88 + $54
  cmp #WHITE_PAWN
  beq __ai_search_white_e3_pawn_ready_0
  lda Board88 + $44
  cmp #WHITE_PAWN
  bne __ai_search_no_white_opening_center_0
  lda Board88 + $25
  cmp #BLACK_PAWN
  bne __ai_search_no_white_opening_center_0
  lda #$63
  ldx #$43
  jmp SetRootShortcutCandidateLegal

__ai_search_white_e3_pawn_ready_0:
  lda Board88 + $62
  cmp #WHITE_PAWN
  bne __ai_search_no_white_opening_center_0
  lda Board88 + $34
  cmp #BLACK_PAWN
  bne __ai_search_white_e3_flank_claim_0
  lda #$63
  ldx #$43
  jmp SetRootShortcutCandidateLegal

__ai_search_white_e3_flank_claim_0:
  lda #$62
  ldx #$42
  jmp SetRootShortcutCandidateLegal

__ai_search_no_white_opening_center_0:
  jmp __ai_search_no_opening_center_0

__ai_search_black_opening_center_0:
  lda Board88 + $34
  cmp #BLACK_PAWN
  bne __ai_search_black_e5_minor_support_0
  jmp __ai_search_black_opening_home_minor_check_0

__ai_search_black_e5_minor_support_0:
  cmp #BLACK_KNIGHT
  bne __ai_search_black_opening_home_minor_check_0
  lda Board88 + $37
  cmp #WHITE_QUEEN
  bne __ai_search_black_opening_home_minor_check_0
  lda Board88 + $36
  cmp #EMPTY_PIECE
  bne __ai_search_black_opening_home_minor_check_0
  lda Board88 + $35
  cmp #EMPTY_PIECE
  bne __ai_search_black_opening_home_minor_check_0
  lda Board88 + $13
  cmp #BLACK_PAWN
  bne __ai_search_black_opening_home_minor_check_0
  lda #$13
  ldx #$23
  jmp SetRootShortcutCandidateLegal

__ai_search_black_opening_home_minor_check_0:
  jsr RootBlackDPawnBreakAvailable
  bcc __ai_search_black_home_minor_gate_0
  lda Board88 + $15
  cmp #BLACK_PAWN
  bne __ai_search_black_home_minor_gate_0
  lda #$13
  ldx #$33
  jmp SetRootShortcutCandidateLegal

__ai_search_black_home_minor_gate_0:
; Black home minors must still be undeveloped.
  lda Board88 + $01
  cmp #BLACK_KNIGHT
  bne __ai_search_no_black_opening_center_near_0
  lda Board88 + $02
  cmp #BLACK_BISHOP
  bne __ai_search_no_black_opening_center_near_0
  lda Board88 + $05
  cmp #BLACK_BISHOP
  bne __ai_search_no_black_opening_center_near_0
  lda Board88 + $06
  cmp #BLACK_KNIGHT
  bne __ai_search_no_black_opening_center_near_0
  jmp __ai_search_black_home_minors_ready_0

__ai_search_no_black_opening_center_near_0:
  jmp __ai_search_no_opening_center_0

__ai_search_black_home_minors_ready_0:
  lda Board88 + $13
  cmp #BLACK_PAWN
  bne __ai_search_no_black_opening_center_near_0
  lda Board88 + $15
  cmp #BLACK_PAWN
  beq __ai_search_black_f_pawn_home_0
  lda Board88 + $14
  cmp #BLACK_PAWN
  bne __ai_search_no_opening_center_0
  lda Board88 + $43
  cmp #WHITE_PAWN
  bne __ai_search_no_opening_center_0
  lda #$14
  ldx #$24
  jmp SetRootShortcutCandidateLegal

__ai_search_black_f_pawn_home_0:
  lda Board88 + $14
  cmp #BLACK_PAWN
  bne __ai_search_black_e6_center_claim_0
  lda Board88 + $22
  cmp #BLACK_PAWN
  bne __ai_search_black_c5_center_claim_0
  lda Board88 + $44
  cmp #WHITE_PAWN
  bne __ai_search_black_e_pawn_full_center_0
  lda #$13
  ldx #$33
  jmp SetRootShortcutCandidateLegal

__ai_search_black_c5_center_claim_0:
  lda Board88 + $32
  cmp #BLACK_PAWN
  bne __ai_search_black_e_pawn_full_center_0
  lda Board88 + $53
  cmp #WHITE_PAWN
  bne __ai_search_black_e_pawn_full_center_0
  lda #$13
  ldx #$33
  jmp SetRootShortcutCandidateLegal

__ai_search_black_e_pawn_full_center_0:
  lda #$14
  ldx #$34
  jmp SetRootShortcutCandidateLegal

__ai_search_black_e6_center_claim_0:
  lda Board88 + $24
  cmp #BLACK_PAWN
  beq __ai_search_black_e6_pawn_ready_0
  lda Board88 + $34
  cmp #BLACK_PAWN
  bne __ai_search_no_opening_center_0
  lda Board88 + $55
  cmp #WHITE_PAWN
  bne __ai_search_no_opening_center_0
  lda #$13
  ldx #$33
  jmp SetRootShortcutCandidateLegal

__ai_search_black_e6_pawn_ready_0:
  lda Board88 + $12
  cmp #BLACK_PAWN
  bne __ai_search_no_opening_center_0
  lda Board88 + $44
  cmp #WHITE_PAWN
  bne __ai_search_black_e6_flank_claim_0
  lda #$13
  ldx #$33
  jmp SetRootShortcutCandidateLegal

__ai_search_black_e6_flank_claim_0:
  lda #$12
  ldx #$32
  jmp SetRootShortcutCandidateLegal

__ai_search_no_opening_center_0:
  clc
  rts

;
; TryRootDevelopingBishopRecaptureMove
; If an enemy pawn reaches d/e on the third/sixth rank and a home bishop can
; recapture it, prefer the developing bishop capture over a structure-wrecking
; side-pawn recapture or a long shallow search.
; Output: Carry set if BestMoveFrom/BestMoveTo were set.
;         Carry clear otherwise.
; Clobbers: A, X, Y, move list
;
TryRootDevelopingBishopRecaptureMove:
  jsr IsCurrentSideInCheck
  bcc __ai_search_bishop_recap_not_checked_0
  clc
  rts

__ai_search_bishop_recap_not_checked_0:
  lda SearchSide
  beq __ai_search_black_bishop_recap_0

  lda Board88 + $53
  cmp #BLACK_PAWN
  bne __ai_search_white_bishop_recap_e3_0
  lda Board88 + $75
  cmp #WHITE_BISHOP
  bne __ai_search_white_bishop_recap_e3_0
  lda Board88 + $64
  cmp #EMPTY_PIECE
  bne __ai_search_white_bishop_recap_e3_0
  lda #$75
  ldx #$53
  jmp SetRootShortcutCandidateLegal

__ai_search_white_bishop_recap_e3_0:
  lda Board88 + $54
  cmp #BLACK_PAWN
  bne __ai_search_no_bishop_recap_0
  lda Board88 + $72
  cmp #WHITE_BISHOP
  bne __ai_search_no_bishop_recap_0
  lda Board88 + $63
  cmp #EMPTY_PIECE
  bne __ai_search_no_bishop_recap_0
  lda #$72
  ldx #$54
  jmp SetRootShortcutCandidateLegal

__ai_search_black_bishop_recap_0:
  lda Board88 + $23
  cmp #WHITE_PAWN
  bne __ai_search_black_bishop_recap_e6_0
  lda Board88 + $05
  cmp #BLACK_BISHOP
  bne __ai_search_black_bishop_recap_e6_0
  lda Board88 + $14
  cmp #EMPTY_PIECE
  bne __ai_search_black_bishop_recap_e6_0
  lda #$05
  ldx #$23
  jmp SetRootShortcutCandidateLegal

__ai_search_black_bishop_recap_e6_0:
  lda Board88 + $24
  cmp #WHITE_PAWN
  bne __ai_search_no_bishop_recap_0
  lda Board88 + $02
  cmp #BLACK_BISHOP
  bne __ai_search_no_bishop_recap_0
  lda Board88 + $13
  cmp #EMPTY_PIECE
  bne __ai_search_no_bishop_recap_0
  lda #$02
  ldx #$24
  jmp SetRootShortcutCandidateLegal

__ai_search_no_bishop_recap_0:
  clc
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
  bne __ai_search_sparse_queen_material_fail_0

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
; TryRootMajorCaptureMove
; In any position, take the best legal queen/rook capture that passes the
; swap-off gate. This broadens the sparse tactical shortcut to real positions
; without trusting obviously poisoned heavy-piece grabs.
;
; Output: Carry set if BestMoveFrom/BestMoveTo were set
;         Carry clear otherwise
; Clobbers: A, X, Y, move list, $e0-$e4, $f0-$f7
;
TryRootMajorCaptureMove:
  ldx #$00
__ai_search_major_piece_scan_loop_0:
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_search_major_piece_next_square_0

  lda SearchSide
  beq __ai_search_scan_white_major_0

  lda Board88, x
  cmp #BLACK_ROOK
  beq __ai_search_have_major_piece_0
  cmp #BLACK_QUEEN
  beq __ai_search_have_major_piece_0
  jmp __ai_search_major_piece_next_square_0

__ai_search_scan_white_major_0:
  lda Board88, x
  cmp #WHITE_ROOK
  beq __ai_search_have_major_piece_0
  cmp #WHITE_QUEEN
  beq __ai_search_have_major_piece_0

__ai_search_major_piece_next_square_0:
  inx
  txa
  and #$08
  beq __ai_search_major_piece_check_done_0
  txa
  clc
  adc #$08
  tax
__ai_search_major_piece_check_done_0:
  cpx #BOARD_SIZE
  bne __ai_search_major_piece_scan_loop_0
  clc
  rts

__ai_search_have_major_piece_0:
  jsr GenerateLegalMoves

  lda #$ff
  sta RootShortcutFrom
  lda #$00
  sta $e0; move index
  sta $e1; best score

__ai_search_major_capture_loop_0:
  lda $e0
  cmp MoveCount
  bne __ai_search_check_major_capture_0
  lda RootShortcutFrom
  cmp #$ff
  beq __ai_search_no_major_capture_0
  jmp __ai_search_accept_major_capture_0
__ai_search_no_major_capture_0:
  clc
  rts

__ai_search_check_major_capture_0:
  ldx $e0
  lda MoveListTo, x
  and #$7f
  tay
  lda Board88, y
  cmp #EMPTY_PIECE
  beq __ai_search_next_major_capture_0
  and #$07
  tay
  lda MVV_LVA_ScoreValues, y
  cmp #$05
  bcc __ai_search_next_major_capture_0
  sta $e2; victim rank

  ldx $e0
  lda MoveListFrom, x
  sta NegamaxState + 3
  lda MoveListTo, x
  sta NegamaxState + 4
  jsr RootEarlyQueenPawnRecapture
  bcs __ai_search_next_major_capture_0

  ldx $e0
  jsr CapturePassesSwapOff
  bcc __ai_search_next_major_capture_0

  lda $e2
  asl
  asl
  asl
  asl
  sta $e3; victim rank * 16

  ldx $e0
  lda MoveListFrom, x
  tay
  lda Board88, y
  and #$07
  sta $e4
; Queen-for-queen captures are often equalizing trades, not tactical wins.
; Let full root search compare them against forcing queen attacks by minors.
  cmp #QUEEN_TYPE
  bne __ai_search_major_capture_check_king_0
  lda $e2
  cmp #$09
  beq __ai_search_next_major_capture_0
  lda $e4

__ai_search_major_capture_check_king_0:
  cmp #KING_TYPE
  bne __ai_search_major_capture_attacker_rank_0
  lda $e3
  sec
  sbc #$0a
  jmp __ai_search_major_capture_score_ready_0

__ai_search_major_capture_attacker_rank_0:
  ldy $e4
  lda $e3
  sec
  sbc MVV_LVA_ScoreValues, y

__ai_search_major_capture_score_ready_0:
  cmp #ROOT_MAJOR_CAPTURE_MIN_SCORE
  bcc __ai_search_next_major_capture_0
  cmp $e1
  bcc __ai_search_next_major_capture_0

  sta $e1
  ldx $e0
  lda MoveListFrom, x
  sta RootShortcutFrom
  lda MoveListTo, x
  sta RootShortcutTo

__ai_search_next_major_capture_0:
  inc $e0
  jmp __ai_search_major_capture_loop_0

__ai_search_accept_major_capture_0:
  lda RootShortcutFrom
  sta BestMoveFrom
  lda RootShortcutTo
  sta BestMoveTo
  sec
  rts

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
  sta $e6; own pawn square
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
  stx $e6
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
  beq __ai_search_black_rook_behind_pawn_0
  lda $e6
  clc
  adc #$10
  cmp $e0
  beq __ai_search_rook_unblock_passer_0
  jmp __ai_search_rook_cutoff_target_0

__ai_search_black_rook_behind_pawn_0:
  lda $e6
  sec
  sbc #$10
  cmp $e0
  bne __ai_search_rook_cutoff_target_0

__ai_search_rook_unblock_passer_0:
  lda $e0
  and #$07
  cmp #$04
  bcc __ai_search_rook_unblock_right_0
  lda $e0
  sec
  sbc #$01
  jmp __ai_search_rook_unblock_target_ready_0

__ai_search_rook_unblock_right_0:
  lda $e0
  clc
  adc #$01

__ai_search_rook_unblock_target_ready_0:
  sta $e5
  jmp __ai_search_rook_target_ready_0

__ai_search_rook_cutoff_target_0:
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
  lda #$00
  sta $e4

PrepareRootWinningCaptureScan:
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
  beq __ai_search_no_winning_capture_0
  jmp __ai_search_accept_capture_0

__ai_search_no_winning_capture_0:
  clc
  rts

__ai_search_check_capture_0:
  ldx $e2
  lda MoveListTo, x
  and #$7f
  tay
  lda Board88, y
  cmp #EMPTY_PIECE
  bne __ai_search_have_capture_target_0
  jmp __ai_search_next_capture_0

__ai_search_have_capture_target_0:

  ldx $e2
  lda MoveListFrom, x
  sta NegamaxState + 3
  lda MoveListTo, x
  sta NegamaxState + 4
  jsr RootEarlyQueenPawnRecapture
  bcc __ai_search_check_capture_swapoff_0
  jmp __ai_search_next_capture_0

__ai_search_check_capture_swapoff_0:
  ldx $e2
  jsr CapturePassesSwapOff
  bcs __ai_search_score_capture_0
  jmp __ai_search_next_capture_0

__ai_search_score_capture_0:
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
  sta $e5
  tay
  lda MVV_LVA_ScoreValues, y
  sta $e6
; Queen trades are not automatically wins. Full root search should compare
; them against tempo moves that keep the enemy queen trapped or attacked.
  lda $e5
  cmp #QUEEN_TYPE
  bne __ai_search_capture_exposed_king_guard_0
  lda $e3
  cmp #$90
  beq __ai_search_next_capture_0

__ai_search_capture_exposed_king_guard_0:
; When the enemy king has left the back rank, non-pawn minor captures should
; stay in full search so forcing checks are not bypassed by material shortcuts.
  lda $e5
  cmp #PAWN_TYPE
  beq __ai_search_capture_attacker_rank_ready_0
  lda SearchSide
  beq __ai_search_black_capture_exposed_king_guard_0
  lda blackkingsq
  and #$70
  bne __ai_search_next_capture_0
  jmp __ai_search_capture_attacker_rank_ready_0

__ai_search_black_capture_exposed_king_guard_0:
  lda whitekingsq
  and #$70
  cmp #$70
  bne __ai_search_next_capture_0

__ai_search_capture_attacker_rank_ready_0:
; Equal captures are not root-shortcut wins if the landing square is already
; recapturable. Let normal search compare those trades against central breaks,
; checks, and tempo moves.
  lda $e3
  lsr
  lsr
  lsr
  lsr
  cmp $e6
  bne __ai_search_capture_score_values_ready_0
  ldx $e2
  jsr RootEqualCaptureDestinationAttacked
  bcs __ai_search_next_capture_0

__ai_search_capture_score_values_ready_0:
  lda $e3
  sec
  sbc $e6
  cmp $e4
  bcc __ai_search_next_capture_0
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
  sta RootProbeFrom
  lda RootShortcutTo
  sta RootProbeTo

  jsr SaveMoveListForDepth
  jsr RootProbeAllowsMateInOne
  lda #$00
  rol
  sta RootAllowsMateFlag
  jsr RestoreMoveListForDepth
  lda RootAllowsMateFlag
  beq __ai_search_capture_mate_safe_0
  clc
  rts

__ai_search_capture_mate_safe_0:
  lda RootProbeFrom
  sta BestMoveFrom
  lda RootProbeTo
  sta BestMoveTo
  sec
  rts

;
; RootEqualCaptureDestinationAttacked
; Input: X = move list index for an equal-value root capture.
; Output: Carry set if the destination is pawn-attacked after the capture.
;         Carry clear otherwise.
; Clobbers: A, X, Y, $f0-$f7
;
RootEqualCaptureDestinationAttacked:
  stx $f7

  lda MoveListTo, x
  and #$7f
  sta $f0
  tay
  lda Board88, y
  sta $f5

  lda MoveListFrom, x
  sta $f4
  tay
  lda Board88, y
  sta $f6
  and #WHITE_COLOR
  sta $f1
  lda $f6
  and #$07
  sta $f2

  ldy $f4
  lda #EMPTY_PIECE
  sta Board88, y
  ldy $f0
  lda $f6
  sta Board88, y

  jsr IsPiecePawnAttacked
  lda #$00
  rol
  sta $f3

  ldy $f4
  lda $f6
  sta Board88, y
  ldy $f0
  lda $f5
  sta Board88, y

  lda $f3
  bne __ai_search_equal_capture_attacked_0
  clc
  rts
__ai_search_equal_capture_attacked_0:
  sec
  rts

;
; TryRootWinningCaptureMove
; In normal material positions, take safe captures of loose minor-or-better
; pieces before search lets a shallow horizon talk itself into quiet drifting.
; Pawn grabs stay in search; this is for real tactical wins per byte.
;
; Output: Carry set if BestMoveFrom/BestMoveTo were set
;         Carry clear otherwise
; Clobbers: A, X, Y, move list, $e0-$e7, $f0-$f7
;
TryRootWinningCaptureMove:
  lda WhitePieceCount
  clc
  adc BlackPieceCount
  cmp #$05
  bcs __ai_search_root_winning_capture_material_ok_0
  clc
  rts

__ai_search_root_winning_capture_material_ok_0:
  jsr GenerateLegalMoves
  lda #ROOT_WINNING_CAPTURE_MIN_SCORE
  sta $e4
  jmp PrepareRootWinningCaptureScan

;
; TryRootSaveAttackedMajorMove
; If a rook or queen is under a minor attack, move that major to the first
; legal safe square instead of burning the whole root search while material is
; already hanging. This is intentionally generic and still rejects moves that
; walk into immediate mate.
;
; Output: Carry set if BestMoveFrom/BestMoveTo were set
;         Carry clear otherwise
; Clobbers: A, X, Y, move list, root probe temps, $f0-$f3
;
TryRootSaveAttackedMajorMove:
  lda SearchSide
  jsr SideHasMinorAttackedMajor
  bcs __ai_search_have_attacked_major_0
  clc
  rts

__ai_search_have_attacked_major_0:
  jsr GenerateLegalMoves
  jsr SaveMoveListForDepth
  lda #$00
  sta RootProbeIndex

__ai_search_save_major_loop_0:
  lda RootProbeIndex
  cmp MoveCount
  bne __ai_search_check_save_major_0
  jsr RestoreMoveListForDepth
  clc
  rts

__ai_search_check_save_major_0:
  tax
  lda MoveListFrom, x
  sta $f0
  tay
  lda Board88, y
  cmp #EMPTY_PIECE
  beq __ai_search_next_save_major_0
  sta $f3
  and #WHITE_COLOR
  cmp SearchSide
  bne __ai_search_next_save_major_0
  sta $f1
  lda $f3
  and #$07
  sta $f2
  cmp #ROOK_TYPE
  bcc __ai_search_next_save_major_0
  cmp #KING_TYPE
  bcs __ai_search_next_save_major_0

  jsr IsPieceKnightAttacked
  bcs __ai_search_save_major_attacked_0
  jsr IsPieceBishopAttacked
  bcc __ai_search_next_save_major_0

__ai_search_save_major_attacked_0:
  ldx RootProbeIndex
  lda MoveListTo, x
  and #$7f
  sta $f0
  jsr RootMajorDestinationUnsafe
  bcs __ai_search_next_save_major_0

  ldx RootProbeIndex
  lda MoveListFrom, x
  sta RootProbeFrom
  lda MoveListTo, x
  sta RootProbeTo
  jsr RootProbeAllowsMateInOne
  bcs __ai_search_restore_next_save_major_0

  jsr RestoreMoveListForDepth
  lda RootProbeFrom
  sta BestMoveFrom
  lda RootProbeTo
  sta BestMoveTo
  sec
  rts

__ai_search_restore_next_save_major_0:
  jsr RestoreMoveListForDepth

__ai_search_next_save_major_0:
  inc RootProbeIndex
  jmp __ai_search_save_major_loop_0

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
  bne __ai_search_kp_material_fail_0

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
  sta RootShortcutIndex; fallback: old same-rank outflanking move

  lda SearchSide
  beq __ai_search_kp_black_forward_0
  lda RootShortcutFrom
  sec
  sbc #$10
  jmp __ai_search_kp_forward_rank_ready_0

__ai_search_kp_black_forward_0:
  lda RootShortcutFrom
  clc
  adc #$10

__ai_search_kp_forward_rank_ready_0:
  and #$70
  ora $e5
  sta RootShortcutTo
  cmp RootShortcutFrom
  bne __ai_search_kp_validate_0
  lda RootShortcutIndex
  sta RootShortcutTo
  cmp RootShortcutFrom
  bne __ai_search_kp_validate_0

__ai_search_kp_no_move_0:
  clc
  rts

__ai_search_kp_validate_0:
  lda #$00
  sta $e7; first try forward outflank, then same-rank fallback
  jsr GenerateLegalMoves
  ldx #$00
__ai_search_kp_move_loop_0:
  cpx MoveCount
  bne __ai_search_kp_check_move_0
  lda $e7
  bne __ai_search_kp_validate_no_move_0
  inc $e7
  lda RootShortcutIndex
  sta RootShortcutTo
  cmp RootShortcutFrom
  beq __ai_search_kp_validate_no_move_0
  ldx #$00
  jmp __ai_search_kp_move_loop_0

__ai_search_kp_validate_no_move_0:
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
; TryLoneKingPawnConversionMove
; When the opponent has only a king, do not spend won endgames shuffling the
; rook/bishop/king forever. If we have support material or multiple pawns,
; push the legal pawn move that makes the most promotion progress.
;
; Output: Carry set if BestMoveFrom/BestMoveTo were set
;         Carry clear otherwise
; Clobbers: A, X, Y, move list, $e0-$e6
;
TryLoneKingPawnConversionMove:
  lda #$00
  sta $e0; own pawn count
  sta $e1; own support piece count
  sta $e2; enemy non-king material flag

  ldx #$00
__ai_search_convert_scan_loop_0:
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_search_convert_next_square_0

  lda SearchSide
  beq __ai_search_convert_scan_black_0

  lda Board88, x
  cmp #WHITE_KING
  beq __ai_search_convert_next_square_0
  cmp #BLACK_KING
  beq __ai_search_convert_next_square_0
  cmp #WHITE_PAWN
  beq __ai_search_convert_found_pawn_0
  and #WHITE_COLOR
  cmp #WHITE_COLOR
  beq __ai_search_convert_found_support_0
  jmp __ai_search_convert_material_fail_0

__ai_search_convert_scan_black_0:
  lda Board88, x
  cmp #BLACK_KING
  beq __ai_search_convert_next_square_0
  cmp #WHITE_KING
  beq __ai_search_convert_next_square_0
  cmp #BLACK_PAWN
  beq __ai_search_convert_found_pawn_0
  and #WHITE_COLOR
  beq __ai_search_convert_found_support_0
  jmp __ai_search_convert_material_fail_0

__ai_search_convert_found_pawn_0:
  inc $e0
  jmp __ai_search_convert_next_square_0

__ai_search_convert_found_support_0:
  inc $e1
  jmp __ai_search_convert_next_square_0

__ai_search_convert_material_fail_0:
  lda #$01
  sta $e2

__ai_search_convert_next_square_0:
  inx
  txa
  and #$08
  beq __ai_search_convert_check_done_0
  txa
  clc
  adc #$08
  tax
__ai_search_convert_check_done_0:
  cpx #BOARD_SIZE
  bne __ai_search_convert_scan_loop_0

  lda $e2
  beq __ai_search_convert_enemy_bare_0
  clc
  rts

__ai_search_convert_enemy_bare_0:
  lda $e0
  bne __ai_search_convert_have_pawns_0
  clc
  rts

__ai_search_convert_have_pawns_0:
  lda $e1
  bne __ai_search_convert_material_ok_0
  lda $e0
  cmp #$02
  bcs __ai_search_convert_material_ok_0
  clc
  rts

__ai_search_convert_material_ok_0:
  jsr GenerateLegalMoves

  lda #$ff
  sta RootShortcutFrom
  lda #$00
  sta RootShortcutTo
  sta $e3; best progress score
  sta $e4; move index

__ai_search_convert_move_loop_0:
  lda $e4
  cmp MoveCount
  bne __ai_search_convert_check_move_0
  lda RootShortcutFrom
  cmp #$ff
  bne __ai_search_convert_accept_0
  clc
  rts

__ai_search_convert_check_move_0:
  ldx $e4
  lda MoveListTo, x
  bmi __ai_search_convert_next_move_0; leave underpromotions to search
  and #$7f
  sta $e5; clean destination
  tay
  lda Board88, y
  cmp #EMPTY_PIECE
  bne __ai_search_convert_next_move_0

  ldx $e4
  lda MoveListFrom, x
  tay
  lda SearchSide
  beq __ai_search_convert_check_black_pawn_0
  lda Board88, y
  cmp #WHITE_PAWN
  bne __ai_search_convert_next_move_0
  lda $e5
  and #$70
  lsr
  lsr
  lsr
  lsr
  sta $e6; destination row
  lda #$07
  sec
  sbc $e6
  jmp __ai_search_convert_have_score_0

__ai_search_convert_check_black_pawn_0:
  lda Board88, y
  cmp #BLACK_PAWN
  bne __ai_search_convert_next_move_0
  lda $e5
  and #$70
  lsr
  lsr
  lsr
  lsr

__ai_search_convert_have_score_0:
  sta $e6
  lda RootShortcutFrom
  cmp #$ff
  beq __ai_search_convert_store_move_0
  lda $e6
  cmp $e3
  bcc __ai_search_convert_next_move_0

__ai_search_convert_store_move_0:
  lda $e6
  sta $e3
  ldx $e4
  lda MoveListFrom, x
  sta RootShortcutFrom
  lda MoveListTo, x
  sta RootShortcutTo

__ai_search_convert_next_move_0:
  inc $e4
  jmp __ai_search_convert_move_loop_0

__ai_search_convert_accept_0:
  lda RootShortcutFrom
  sta BestMoveFrom
  lda RootShortcutTo
  sta BestMoveTo
  sec
  rts

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
RootShortcutIndex:
  .res 1
RootProbeFrom:
  .res 1
RootProbeTo:
  .res 1
RootSavedBestFrom:
  .res 1
RootSavedBestTo:
  .res 1
RootAllowsMateFlag:
  .res 1
RootProbeIndex:
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
SearchCheckExtensions:
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
SearchCounterMoveActive:
  .res 1
; Number of times the final-legality guard had to replace an illegal best
; move this search. Nonzero means an engine bug upstream; the guard exists so
; a host never sees an illegal move regardless.
SearchBestMoveRepairs:
  .res 1
; Best move as of the last fully completed iteration. BestMoveFrom/To is
; scratch during root shortcut probes and partial iterations, so an external
; supervisor that cuts a search short must read this pair instead.
CommittedBestFrom:
  .res 1
CommittedBestTo:
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
; Margin for the lazy stand-pat evaluation, in engine units (Part B: 100 = one
; pawn = one centipawn). Must exceed the largest realistic swing the skipped
; terms can add on top of material + PST (pressure, mobility, king safety, pawn
; structure combined). x10 of the pre-rescale value to track the new scale.
LAZY_EVAL_MARGIN = 240

;
; EvaluateLazy
; Quiescence stand-pat evaluation with a lazy first stage. Computes material
; + PST only; when that score sits more than LAZY_EVAL_MARGIN outside the
; current alpha/beta window ($e8/$e9) the expensive positional terms cannot
; change the cutoff decision and the stage-one score is returned directly.
; Output: A = score from SearchSide's perspective.
; Clobbers: Evaluate temps, $f6-$f7
;
EvaluateLazy:
  lda #$01
  sta EvalLazyStage
  jsr Evaluate; 16-bit stage-one score (lo A / hi $ec)
  ldx #$00
  stx EvalLazyStage
  sta $f6; stage-one score lo
  lda $ec
  sta $f7; stage-one score hi

; Fail-high check: stage1 >= beta + margin? (16-bit)
  lda $e9; beta lo
  clc
  adc #<LAZY_EVAL_MARGIN
  sta $f8
  lda $ee; beta hi
  adc #>LAZY_EVAL_MARGIN
  sta $f9
  bvc __ai_search_lazy_hi_bound_ok_0
  lda #POS_INFINITY
  sta $f8
  lda #POS_INFINITY_HI
  sta $f9
__ai_search_lazy_hi_bound_ok_0:
; stage1 - (beta+margin); >= 0 -> return stage1.
  lda $f6
  sec
  sbc $f8
  lda $f7
  sbc $f9
  bvc __ai_search_lazy_hi_cmp_ok_0
  eor #$80
__ai_search_lazy_hi_cmp_ok_0:
  bmi __ai_search_lazy_not_high_0
  lda $f7
  sta $ec
  lda $f6
  rts

__ai_search_lazy_not_high_0:
; Fail-low check: stage1 <= alpha - margin? (16-bit)
  lda $e8; alpha lo
  sec
  sbc #<LAZY_EVAL_MARGIN
  sta $f8
  lda $ed; alpha hi
  sbc #>LAZY_EVAL_MARGIN
  sta $f9
  bvc __ai_search_lazy_lo_bound_ok_0
  lda #NEG_INFINITY
  sta $f8
  lda #NEG_INFINITY_HI
  sta $f9
__ai_search_lazy_lo_bound_ok_0:
; stage1 - (alpha-margin); <= 0 -> return stage1 (low), else full eval.
  lda $f6
  sec
  sbc $f8
  sta $fa
  lda $f7
  sbc $f9
  sta $fb
  ora $fa
  beq __ai_search_lazy_low_0; equal -> low
  lda $fb
  bvc __ai_search_lazy_lo_cmp_ok_0
  eor #$80
__ai_search_lazy_lo_cmp_ok_0:
  bmi __ai_search_lazy_low_0
; Near the window: the cheap score cannot decide, pay for the full terms.
  jmp Evaluate

__ai_search_lazy_low_0:
  lda $f7
  sta $ec
  lda $f6
  rts

Evaluate:
  jsr EvaluatePosition

; EvalScore is 16-bit, positive = white advantage. Part A returns the FULL
; 16-bit score (lo in A, hi in $ec) from SearchSide's perspective, clamped only
; to +/-STATIC_EVAL_LIMIT so it can never masquerade as a mate score.
;
; Clamp white-perspective EvalScore to [-STATIC_EVAL_LIMIT, +STATIC_EVAL_LIMIT].
; high vs upper limit: EvalScore - STATIC_EVAL_LIMIT > 0 -> clamp to +limit.
  lda EvalScore
  sec
  sbc #<STATIC_EVAL_LIMIT
  lda EvalScore + 1
  sbc #>STATIC_EVAL_LIMIT
  bvc __ai_search_eval_hi_no_ov_0
  eor #$80
__ai_search_eval_hi_no_ov_0:
  bmi __ai_search_eval_check_low_0; EvalScore < limit, check floor
  beq __ai_search_eval_check_low_0; equal (EvalScore==limit) is in range
; EvalScore > +limit -> clamp to +STATIC_EVAL_LIMIT
  lda #<STATIC_EVAL_LIMIT
  sta EvalScore
  lda #>STATIC_EVAL_LIMIT
  sta EvalScore + 1
  jmp __ai_search_apply_side_0

__ai_search_eval_check_low_0:
; EvalScore - (-STATIC_EVAL_LIMIT) < 0 -> clamp to -limit.
  lda EvalScore
  sec
  sbc #<-STATIC_EVAL_LIMIT
  lda EvalScore + 1
  sbc #>-STATIC_EVAL_LIMIT
  bvc __ai_search_eval_lo_no_ov_0
  eor #$80
__ai_search_eval_lo_no_ov_0:
  bpl __ai_search_apply_side_0; EvalScore >= -limit, in range
; EvalScore < -limit -> clamp to -STATIC_EVAL_LIMIT
  lda #<-STATIC_EVAL_LIMIT
  sta EvalScore
  lda #>-STATIC_EVAL_LIMIT
  sta EvalScore + 1

__ai_search_apply_side_0:
; EvalScore is the clamped 16-bit white-perspective score.
; If SearchSide is black ($00), negate to that side's perspective.
  ldx SearchSide
  bne __ai_search_eval_white_0; White = $80, keep as-is

; Black to move - 16-bit two's-complement negate.
  sec
  lda #$00
  sbc EvalScore
  sta EvalScore
  lda #$00
  sbc EvalScore + 1
  sta EvalScore + 1

__ai_search_eval_white_0:
  lda EvalScore + 1
  sta $ec; hi byte of returned score
  lda EvalScore; lo byte in A
  rts

;
; NEGATE_SCORE_A - inline 16-bit two's-complement negate for hot paths.
; Part A: the search score is 16-bit (lo in A, hi in $ec). Negates the pair in
; place, saturating -(-32768) to +32767 so the window extremes stay symmetric.
; Input/Output: A = lo, $ec = hi. Clobbers: A, $ec, flags.
;
.macro NEGATE_SCORE_A
  .local notmin
  .local notmin_pull
  .local done
; Detect the NEG_INFINITY pair ($80 lo / $80 hi) and saturate to POS_INFINITY
; ($7f / $7f) so the window extremes stay symmetric. X-safe: never touches X.
  cmp #NEG_INFINITY
  bne notmin
  pha
  lda $ec
  cmp #NEG_INFINITY_HI
  bne notmin_pull
  pla; discard saved lo
  lda #POS_INFINITY_HI
  sta $ec
  lda #POS_INFINITY
  jmp done
notmin_pull:
  pla; restore lo
notmin:
; 16-bit negate: 0 - value.
  eor #$ff
  clc
  adc #$01
  pha
  lda $ec
  eor #$ff
  adc #$00
  sta $ec
  pla
done:
.endmacro

;
; PENALTY16 - subtract an immediate unsigned penalty from the 16-bit root score
; pair $eb/$ec, clamping signed underflow to the NEG_INFINITY pair.
; Part B: the rescaled (x10) penalties exceed a byte, so the high byte uses the
; immediate's high part instead of a constant 0.
;
.macro PENALTY16 amt
  .local ok
  lda $eb
  sec
  sbc #<(amt)
  sta $eb
  lda $ec
  sbc #>(amt)
  sta $ec
  bvc ok
  lda #NEG_INFINITY
  sta $eb
  lda #NEG_INFINITY_HI
  sta $ec
ok:
.endmacro

;
; SET_NEG_INF16 - set the 16-bit root score pair $eb/$ec to NEG_INFINITY.
;
.macro SET_NEG_INF16
  lda #NEG_INFINITY
  sta $eb
  lda #NEG_INFINITY_HI
  sta $ec
.endmacro

;
; NegateSearchScore - 16-bit two's-complement negate (subroutine form).
; Input/Output: A = lo, $ec = hi. Saturates the NEG_INFINITY pair to
; POS_INFINITY. X-safe: does not clobber X.
;
NegateSearchScore:
  cmp #NEG_INFINITY
  bne __ai_search_normal_negate_0
  pha
  lda $ec
  cmp #NEG_INFINITY_HI
  bne __ai_search_negate_pull_0
  pla
  lda #POS_INFINITY_HI
  sta $ec
  lda #POS_INFINITY
  rts
__ai_search_negate_pull_0:
  pla
__ai_search_normal_negate_0:
  eor #$ff
  clc
  adc #$01
  pha
  lda $ec
  eor #$ff
  adc #$00
  sta $ec
  pla
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
; beta <= 0 (hi negative, or both bytes zero) -> skip the gate, pass straight.
  lda SearchDepth
  asl
  asl
  asl
  tax
  ldy SearchDepth
  lda NegamaxBetaHi, y; beta hi
  bmi __ai_search_null_eval_pass_0; beta < 0
  bne __ai_search_null_beta_positive_0; beta hi > 0 -> beta > 0
  lda NegamaxState + 7, x; beta hi == 0, check lo
  beq __ai_search_null_eval_pass_0; beta == 0
__ai_search_null_beta_positive_0:

  jsr Evaluate; 16-bit static eval (lo A / hi $ec)
  clc
  adc #<NULL_MOVE_EVAL_MARGIN
  sta NullStaticEval
  lda $ec
  adc #>NULL_MOVE_EVAL_MARGIN
  sta NullStaticEvalHi

  lda SearchDepth
  asl
  asl
  asl
  tax
  ldy SearchDepth
; (NullStaticEval - beta) >= 0 -> proceed with null move (eval already strong).
  lda NullStaticEval
  sec
  sbc NegamaxState + 7, x
  lda NullStaticEvalHi
  sbc NegamaxBetaHi, y
  bvc __ai_search_null_eval_cmp_no_ov_0
  eor #$80
__ai_search_null_eval_cmp_no_ov_0:
  bpl __ai_search_null_eval_pass_0; NullStaticEval >= beta

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
  ldy SearchDepth
  dey; parent index for hi arrays
; child alpha = -beta (16-bit)
  lda NegamaxBetaHi, y
  sta $ec
  lda NegamaxState + 7, x; beta lo
  NEGATE_SCORE_A
  sta $e8
  lda $ec
  sta $ed
; child beta = -beta + 1 = (child alpha) + 1 (16-bit), clamp overflow to +inf
  lda $e8
  clc
  adc #$01
  sta $e9
  lda $ed
  adc #$00
  sta $ee
  bvc __ai_search_null_beta_ready_0
  lda #POS_INFINITY
  sta $e9
  lda #POS_INFINITY_HI
  sta $ee
__ai_search_null_beta_ready_0:

  lda NegamaxState + 5, x
  sec
  sbc #NULL_MOVE_REDUCTION + 1
  bcs __ai_search_null_child_depth_ready_0
  lda #$00
__ai_search_null_child_depth_ready_0:
  jsr Negamax
  NEGATE_SCORE_A
  sta NullMoveScore
  lda $ec
  sta NullMoveScoreHi

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
  ldy SearchDepth
; (NullMoveScore - beta) >= 0 -> cutoff.
  lda NullMoveScore
  sec
  sbc NegamaxState + 7, x
  lda NullMoveScoreHi
  sbc NegamaxBetaHi, y
  bvc __ai_search_null_cmp_no_ov_0
  eor #$80
__ai_search_null_cmp_no_ov_0:
  bmi __ai_search_null_no_cutoff_0

__ai_search_null_cutoff_0:
  inc SearchNullMoveCutoffs
  ldy SearchDepth
  lda NegamaxBetaHi, y
  sta $ec
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
  jmp EvaluateLazy

__ai_search_quiesce_continue_0:
; In deeper check quiescence, standing pat is illegal. Search all legal
; evasions immediately, not just captures, or quiescence can cut off on an
; impossible "pass". The first root leaf stays capture-only for speed; root
; mate/check tactics are handled before iterative search.
  lda SearchDepth
  cmp #CHECK_QUIESCE_MIN_SEARCH_PLY
  bcc __ai_search_q_not_in_check_0
  jsr IsCurrentSideInCheck
  bcc __ai_search_q_not_in_check_0

  ldx QuiesceDepth
  lda $e8
  sta QAlpha, x
  lda $ed
  sta QAlphaHi, x
  lda $e9
  sta QBeta, x
  lda $ee
  sta QBetaHi, x
  lda #$01
  sta QInCheck, x

  jsr GenerateLegalMoves
  lda MoveCount
  beq __ai_search_q_no_checked_evasions_0
  jmp __ai_search_q_have_captures_0

__ai_search_q_no_checked_evasions_0:
  dec QuiesceDepth
; FIX 1 (mate distance): quiescence checkmate uses ply = SearchDepth +
; QuiesceDepth so mates found inside quiescence stay ordered by distance.
  lda QuiesceDepth
  clc
  adc SearchDepth
  jsr LoadMatedScore
  rts

__ai_search_q_not_in_check_0:
; Stand pat: evaluate current position
; If this position is already good enough, we don't need to search captures
  jsr EvaluateLazy; 16-bit stand_pat (lo A / hi $ec)
  sta $ea; stand_pat lo
  lda $ec
  sta $ef; stand_pat hi

; Beta cutoff: if stand_pat >= beta, return beta (16-bit: stand_pat - beta >= 0)
  lda $ea
  sec
  sbc $e9; stand_pat lo - beta lo
  lda $ef
  sbc $ee; stand_pat hi - beta hi
  bvc __ai_search_q_no_ov1_0
  eor #$80; Overflow correction for signed compare
__ai_search_q_no_ov1_0:
  bmi __ai_search_q_no_beta_cut_0
; stand_pat >= beta, return beta
  dec QuiesceDepth
  lda $ee
  sta $ec
  lda $e9
  rts

__ai_search_q_no_beta_cut_0:
; Update alpha if stand_pat > alpha (16-bit: stand_pat - alpha > 0)
  lda $ea; stand_pat lo
  sec
  sbc $e8; - alpha lo
  sta $f0
  lda $ef; stand_pat hi
  sbc $ed; - alpha hi
  sta $f1
  ora $f0
  beq __ai_search_q_alpha_ok_0; equal -> no update
  lda $f1
  bvc __ai_search_q_no_ov2_0
  eor #$80
__ai_search_q_no_ov2_0:
  bmi __ai_search_q_alpha_ok_0
  lda $ea
  sta $e8; alpha = stand_pat lo
  lda $ef
  sta $ed; alpha = stand_pat hi

__ai_search_q_alpha_ok_0:
; Save alpha/beta to quiescence state area
  ldx QuiesceDepth
  lda $e8
  sta QAlpha, x
  lda $ed
  sta QAlphaHi, x
  lda $e9
  sta QBeta, x
  lda $ee
  sta QBetaHi, x
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
  beq __ai_search_q_no_pseudo_caps_0
  jmp __ai_search_q_have_captures_0
__ai_search_q_no_pseudo_caps_0:

; A quiet leaf still needs a checkmate guard. If the side to move is checked
; and has no captures, search all legal evasions and report mate if none exist.
  jsr IsCurrentSideInCheck
  bcc __ai_search_q_return_quiet_alpha_0

  ldx QuiesceDepth
  lda #$01
  sta QInCheck, x
  jsr GenerateLegalMoves
  lda MoveCount
  beq __ai_search_q_no_evasions_0
  jmp __ai_search_q_have_captures_0
__ai_search_q_no_evasions_0:

  dec QuiesceDepth
; FIX 1 (mate distance): quiescence checkmate uses ply = SearchDepth +
; QuiesceDepth so mates found inside quiescence stay ordered by distance.
  lda QuiesceDepth
  clc
  adc SearchDepth
  jsr LoadMatedScore
  rts

__ai_search_q_return_quiet_alpha_0:
; At the first quiet quiescence ply, search legal quiet checks. This is tightly
; bounded so forcing checks are visible without turning quiescence into full
; width search.
  lda SearchDepth
  cmp #CHECK_QUIESCE_MIN_SEARCH_PLY
  bcc __ai_search_q_return_quiet_now_0
  cmp #CHECK_QUIESCE_MAX_SEARCH_PLY + 1
  bcs __ai_search_q_return_quiet_now_0
  lda QuiesceDepth
  cmp #CHECK_QUIESCE_MAX_DEPTH
  bcs __ai_search_q_return_quiet_now_0

  jsr GenerateCheckingMoves
  lda MoveCount
  beq __ai_search_q_return_quiet_now_0

  ldx QuiesceDepth
  lda #$02
  sta QInCheck, x
  jmp __ai_search_q_have_captures_0

__ai_search_q_return_quiet_now_0:
  ldx QuiesceDepth
  dec QuiesceDepth
  lda QAlphaHi, x
  sta $ec
  lda QAlpha, x
  rts

;
; QSaveMoveList / QRestoreMoveList
; Snapshot the current node's ordered move list so child quiescence calls can
; clobber the shared buffer freely. Restore sets carry on success; carry clear
; means the list was oversized and the caller must regenerate.
; Clobbers: A, X, Y, $f0
;
QSaveMoveList:
  lda MoveCount
  cmp #QSAVED_MAX_MOVES + 1
  bcc __ai_search_qsave_fits_0
  ldx QuiesceDepth
  lda #$ff
  sta QSavedCount, x
  rts
__ai_search_qsave_fits_0:
  ldx QuiesceDepth
  sta QSavedCount, x
; Copy top-down with X tracking base+index in lockstep with Y; identical
; bytes land in the same slots, minus the per-move base+index recompute.
  lda QuiesceDepth
  asl
  asl
  asl
  asl
  asl
  clc
  adc MoveCount
  tax; X = base (depth * 32) + count
  ldy MoveCount
  beq __ai_search_qsave_done_0
__ai_search_qsave_loop_0:
  dex
  dey
  lda MoveListFrom, y
  sta QSavedFrom, x
  lda MoveListTo, y
  sta QSavedTo, x
  cpy #$00
  bne __ai_search_qsave_loop_0
__ai_search_qsave_done_0:
  rts

QRestoreMoveList:
  ldx QuiesceDepth
  lda QSavedCount, x
  cmp #$ff
  bne __ai_search_qrestore_ok_0
  clc
  rts
__ai_search_qrestore_ok_0:
  sta MoveCount
; Mirror of the save loop: top-down copy, X = base+index in lockstep with Y.
  lda QuiesceDepth
  asl
  asl
  asl
  asl
  asl
  clc
  adc MoveCount
  tax; X = base (depth * 32) + count
  ldy MoveCount
  beq __ai_search_qrestore_done_0
__ai_search_qrestore_loop_0:
  dex
  dey
  lda QSavedFrom, x
  sta MoveListFrom, y
  lda QSavedTo, x
  sta MoveListTo, y
  cpy #$00
  bne __ai_search_qrestore_loop_0
__ai_search_qrestore_done_0:
  sec
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

; Recurse: -Quiesce(-beta, -alpha) (16-bit windows)
  ldx QuiesceDepth
  lda QBetaHi, x
  sta $ec
  lda QBeta, x
  NEGATE_SCORE_A
  sta $e8; child alpha lo = -beta
  lda $ec
  sta $ed; child alpha hi

  ldx QuiesceDepth
  lda QAlphaHi, x
  sta $ec
  lda QAlpha, x
  NEGATE_SCORE_A
  sta $e9; child beta lo = -alpha
  lda $ec
  sta $ee; child beta hi

  jsr Quiesce

; Negate score (lo A / hi $ec)
  NEGATE_SCORE_A
  ldx QuiesceDepth
  sta QScore, x; QScore lo = -child_score
  lda $ec
  sta QScoreHi, x; QScore hi

; Unmake move
  ldy QuiesceDepth
  ldx QTo, y
  lda QFrom, y
  jsr UnmakeMove

; Beta cutoff? (16-bit: QScore - QBeta >= 0)
  ldx QuiesceDepth
  lda QScore, x
  sec
  sbc QBeta, x; lo
  lda QScoreHi, x
  sbc QBetaHi, x; hi
  bvc __ai_search_q_no_ov3_0
  eor #$80
__ai_search_q_no_ov3_0:
  bmi __ai_search_q_no_cut_0
; score >= beta, return beta
  ldx QuiesceDepth
  dec QuiesceDepth
  lda QBetaHi, x
  sta $ec
  lda QBeta, x
  rts

__ai_search_q_no_cut_0:
; Update alpha if score > alpha (16-bit: QScore - QAlpha > 0)
  ldx QuiesceDepth
  lda QScore, x
  sec
  sbc QAlpha, x; lo
  sta $f0
  lda QScoreHi, x
  sbc QAlphaHi, x; hi
  sta $f1
  ora $f0
  beq __ai_search_q_next_cap_0; equal -> no update
  lda $f1
  bvc __ai_search_q_no_ov4_0
  eor #$80
__ai_search_q_no_ov4_0:
  bmi __ai_search_q_next_cap_0
  ldx QuiesceDepth
  lda QScore, x
  sta QAlpha, x; alpha = score lo
  lda QScoreHi, x
  sta QAlphaHi, x; alpha = score hi

__ai_search_q_next_cap_0:
; Child quiescence clobbered the shared move list, so rebuild it before the
; next parent move. The save/restore shortcut (QSaveMoveList/QRestoreMoveList)
; was unsound: restoring a snapshot across quiescence make/unmake corrupted
; piece-list/stack state on some capture sequences and crashed deep beast
; searches (illegal opcode at ~$09A0; repro FEN in the tracked task).
; Regeneration is provably correct; reinstate save/restore only with a
; validated fix. The QSave* helper remains defined but unused.
  ldx QuiesceDepth
  lda QInCheck, x
  cmp #$01
  beq __ai_search_q_regen_evasions_0
  cmp #$02
  beq __ai_search_q_regen_checks_0

__ai_search_q_regen_captures_0:
  ldx SearchSide
  jsr GenerateCaptures
  jsr FilterLegalMoves
  jsr OrderMovesMVVLVA
  jmp __ai_search_q_regen_done_0

__ai_search_q_regen_evasions_0:
  jsr GenerateLegalMoves
  jmp __ai_search_q_regen_done_0

__ai_search_q_regen_checks_0:
  jsr GenerateCheckingMoves

__ai_search_q_regen_done_0:
  ldx QuiesceDepth
  inc QMoveIdx, x
  jmp __ai_search_q_capture_loop_0

__ai_search_q_return_alpha_0:
  ldx QuiesceDepth
  dec QuiesceDepth
  lda QAlphaHi, x
  sta $ec
  lda QAlpha, x
  rts

; Quiescence state storage. Index 0 is unused by the current depth counter,
; which enters active nodes at depth 1 and evaluates immediately at depth 6.
.segment "BSS"

QAlpha:   .res MAX_QUIESCE_DEPTH
QAlphaHi: .res MAX_QUIESCE_DEPTH
QBeta:    .res MAX_QUIESCE_DEPTH
QBetaHi:  .res MAX_QUIESCE_DEPTH
QFrom:    .res MAX_QUIESCE_DEPTH
QTo:      .res MAX_QUIESCE_DEPTH
QScore:   .res MAX_QUIESCE_DEPTH
QScoreHi: .res MAX_QUIESCE_DEPTH
QMoveIdx: .res MAX_QUIESCE_DEPTH
QInCheck: .res MAX_QUIESCE_DEPTH
; Per-depth saved move lists. Regenerating + refiltering the shared move list
; after every searched capture made quiescence O(moves^2) in make/unmake;
; restoring a 32-entry copy costs a few hundred cycles instead. Count $ff
; marks an oversized list that must fall back to regeneration.
QSAVED_MAX_MOVES = 32
QSavedCount: .res MAX_QUIESCE_DEPTH + 2
QSavedFrom:  .res (MAX_QUIESCE_DEPTH + 2) * QSAVED_MAX_MOVES
QSavedTo:    .res (MAX_QUIESCE_DEPTH + 2) * QSAVED_MAX_MOVES

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

; Part A: best score is a real 16-bit value (lo in NegamaxState+1, hi in
; NegamaxBestHi). Store both bytes; the prior sign-extend-of-8-bit hack is gone.
  lda NegamaxState + 1, x
  sta TTScoreLo
  ldy SearchDepth
  lda NegamaxBestHi, y
  sta TTScoreHi

; FIX 1 (mate distance): make a mate score ply-relative before it is stored so
; it is portable across plies. Non-mate scores pass through unchanged.
  jsr MateStoreAdjust

  ldy SearchDepth
  lda NegamaxBestFrom, y
  sta TTStoreFrom
  lda NegamaxBestTo, y
  sta TTStoreTo
  lda #$01
  sta TTStoreUseMove

  ldy SearchDepth
  lda NegamaxHashLo, y
  sta ZobristHash
  lda NegamaxHashHi, y
  sta ZobristHash + 1
  lda #$01
  sta ZobristHashValid

  lda SearchDepth
  asl
  asl
  asl
  tax
  lda NegamaxState + 5, x
  ldx TTFlag
  jmp TTStore

;
; FIX 1 (mate distance): LoadMatedScore
; Build the "side to move is checkmated" score with distance-to-mate encoded so
; the search prefers faster mates and the longest defense. Standard negamax
; convention: a checkmate at ply P returns -(MATE_SCORE - P). Because the score
; grows toward 0 as P grows, a nearer mate (small P) scores more negative and is
; correctly avoided harder, while the mating side's negated sibling scores
; +(MATE_SCORE - P) and prefers the smallest P (fastest mate).
;
; -(MATE_SCORE - P) == P - MATE_SCORE == P + (-MATE_SCORE), so add the (small,
; unsigned 0..255) ply to the 16-bit constant -MATE_SCORE.
; Input:  A = ply distance from the root for this terminal node.
; Output: A = score lo, $ec = score hi (16-bit signed, ABI-correct).
; Clobbers: A.
;
LoadMatedScore:
  clc
  adc #<-MATE_SCORE; A = ply + lo(-MATE_SCORE)
  pha; stash score lo
  lda #>-MATE_SCORE
  adc #$00; propagate carry from the low add
  sta $ec; score hi
  pla; score lo back into A
  rts

;
; FIX 1 (mate distance): TT mate-score (de)normalization.
; Mate scores must be made ply-relative before storing and ply-absolute after
; probing, otherwise a mate distance stored at one ply is misread at another.
;
; Convention (matches LoadMatedScore):
;   winning mate   score in ( STATIC_EVAL_LIMIT, +MATE_SCORE]
;   losing mate    score in [-MATE_SCORE, -STATIC_EVAL_LIMIT)
;
; On STORE: a winning mate becomes more "won" (closer to +MATE_SCORE) by adding
; ply; a losing mate becomes more "lost" by subtracting ply. This bakes the
; absolute (root-relative) distance into the stored value.
; On PROBE: the inverse, re-centering the stored absolute mate onto the current
; node's ply.
;
; MateStoreAdjust / MateProbeAdjust both operate in place on TTScoreLo/TTScoreHi
; using ply = SearchDepth, and leave non-mate scores untouched.
; Clobbers: A, X, Y.
;
MateStoreAdjust:
  jsr __mate_classify; sets X = 1 winning, 2 losing, 0 neither
  cpx #$01
  beq __mate_add_ply; winning -> +ply on store
  cpx #$02
  beq __mate_sub_ply; losing  -> -ply on store
  rts

MateProbeAdjust:
  jsr __mate_classify
  cpx #$01
  beq __mate_sub_ply; winning -> -ply on probe (inverse of store)
  cpx #$02
  beq __mate_add_ply; losing  -> +ply on probe
  rts

; Classify TTScoreLo/Hi vs +/-STATIC_EVAL_LIMIT. Returns X = 1 (winning mate),
; 2 (losing mate), or 0 (ordinary score). Clobbers A, Y.
__mate_classify:
  ldx #$00
; winning? score - STATIC_EVAL_LIMIT > 0 (16-bit signed).
  lda TTScoreLo
  sec
  sbc #<STATIC_EVAL_LIMIT
  sta $f0; lo diff (for the strict > test)
  lda TTScoreHi
  sbc #>STATIC_EVAL_LIMIT
  sta $f1
  ora $f0
  beq __mate_classify_check_low; diff == 0 -> not strictly greater
  lda $f1
  bvc __mate_classify_win_no_ov
  eor #$80
__mate_classify_win_no_ov:
  bmi __mate_classify_check_low; diff < 0 -> not winning
  ldx #$01; winning mate
  rts
__mate_classify_check_low:
; losing? score + STATIC_EVAL_LIMIT < 0 (16-bit signed):
;   score - (-STATIC_EVAL_LIMIT) < 0.
  lda TTScoreLo
  sec
  sbc #<-STATIC_EVAL_LIMIT
  lda TTScoreHi
  sbc #>-STATIC_EVAL_LIMIT
  bvc __mate_classify_lose_no_ov
  eor #$80
__mate_classify_lose_no_ov:
  bpl __mate_classify_done; diff >= 0 -> not losing
  ldx #$02; losing mate
__mate_classify_done:
  rts

; TTScore += SearchDepth (16-bit).
__mate_add_ply:
  lda TTScoreLo
  clc
  adc SearchDepth
  sta TTScoreLo
  lda TTScoreHi
  adc #$00
  sta TTScoreHi
  rts

; TTScore -= SearchDepth (16-bit).
__mate_sub_ply:
  lda TTScoreLo
  sec
  sbc SearchDepth
  sta TTScoreLo
  lda TTScoreHi
  sbc #$00
  sta TTScoreHi
  rts

;
; FIX 2 (in-tree draw detection): CheckInTreeDraw
; Decide whether the current node is a draw by repetition. Two sources:
;   (a) In-tree repetition: the current position hash already appears among the
;       ancestors on this root->leaf path (SearchPathHash[0 .. SearchDepth-1]).
;       The FIRST repetition is scored as a draw -- the standard search
;       convention -- which stops the engine from chasing perpetuals when it is
;       winning and lets it claim a saving repetition when it is losing.
;   (b) Game-history repetition: the position already occurred in the real game
;       (CheckRepetition matches the host-maintained history). Repeating it now
;       risks a draw claim, so treat one prior occurrence (RepeatCount >= 1) as a
;       draw inside the tree.
; Must be called only for non-root nodes (SearchDepth != 0) and only once the
; current ZobristHash is valid.
; Input:  ZobristHash valid; SearchDepth = current ply (> 0).
; Output: Carry SET if this node is a draw, Carry CLEAR otherwise.
; Clobbers: A, X, Y, RepeatCount.
;
CheckInTreeDraw:
; (a) Scan ancestors [0 .. SearchDepth-1] for a hash match.
  ldx #$00
__ai_search_pathscan_loop_0:
  cpx SearchDepth
  bcs __ai_search_pathscan_done_0; reached current ply -> no ancestor match
  lda ZobristHash
  cmp SearchPathHashLo, x
  bne __ai_search_pathscan_next_0
  lda ZobristHash + 1
  cmp SearchPathHashHi, x
  bne __ai_search_pathscan_next_0
  sec; ancestor match -> in-tree repetition draw
  rts
__ai_search_pathscan_next_0:
  inx
  bne __ai_search_pathscan_loop_0; SearchDepth < MAX_DEPTH so X never wraps

__ai_search_pathscan_done_0:
; (b) Game-history repetition. CheckRepetition compares the current ZobristHash
; against the host history and sets RepeatCount to the number of matches.
  jsr CheckRepetition
  lda RepeatCount
  beq __ai_search_intree_no_draw_0; zero prior occurrences -> not a draw
  sec; one or more real-game occurrences -> draw risk
  rts
__ai_search_intree_no_draw_0:
  clc
  rts

;
; ComputeSearchZobristHash
; Compute a full position hash for the current search side to move. The shared
; hash routine keys side-to-move from currentplayer for host/API calls; search
; advances SearchSide without mutating currentplayer, so xor the side key when
; those two views disagree.
; Clobbers: A, X, Y, $f7-$fb
;
ComputeSearchZobristHash:
  jsr ComputeZobristHashFromPieceLists

  lda currentplayer
  cmp #WHITES_TURN
  beq __ai_search_hash_current_white_0

__ai_search_hash_current_black_0:
  lda SearchSide
  cmp #WHITE_COLOR
  beq __ai_search_hash_flip_side_0
  rts

__ai_search_hash_current_white_0:
  lda SearchSide
  cmp #WHITE_COLOR
  beq __ai_search_hash_done_0

__ai_search_hash_flip_side_0:
  lda ZobristSide
  eor ZobristHash
  sta ZobristHash
  lda ZobristSide + 1
  eor ZobristHash + 1
  sta ZobristHash + 1

__ai_search_hash_done_0:
  lda #$01
  sta ZobristHashValid
  rts

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

; Part B: PawnAttackPenalty is now a 16-bit (x10) table; subtract the full
; 16-bit penalty from the root score $eb/$ec, clamping signed underflow.
  ldy $f2
  lda $eb
  sec
  sbc PawnAttackPenalty_Lo, y
  sta $eb
  lda $ec
  sbc PawnAttackPenalty_Hi, y
  sta $ec
  bvc __ai_search_store_score_0
  lda #NEG_INFINITY
  sta $eb
  lda #NEG_INFINITY_HI
  sta $ec
__ai_search_store_score_0:

__ai_search_done_1:
  rts

;
; RootMajorDestinationUnsafe
; Input: $f0 = clean destination, $f2 = moving piece type, $f3 = moving piece.
; Output: Carry set if the destination is attacked and does not contain an
;         equal-or-better major. Carry clear otherwise.
; Clobbers: A, Y, attack_sq, attack_color
;
RootMajorDestinationUnsafe:
  ldy $f0
  lda Board88, y
  cmp #EMPTY_PIECE
  beq __ai_search_check_root_major_attack_0
  and #$07
  cmp $f2
  bcs __ai_search_root_major_dest_safe_0

__ai_search_check_root_major_attack_0:
  lda $f0
  sta attack_sq
  lda $f3
  and #WHITE_COLOR
  beq __ai_search_black_major_0
  lda #BLACKS_TURN
  jmp __ai_search_major_attack_color_set_0
__ai_search_black_major_0:
  lda #WHITES_TURN
__ai_search_major_attack_color_set_0:
  sta attack_color
  jsr IsSquareAttacked
  rts

__ai_search_root_major_dest_safe_0:
  clc
  rts

;
; RootAttackedQueenMaterialCapture
; If the queen is already under attack, allow queen captures of non-pawn
; material to reach search even when the landing square is attacked. The queen
; is already in trouble; cashing out for material is often the least bad line.
; Input: $f0 = clean destination, $f2 = moving piece type, $f3 = moving piece.
; Output: Carry set if this is an attacked-queen material capture.
; Clobbers: A, Y, attack_sq, attack_color
;
RootAttackedQueenMaterialCapture:
  lda $f2
  cmp #QUEEN_TYPE
  beq __ai_search_attacked_queen_check_capture_0
  clc
  rts

__ai_search_attacked_queen_check_capture_0:
  ldy $f0
  lda Board88, y
  cmp #EMPTY_PIECE
  beq __ai_search_not_attacked_queen_capture_0
  and #$07
  cmp #KNIGHT_TYPE
  bcc __ai_search_not_attacked_queen_capture_0
  cmp #KING_TYPE
  bcs __ai_search_not_attacked_queen_capture_0

  lda NegamaxState + 3
  sta attack_sq
  lda $f3
  and #WHITE_COLOR
  beq __ai_search_black_queen_capture_0
  lda #BLACKS_TURN
  jmp __ai_search_queen_capture_attack_color_set_0
__ai_search_black_queen_capture_0:
  lda #WHITES_TURN
__ai_search_queen_capture_attack_color_set_0:
  sta attack_color
  jsr IsSquareAttacked
  rts

__ai_search_not_attacked_queen_capture_0:
  clc
  rts

;
; ApplyRootMajorSafetyPenalty
; Reject root rook/queen moves that land on enemy attacks while grabbing less
; than an equal major. This catches shallow raids and "active" moves where a
; major can simply be taken on the next move.
; Input/Output: $eb = root move score from the mover's perspective.
; Clobbers: A, X, Y, attack_sq, attack_color, $f0-$f5
;
ApplyRootMajorSafetyPenalty:
  ldx NegamaxState + 3; Root move from square
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_search_done_2
  sta $f3
  and #$07
  sta $f2
  cmp #ROOK_TYPE
  bcc __ai_search_done_2
  cmp #KING_TYPE
  bcs __ai_search_done_2

  lda NegamaxState + 4; Root move to square
  and #$7f
  sta $f0

  jsr RootMajorDestinationUnsafe
  bcc __ai_search_done_2

  jsr RootAttackedQueenMaterialCapture
  bcs __ai_search_done_2

  SET_NEG_INF16

__ai_search_done_2:
  rts

;
; RootQuietPawnAttacksEnemyQueen
; Input: $f0 = quiet pawn destination, $f1 = moving color.
; Output: Carry set if the pawn would attack the enemy queen from $f0.
; Clobbers: A, X, $f2, $f4
;
RootQuietPawnAttacksEnemyQueen:
  lda $f1
  beq __ai_search_black_pawn_attacks_queen_0

  lda #BLACK_QUEEN
  sta $f2
  lda $f0
  sec
  sbc #$11
  jsr CheckRootQueenTarget
  bcs __ai_search_pawn_attacks_queen_0
  lda $f0
  sec
  sbc #$0f
  jmp CheckRootQueenTarget

__ai_search_black_pawn_attacks_queen_0:
  lda #WHITE_QUEEN
  sta $f2
  lda $f0
  clc
  adc #$0f
  jsr CheckRootQueenTarget
  bcs __ai_search_pawn_attacks_queen_0
  lda $f0
  clc
  adc #$11
  jmp CheckRootQueenTarget

__ai_search_pawn_attacks_queen_0:
  sec
  rts

;
; CheckRootQueenTarget
; Input: A = target square, $f2 = enemy queen piece.
; Output: Carry set if target contains that queen.
; Clobbers: A, X, $f4
;
CheckRootQueenTarget:
  sta $f4
  and #OFFBOARD_MASK
  bne __ai_search_not_root_queen_target_0
  ldx $f4
  lda Board88, x
  cmp $f2
  beq __ai_search_is_root_queen_target_0
__ai_search_not_root_queen_target_0:
  clc
  rts
__ai_search_is_root_queen_target_0:
  sec
  rts

;
; ApplyRootQueenDangerPawnPenalty
; Reject quiet pawn pushes while an enemy queen is close to our king, unless
; the pawn move directly attacks that queen. In measured games these "one more
; pawn move" choices were how already-bad king positions turned into jokes.
; Input/Output: $eb = root move score from the mover's perspective.
; Clobbers: A, X, Y, attack_sq, attack_color, $f0-$f4
;
ApplyRootQueenDangerPawnPenalty:
  ldx NegamaxState + 3
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_search_queen_danger_pawn_done_0
  sta $f3
  and #$07
  cmp #PAWN_TYPE
  bne __ai_search_queen_danger_pawn_done_0

  lda NegamaxState + 4
  bmi __ai_search_queen_danger_pawn_done_0
  sta $f0
  tax
  lda Board88, x
  cmp #EMPTY_PIECE
  bne __ai_search_queen_danger_pawn_done_0

  lda $f3
  and #WHITE_COLOR
  sta $f1
  beq __ai_search_check_black_quiet_pawn_promo_0
  lda $f0
  and #$70
  cmp #WHITE_PROMO_ROW
  beq __ai_search_queen_danger_pawn_done_0
  jmp __ai_search_check_quiet_pawn_queen_attack_0
__ai_search_check_black_quiet_pawn_promo_0:
  lda $f0
  and #$70
  cmp #BLACK_PROMO_ROW
  beq __ai_search_queen_danger_pawn_done_0

__ai_search_check_quiet_pawn_queen_attack_0:
; Central pawn moves can blunt queen pressure and open defenders. Do not apply
; the panic filter to c/d/e/f-pawns; flank pawn moves still need to be forcing.
  lda NegamaxState + 3
  and #$07
  cmp #$02
  bcc __ai_search_check_quiet_pawn_queen_attack_1
  cmp #$06
  bcc __ai_search_queen_danger_pawn_done_0

__ai_search_check_quiet_pawn_queen_attack_1:
  jsr RootQuietPawnAttacksEnemyQueen
  bcs __ai_search_queen_danger_pawn_done_0

  jsr RootEnemyQueenNearKing
  bcc __ai_search_queen_danger_pawn_done_0
  jsr IsCurrentSideInCheck
  bcs __ai_search_queen_danger_pawn_done_0

  SET_NEG_INF16

__ai_search_queen_danger_pawn_done_0:
  rts

;
; ApplyRootQueenPawnRaidPenalty
; If an enemy queen is already near our king, reject queen moves that spend the
; tempo grabbing a pawn. In those positions the queen needs to defend, trade, or
; attack something meaningful; pawn raids routinely leave the king boxed in.
; Input/Output: $eb = root move score from the mover's perspective.
; Clobbers: A, X, Y, temp1, $f0-$f7
;
ApplyRootQueenPawnRaidPenalty:
  ldx NegamaxState + 3
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_search_queen_raid_done_0
  sta $f3
  and #$07
  cmp #QUEEN_TYPE
  bne __ai_search_queen_raid_done_0

  lda NegamaxState + 4
  and #$7f
  tax
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_search_queen_raid_done_0
  and #$07
  cmp #PAWN_TYPE
  bne __ai_search_queen_raid_done_0

  jsr RootEnemyQueenNearKing
  bcc __ai_search_queen_raid_done_0

  SET_NEG_INF16

__ai_search_queen_raid_done_0:
  rts

; SetSafeRootFallbackMove
; Pick a legal fallback that does not immediately hang a major or ignore a
; queen near the king. The search can still choose a sharper move later; this
; only controls fail-safe behavior when all root moves score at the floor.
; Clobbers: A, X, Y, attack_sq, attack_color, RootProbeIndex, $eb, $f0-$f4
;
SetSafeRootFallbackMove:
  lda MoveListFrom
  sta BestMoveFrom
  lda MoveListTo
  sta BestMoveTo

  jsr SaveMoveListForDepth
  lda #$00
  sta RootProbeIndex

__ai_search_root_fallback_loop_0:
  lda RootProbeIndex
  cmp MoveCount
  bne __ai_search_check_root_fallback_0
  rts

__ai_search_check_root_fallback_0:
  ldx RootProbeIndex
  lda MoveListFrom, x
  sta NegamaxState + 3
  lda MoveListTo, x
  sta NegamaxState + 4

  lda #$00
  sta $eb
  sta $ec; 16-bit score temp (lo/hi)
  jsr ApplyRootMajorSafetyPenalty
  jsr __ai_search_fallback_is_neg_inf_0
  beq __ai_search_next_root_fallback_0

  jsr ApplyRootHangingQueenPenalty
  jsr __ai_search_fallback_is_neg_inf_0
  beq __ai_search_next_root_fallback_0

  jsr ApplyRootQueenDangerPawnPenalty
  jsr __ai_search_fallback_is_neg_inf_0
  beq __ai_search_next_root_fallback_0

  jsr ApplyRootBlockedBishopRecapturePenalty
  jsr __ai_search_fallback_is_neg_inf_0
  beq __ai_search_next_root_fallback_0

  jsr ApplyRootExposedKingFlankPawnPenalty
  jsr __ai_search_fallback_is_neg_inf_0
  beq __ai_search_next_root_fallback_0

  jsr ApplyRootAllowsMatePenalty
  jsr RestoreMoveListForDepth
  jsr __ai_search_fallback_is_neg_inf_0
  bne __ai_search_accept_root_fallback_0

__ai_search_next_root_fallback_0:
  inc RootProbeIndex
  jmp __ai_search_root_fallback_loop_0

__ai_search_accept_root_fallback_0:
  ldx RootProbeIndex
  lda MoveListFrom, x
  sta BestMoveFrom
  lda MoveListTo, x
  sta BestMoveTo
  rts

;
; __ai_search_fallback_is_neg_inf_0
; Returns Z=1 iff the 16-bit score temp ($eb lo / $ec hi) equals the
; NEG_INFINITY pair ($8000). Clobbers A.
;
__ai_search_fallback_is_neg_inf_0:
  lda $eb
  cmp #NEG_INFINITY
  bne __ai_search_fallback_not_inf_0
  lda $ec
  cmp #NEG_INFINITY_HI
__ai_search_fallback_not_inf_0:
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
  beq __ai_search_minor_done_tramp_0
  sta $f3
  and #$07
  sta $f2
  cmp #KNIGHT_TYPE
  beq __ai_search_minor_piece_0
  cmp #BISHOP_TYPE
  beq __ai_search_minor_piece_0
__ai_search_minor_done_tramp_0:
  jmp __ai_search_done_3

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

  PENALTY16 ROOT_MINOR_QUEEN_RAY_PENALTY
  rts

__ai_search_check_knight_attack_0:
  jsr IsPieceKnightAttacked
  bcc __ai_search_check_attacked_dest_0

  PENALTY16 ROOT_MINOR_KNIGHT_DEST_PENALTY
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

  PENALTY16 ROOT_MINOR_ATTACKED_DEST_PENALTY

__ai_search_done_3:
  rts

;
; RootMoveResolvesPieceAttack
; Input: $f0 = piece square, $f1 = piece color/SearchSide.
; Output: Carry set if the root candidate leaves the piece unattacked.
; Clobbers: A, X, Y, attack_sq, attack_color, $f2-$f5
;
RootMoveResolvesPieceAttack:
  lda NegamaxState + 3; Moving the piece addresses the threat.
  cmp $f0
  beq __ai_search_resolves_piece_attack_0
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
  bcc __ai_search_resolves_piece_attack_0

__ai_search_not_resolved_0:
  clc
  rts

__ai_search_resolves_piece_attack_0:
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
; Reject root moves that ignore a queen currently attacked by an enemy piece.
; Moving the queen, blocking the attack, or capturing the attacker resolves it.
; Input/Output: $eb = root move score from the mover's perspective.
; Clobbers: A, X, Y, attack_sq, attack_color, $f0-$f7
;
ApplyRootHangingQueenPenalty:
  lda SearchSide
  sta $f1
  beq __ai_search_black_side_1
  lda #WHITE_QUEEN
  sta $f6
  lda WhitePieceCount
  sta $f5
  lda #<WhitePieceList
  sta temp1
  lda #>WhitePieceList
  sta temp1 + 1
  jmp __ai_search_queen_list_set_0
__ai_search_black_side_1:
  lda #BLACK_QUEEN
  sta $f6
  lda BlackPieceCount
  sta $f5
  lda #<BlackPieceList
  sta temp1
  lda #>BlackPieceList
  sta temp1 + 1

__ai_search_queen_list_set_0:
  lda #$00
  sta $f7

__ai_search_scan_loop_0:
  ldy $f7
  cpy $f5
  beq __ai_search_done_4
  lda (temp1), y
  tax
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

  jsr RootMoveResolvesPieceAttack
  bcs __ai_search_done_4

  SET_NEG_INF16
  rts

__ai_search_next_square_0:
  inc $f7
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

  lda #<ROOT_REVERSE_MOVE_PENALTY
  ldx #>ROOT_REVERSE_MOVE_PENALTY
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

  lda #<ROOT_REPETITION_PENALTY
  ldx #>ROOT_REPETITION_PENALTY
  jmp ApplyRootPenaltyAmount

__ai_search_history_seen_once_0:
  lda #<ROOT_HISTORY_SEEN_PENALTY
  ldx #>ROOT_HISTORY_SEEN_PENALTY
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
; Subtract a 16-bit unsigned penalty (A = low, X = high) from the 16-bit root
; score $eb/$ec and clamp signed underflow to the NEG_INFINITY pair ($8080).
; Part B: the rescaled (x10) penalties exceed a byte, so the penalty is 16-bit.
; Input: A = penalty low byte, X = penalty high byte
; Input/Output: $eb/$ec = signed root score (lo/hi)
; Clobbers: A, $f0
;
ApplyRootPenaltyAmount:
  sta $f0
  lda $eb
  sec
  sbc $f0
  sta $eb
  txa
  sta $f0
  lda $ec
  sbc $f0
  sta $ec
  bvc __ai_search_penalty_store_0
  lda #NEG_INFINITY
  sta $eb
  lda #NEG_INFINITY_HI
  sta $ec
__ai_search_penalty_store_0:
  rts

;
; RootProbeAllowsMateInOne
; Input: RootProbeFrom/RootProbeTo hold a legal candidate for the current side.
; Output: Carry set if making that move gives the opponent mate in one.
;         Carry clear otherwise.
; Clobbers: A, X, Y, move list, root shortcut temps.
;
RootProbeAllowsMateInOne:
  lda BestMoveFrom
  sta RootSavedBestFrom
  lda BestMoveTo
  sta RootSavedBestTo

  ldx RootProbeTo
  lda RootProbeFrom
  jsr MakeMove

  jsr TryRootMateInOne
  lda #$00
  rol
  sta RootAllowsMateFlag

  ldx RootProbeTo
  lda RootProbeFrom
  jsr UnmakeMove

  lda RootSavedBestFrom
  sta BestMoveFrom
  lda RootSavedBestTo
  sta BestMoveTo

  lda RootAllowsMateFlag
  bne __ai_search_probe_allows_mate_0
  clc
  rts

__ai_search_probe_allows_mate_0:
  sec
  rts

;
; RootEnemyQueenNearKing
; Cheap prefilter for mate-threat probes. Most immediate "looks stupid" mates
; in our Stockfish games came from a queen already in the king's near zone.
; Output: Carry set if an enemy queen is within two ranks and four files of our king.
;         Carry clear otherwise.
; Clobbers: A, X, Y, temp1, $f0-$f7
;
RootEnemyQueenNearKing:
  lda #$05
  sta $f6
  jmp RootEnemyQueenZoneScan

;
; RootEnemyQueenPressuresKing
; Wider queen-pressure detector used only for root king-move scoring. This
; keeps mate-threat probes narrow while allowing exposed kings to run before
; the queen is directly adjacent.
; Output: Carry set if an enemy queen is close enough to pressure our king.
;         Carry clear otherwise.
; Clobbers: A, X, Y, temp1, $f0-$f7
;
RootEnemyQueenPressuresKing:
  lda #$04
  sta $f6

RootEnemyQueenZoneScan:
  lda SearchSide
  beq __ai_search_black_king_queen_zone_0

  lda whitekingsq
  sta $f0
  lda #BLACK_QUEEN
  sta $f1
  lda BlackPieceCount
  sta $f7
  lda #<BlackPieceList
  sta temp1
  lda #>BlackPieceList
  sta temp1 + 1
  jmp __ai_search_scan_enemy_queen_zone_0

__ai_search_black_king_queen_zone_0:
  lda blackkingsq
  sta $f0
  lda #WHITE_QUEEN
  sta $f1
  lda WhitePieceCount
  sta $f7
  lda #<WhitePieceList
  sta temp1
  lda #>WhitePieceList
  sta temp1 + 1

__ai_search_scan_enemy_queen_zone_0:
  lda #$00
  sta $f2

__ai_search_queen_zone_loop_0:
  ldy $f2
  cpy $f7
  beq __ai_search_no_enemy_queen_zone_0
  lda (temp1), y
  tax
  lda Board88, x
  cmp $f1
  bne __ai_search_queen_zone_next_0

  txa
  and #$70
  sta $f3
  lda $f0
  and #$70
  sta $f4
  lda $f3
  sec
  sbc $f4
  bcs __ai_search_queen_zone_row_abs_0
  eor #$ff
  clc
  adc #$01
__ai_search_queen_zone_row_abs_0:
  sta $f3

  txa
  and #$07
  sta $f4
  lda $f0
  and #$07
  sta $f5
  lda $f4
  sec
  sbc $f5
  bcs __ai_search_queen_zone_file_abs_0
  eor #$ff
  clc
  adc #$01
__ai_search_queen_zone_file_abs_0:
  sta $f4
  lda $f4
  bne __ai_search_queen_zone_check_near_0

; Same-file queen pressure can be mate from farther away than the near-zone
; box, e.g. Qg3-g7# against a boxed king on g8.
  lda $f3
  cmp #$60
  bcc __ai_search_queen_zone_yes_0

__ai_search_queen_zone_check_near_0:
  lda $f3
  cmp #$40
  bcs __ai_search_queen_zone_next_0
  lda $f4
  cmp $f6
  bcs __ai_search_queen_zone_next_0

__ai_search_queen_zone_yes_0:
  sec
  rts

__ai_search_queen_zone_next_0:
  inc $f2
  jmp __ai_search_queen_zone_loop_0

__ai_search_no_enemy_queen_zone_0:
  clc
  rts

;
; RootOpponentHasMateInOne
; Output: Carry set if the opponent has mate in one in the current position.
;         Carry clear otherwise.
; Clobbers: A, X, Y, move list, root shortcut temps.
;
RootOpponentHasMateInOne:
  jsr RootEnemyQueenNearKing
  bcs __ai_search_probe_opp_mate_0
  clc
  rts

__ai_search_probe_opp_mate_0:
  lda BestMoveFrom
  sta RootSavedBestFrom
  lda BestMoveTo
  sta RootSavedBestTo

  lda SearchSide
  eor #WHITE_COLOR
  sta SearchSide

  jsr TryRootMateInOne
  lda #$00
  rol
  sta RootAllowsMateFlag

  lda SearchSide
  eor #WHITE_COLOR
  sta SearchSide

  lda RootSavedBestFrom
  sta BestMoveFrom
  lda RootSavedBestTo
  sta BestMoveTo

  lda RootAllowsMateFlag
  bne __ai_search_opp_has_mate_0
  clc
  rts

__ai_search_opp_has_mate_0:
  sec
  rts

;
; TryRootAvoidMateThreatMove
; If the opponent threatens immediate mate, play the first ordered legal move
; that removes every opponent mate-in-one. This is intentionally blunt: in a
; mate-threat position, not dying matters more than shallow material taste.
; Output: Carry set if BestMoveFrom/BestMoveTo were set.
;         Carry clear if no immediate mate threat or no escape was found.
; Clobbers: A, X, Y, move list, root shortcut temps.
;
TryRootAvoidMateThreatMove:
  jsr IsCurrentSideInCheck
  bcs __ai_search_no_root_mate_threat_1
  jsr RootOpponentHasMateInOne
  bcs __ai_search_have_mate_threat_1

__ai_search_no_root_mate_threat_1:
  clc
  rts

__ai_search_have_mate_threat_1:
__ai_search_scan_mate_escapes_0:
  jsr GenerateLegalMoves
  lda MoveCount
  bne __ai_search_have_mate_escape_moves_0
  clc
  rts

__ai_search_have_mate_escape_moves_0:
  jsr SaveMoveListForDepth
  lda #$00
  sta RootProbeIndex

__ai_search_mate_escape_loop_0:
  lda RootProbeIndex
  cmp MoveCount
  bne __ai_search_check_mate_escape_0
  clc
  rts

__ai_search_check_mate_escape_0:
  tax
  lda MoveListFrom, x
  sta RootProbeFrom
  lda MoveListTo, x
  sta RootProbeTo

  jsr RootProbeAllowsMateInOne
  bcc __ai_search_found_mate_escape_0

  jsr RestoreMoveListForDepth
  inc RootProbeIndex
  jmp __ai_search_mate_escape_loop_0

__ai_search_found_mate_escape_0:
  lda RootProbeFrom
  sta BestMoveFrom
  lda RootProbeTo
  sta BestMoveTo
  sec
  rts

;
; ApplyRootAllowsMatePenalty
; Reject root moves that hand the opponent an immediate mate. This is a
; deliberate "do not look stupid" filter at the root only: the full search can
; miss these when pruning/reductions hide a quiet mating follow-up.
; Input/Output: $eb = root move score from the mover's perspective.
; Clobbers: A, X, Y, move list, root shortcut temps.
;
ApplyRootAllowsMatePenalty:
  lda SearchDepth
  beq __ai_search_check_allows_mate_0
  rts

__ai_search_check_allows_mate_0:
; Checked king evasions are few and tactically fragile, so verify they do not
; walk into a one-move mate. Other moves keep the cheap queen-near prefilter.
  ldx NegamaxState + 3
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_search_check_allows_mate_prefilter_0
  and #$07
  cmp #KING_TYPE
  bne __ai_search_check_allows_mate_prefilter_0
  jsr IsCurrentSideInCheck
  bcs __ai_search_probe_candidate_mate_0

__ai_search_check_allows_mate_prefilter_0:
  jsr RootEnemyQueenNearKing
  bcs __ai_search_probe_candidate_mate_0
  rts

__ai_search_probe_candidate_mate_0:
  lda NegamaxState + 3
  sta RootProbeFrom
  lda NegamaxState + 4
  sta RootProbeTo
  jsr RootProbeAllowsMateInOne
  bcs __ai_search_allows_mate_0
  rts

__ai_search_allows_mate_0:
  SET_NEG_INF16
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
  sta $f1
  beq __ai_search_hanging_black_list_0
  lda WhitePieceCount
  sta $f5
  lda #<WhitePieceList
  sta temp1
  lda #>WhitePieceList
  sta temp1 + 1
  jmp __ai_search_hanging_list_set_0

__ai_search_hanging_black_list_0:
  lda BlackPieceCount
  sta $f5
  lda #<BlackPieceList
  sta temp1
  lda #>BlackPieceList
  sta temp1 + 1

__ai_search_hanging_list_set_0:
  lda #$00
  sta $f7

__ai_search_scan_loop_1:
  ldy $f7
  cpy $f5
  beq __ai_search_done_5
  lda (temp1), y
  tax
  lda Board88, x
  sta $f3
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

  PENALTY16 ROOT_HANGING_MINOR_PENALTY
  rts

__ai_search_next_square_1:
  inc $f7
  jmp __ai_search_scan_loop_1

__ai_search_done_5:
  rts

;
; ApplyRootLoosePiecePenalty
; Penalize root moves that ignore an undefended minor or rook under non-pawn
; attack. Defended pieces and moves that move/block/capture the attacker are
; exempt.
; Input/Output: $eb = root move score from the mover's perspective.
; Clobbers: A, X, Y, attack_sq, attack_color, $f0-$f7
;
ApplyRootLoosePiecePenalty:
  lda NegamaxState + 4
  bmi __ai_search_loose_rook_skip_0
  and #$7f
  tax
  lda Board88, x
  cmp #EMPTY_PIECE
  bne __ai_search_loose_rook_skip_0

  ldx NegamaxState + 3
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_search_loose_rook_skip_0
  and #$07
  cmp #ROOK_TYPE
  bne __ai_search_loose_rook_scan_0
__ai_search_loose_rook_skip_0:
  rts

__ai_search_loose_rook_scan_0:
  lda SearchSide
  sta $f6
  beq __ai_search_loose_black_list_0
  lda WhitePieceCount
  sta $f5
  lda #<WhitePieceList
  sta temp1
  lda #>WhitePieceList
  sta temp1 + 1
  jmp __ai_search_loose_list_set_0

__ai_search_loose_black_list_0:
  lda BlackPieceCount
  sta $f5
  lda #<BlackPieceList
  sta temp1
  lda #>BlackPieceList
  sta temp1 + 1

__ai_search_loose_list_set_0:
  lda #$00
  sta $f7

__ai_search_rook_scan_loop_1:
  ldy $f7
  cpy $f5
  beq __ai_search_done_14
  lda (temp1), y
  tax
  lda Board88, x
  sta $f3
  lda $f3
  and #$07
  cmp #KNIGHT_TYPE
  bcc __ai_search_rook_next_square_1
  cmp #QUEEN_TYPE
  bcs __ai_search_rook_next_square_1

  stx $f0
  jsr IsPiecePawnAttacked
  bcs __ai_search_rook_next_square_1

  lda $f0
  sta attack_sq
  lda #BLACKS_TURN
  ldx $f6
  bne __ai_search_rook_enemy_color_set_0
  lda #WHITES_TURN
__ai_search_rook_enemy_color_set_0:
  sta attack_color
  jsr IsSquareAttacked
  bcc __ai_search_rook_next_square_1

  lda $f0
  sta attack_sq
  lda #WHITES_TURN
  ldx $f6
  bne __ai_search_rook_own_color_set_0
  lda #BLACKS_TURN
__ai_search_rook_own_color_set_0:
  sta attack_color
  jsr IsSquareAttacked
  bcs __ai_search_rook_next_square_1

  jsr RootMoveResolvesPieceAttack
  bcs __ai_search_done_14

  PENALTY16 ROOT_HANGING_MINOR_PENALTY
  rts

__ai_search_rook_next_square_1:
  inc $f7
  jmp __ai_search_rook_scan_loop_1

__ai_search_done_14:
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
  beq __ai_search_pawn_win_black_list_0
  lda WhitePieceCount
  sta $f2
  lda #<WhitePieceList
  sta temp1
  lda #>WhitePieceList
  sta temp1 + 1
  jmp __ai_search_pawn_win_list_set_0

__ai_search_pawn_win_black_list_0:
  lda BlackPieceCount
  sta $f2
  lda #<BlackPieceList
  sta temp1
  lda #>BlackPieceList
  sta temp1 + 1

__ai_search_pawn_win_list_set_0:
  lda #$00
  sta $f7

__ai_search_scan_loop_2:
  ldy $f7
  cpy $f2
  beq __ai_search_done_6
  lda (temp1), y
  tax
  lda Board88, x
  sta $f3
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
  bcc __ai_search_next_square_2

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
  bcc __ai_search_next_square_2

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
  PENALTY16 ROOT_MISSED_PAWN_WIN_PENALTY
  rts

__ai_search_next_square_2:
  inc $f7
  jmp __ai_search_scan_loop_2

__ai_search_done_6:
  rts

;
; ApplyRootMissedCentralPawnKickPenalty
; If a home f-pawn can quietly attack an enemy piece, discourage unrelated
; quiet moves. This prefers useful piece kicks over rook-pawn pokes.
; Input/Output: $eb = root move score from the mover's perspective.
; Clobbers: A, X, $f3-$f6
;
ApplyRootMissedCentralPawnKickPenalty:
  lda NegamaxState + 4
  bmi __ai_search_pawn_kick_done_0
  and #$7f
  tax
  lda Board88, x
  cmp #EMPTY_PIECE
  bne __ai_search_pawn_kick_done_0

  jsr IsCurrentSideInCheck
  bcs __ai_search_pawn_kick_done_0

  lda SearchSide
  sta $f6
  beq __ai_search_black_pawn_kick_0

  lda Board88 + $65
  cmp #WHITE_PAWN
  bne __ai_search_pawn_kick_done_0
  lda Board88 + $55
  cmp #EMPTY_PIECE
  bne __ai_search_pawn_kick_done_0
  lda #$44
  jsr CheckRootPawnWinTarget
  bcs __ai_search_white_f_pawn_available_0
  lda #$46
  jsr CheckRootPawnWinTarget
  bcc __ai_search_pawn_kick_done_0

__ai_search_white_f_pawn_available_0:
  lda NegamaxState + 3
  cmp #$65
  beq __ai_search_white_f_pawn_from_ok_0
  jmp __ai_search_penalize_pawn_kick_0
__ai_search_white_f_pawn_from_ok_0:
  lda NegamaxState + 4
  and #$7f
  cmp #$55
  beq __ai_search_pawn_kick_done_0
  jmp __ai_search_penalize_pawn_kick_0

__ai_search_black_pawn_kick_0:
  lda Board88 + $15
  cmp #BLACK_PAWN
  bne __ai_search_pawn_kick_done_0
  lda Board88 + $25
  cmp #EMPTY_PIECE
  bne __ai_search_pawn_kick_done_0
  lda #$34
  jsr CheckRootPawnWinTarget
  bcs __ai_search_black_f_pawn_available_0
  lda #$36
  jsr CheckRootPawnWinTarget
  bcc __ai_search_pawn_kick_done_0

__ai_search_black_f_pawn_available_0:
  lda NegamaxState + 3
  cmp #$15
  bne __ai_search_penalize_pawn_kick_0
  lda NegamaxState + 4
  and #$7f
  cmp #$25
  beq __ai_search_pawn_kick_done_0
  jmp __ai_search_penalize_pawn_kick_0

__ai_search_penalize_pawn_kick_0:
  lda #<ROOT_MISSED_CENTER_BREAK_PENALTY
  ldx #>ROOT_MISSED_CENTER_BREAK_PENALTY
  jmp ApplyRootPenaltyAmount

__ai_search_pawn_kick_done_0:
  rts

;
; RootWhiteEnemyCenterPawn
; Output: Carry set if black has a d/e center pawn far enough forward that
;         White should challenge it with a home-pawn break.
; Clobbers: A
;
RootWhiteEnemyCenterPawn:
  lda Board88 + $33
  cmp #BLACK_PAWN
  beq __ai_search_center_pawn_found_0
  lda Board88 + $34
  cmp #BLACK_PAWN
  beq __ai_search_center_pawn_found_0
  clc
  rts

;
; RootBlackEnemyCenterPawn
; Output: Carry set if white has a d/e center pawn far enough forward that
;         Black should challenge it with a home-pawn break.
; Clobbers: A
;
RootBlackEnemyCenterPawn:
  lda Board88 + $43
  cmp #WHITE_PAWN
  beq __ai_search_center_pawn_found_0
  lda Board88 + $44
  cmp #WHITE_PAWN
  beq __ai_search_center_pawn_found_0
  clc
  rts

__ai_search_center_pawn_found_0:
  sec
  rts

;
; RootWhiteDPawnBreakAvailable
; Output: Carry set if the home pawn can make a two-square center break.
; Clobbers: A
;
RootWhiteDPawnBreakAvailable:
  jsr RootWhiteEnemyCenterPawn
  bcc __ai_search_no_white_d_break_0
  lda Board88 + $63
  cmp #WHITE_PAWN
  bne __ai_search_no_white_d_break_0
  lda Board88 + $53
  cmp #EMPTY_PIECE
  bne __ai_search_no_white_d_break_0
  lda Board88 + $43
  cmp #EMPTY_PIECE
  bne __ai_search_no_white_d_break_0
  sec
  rts
__ai_search_no_white_d_break_0:
  clc
  rts

;
; RootBlackDPawnBreakAvailable
; Output: Carry set if the home pawn can make a two-square center break.
; Clobbers: A
;
RootBlackDPawnBreakAvailable:
  jsr RootBlackEnemyCenterPawn
  bcc __ai_search_no_black_d_break_0
  lda Board88 + $13
  cmp #BLACK_PAWN
  bne __ai_search_no_black_d_break_0
  lda Board88 + $23
  cmp #EMPTY_PIECE
  bne __ai_search_no_black_d_break_0
  lda Board88 + $33
  cmp #EMPTY_PIECE
  bne __ai_search_no_black_d_break_0
  sec
  rts
__ai_search_no_black_d_break_0:
  clc
  rts

;
; ApplyRootMissedOpeningCenterBreakPenalty
; In the opening, if a home d/e pawn can challenge an enemy d/e center pawn,
; discourage quiet drift. Keep this to the d-pawn break; e-pawn pushes are
; more position-dependent and belong in full search unless tactically forced.
; Input/Output: $eb = root move score from the mover's perspective.
; Clobbers: A, X, attack_sq, attack_color, $f0
;
ApplyRootMissedOpeningCenterBreakPenalty:
  lda NegamaxState + 4
  bmi __ai_search_center_break_done_0
  and #$7f
  sta $f0
  tax
  lda Board88, x
  cmp #EMPTY_PIECE
  bne __ai_search_center_break_done_0

  jsr IsCurrentSideInCheck
  bcs __ai_search_center_break_done_0

  lda SearchSide
  beq __ai_search_black_center_break_0

  jsr RootWhiteDPawnBreakAvailable
  bcc __ai_search_center_break_done_0
  lda NegamaxState + 3
  cmp #$63
  bne __ai_search_penalize_center_break_0
  lda $f0
  cmp #$43
  beq __ai_search_center_break_done_0
  jmp __ai_search_penalize_center_break_0

__ai_search_black_center_break_0:
  jsr RootBlackDPawnBreakAvailable
  bcc __ai_search_center_break_done_0
  lda NegamaxState + 3
  cmp #$13
  bne __ai_search_penalize_center_break_0
  lda $f0
  cmp #$33
  beq __ai_search_center_break_done_0

__ai_search_penalize_center_break_0:
  lda #<ROOT_MISSED_CENTER_BREAK_PENALTY
  ldx #>ROOT_MISSED_CENTER_BREAK_PENALTY
  jmp ApplyRootPenaltyAmount

__ai_search_center_break_done_0:
  rts

;
; RootEarlyQueenPawnRecapture
; Output: Carry set if the root candidate is an early queen capture of an
;         enemy pawn when a friendly pawn can make the same recapture.
;         Carry clear otherwise.
; Clobbers: A, X, Y, $f0-$f3
;
RootEarlyQueenPawnRecapture:
  ldx NegamaxState + 3
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_search_not_queen_recapture_0
  sta $f3
  and #$07
  cmp #QUEEN_TYPE
  bne __ai_search_not_queen_recapture_0

  lda $f3
  and #WHITE_COLOR
  sta $f1

  lda NegamaxState + 4
  and #$7f
  sta $f0
  tax
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_search_not_queen_recapture_0
  sta $f2
  and #$07
  cmp #PAWN_TYPE
  bne __ai_search_not_queen_recapture_0
  lda $f2
  and #WHITE_COLOR
  cmp $f1
  beq __ai_search_not_queen_recapture_0

  jsr SideHasHomeMinor
  bcc __ai_search_not_queen_recapture_0

  lda $f1
  beq __ai_search_black_queen_recapture_0

  lda $f0
  clc
  adc #$0f
  jsr CheckWhitePawnAt
  bcs __ai_search_is_queen_recapture_0
  lda $f0
  clc
  adc #$11
  jsr CheckWhitePawnAt
  bcs __ai_search_is_queen_recapture_0
  clc
  rts

__ai_search_black_queen_recapture_0:
  lda $f0
  sec
  sbc #$0f
  jsr CheckBlackPawnAt
  bcs __ai_search_is_queen_recapture_0
  lda $f0
  sec
  sbc #$11
  jsr CheckBlackPawnAt
  bcs __ai_search_is_queen_recapture_0

__ai_search_not_queen_recapture_0:
  clc
  rts

__ai_search_is_queen_recapture_0:
  sec
  rts

;
; ApplyRootEarlyQueenRecapturePenalty
; Penalize early queen captures of enemy pawns when a friendly pawn can make
; the same recapture. This keeps the queen out of center tempi without exact
; opening memory.
; Input/Output: $eb = root move score from the mover's perspective.
; Clobbers: A, X, Y, $f0-$f3
;
ApplyRootEarlyQueenRecapturePenalty:
  jsr RootEarlyQueenPawnRecapture
  bcc __ai_search_queen_recapture_done_0
  lda #<ROOT_EARLY_QUEEN_MOVE_PENALTY
  ldx #>ROOT_EARLY_QUEEN_MOVE_PENALTY
  jmp ApplyRootPenaltyAmount

__ai_search_queen_recapture_done_0:
  rts

;
; ApplyRootBlockedBishopRecapturePenalty
; In the opening, do not spend a side pawn to recapture an advanced center pawn
; when an undeveloped bishop can recapture the same pawn and develop.
; Input/Output: $eb = root move score from the mover's perspective.
; Clobbers: A, X, Y, $f0
;
ApplyRootBlockedBishopRecapturePenalty:
  lda NegamaxState + 4
  bmi __ai_search_blocked_bishop_exit_0
  and #$7f
  sta $f0
  tax
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_search_blocked_bishop_exit_0
  and #$07
  cmp #PAWN_TYPE
  bne __ai_search_blocked_bishop_exit_0

  lda NegamaxState + 3
  tay
  lda Board88, y
  and #$07
  cmp #PAWN_TYPE
  bne __ai_search_blocked_bishop_exit_0

  lda SearchSide
  beq __ai_search_black_blocked_bishop_recap_0
  jmp __ai_search_white_blocked_bishop_recap_0

__ai_search_blocked_bishop_exit_0:
  jmp __ai_search_blocked_bishop_done_0

__ai_search_white_blocked_bishop_recap_0:
  lda $f0
  cmp #$53
  bne __ai_search_white_check_e3_recap_0
  lda NegamaxState + 3
  cmp #$62
  bne __ai_search_blocked_bishop_done_0
  lda Board88 + $75
  cmp #WHITE_BISHOP
  bne __ai_search_blocked_bishop_done_0
  lda Board88 + $64
  cmp #EMPTY_PIECE
  bne __ai_search_blocked_bishop_done_0
  jmp __ai_search_penalize_blocked_bishop_0

__ai_search_white_check_e3_recap_0:
  cmp #$54
  bne __ai_search_blocked_bishop_done_0
  lda NegamaxState + 3
  cmp #$65
  bne __ai_search_blocked_bishop_done_0
  lda Board88 + $72
  cmp #WHITE_BISHOP
  bne __ai_search_blocked_bishop_done_0
  lda Board88 + $63
  cmp #EMPTY_PIECE
  bne __ai_search_blocked_bishop_done_0
  jmp __ai_search_penalize_blocked_bishop_0

__ai_search_black_blocked_bishop_recap_0:
  lda $f0
  cmp #$23
  bne __ai_search_black_check_e6_recap_0
  lda NegamaxState + 3
  cmp #$12
  bne __ai_search_blocked_bishop_done_0
  lda Board88 + $05
  cmp #BLACK_BISHOP
  bne __ai_search_blocked_bishop_done_0
  lda Board88 + $14
  cmp #EMPTY_PIECE
  bne __ai_search_blocked_bishop_done_0
  jmp __ai_search_penalize_blocked_bishop_0

__ai_search_black_check_e6_recap_0:
  cmp #$24
  bne __ai_search_blocked_bishop_done_0
  lda NegamaxState + 3
  cmp #$15
  bne __ai_search_blocked_bishop_done_0
  lda Board88 + $02
  cmp #BLACK_BISHOP
  bne __ai_search_blocked_bishop_done_0
  lda Board88 + $13
  cmp #EMPTY_PIECE
  bne __ai_search_blocked_bishop_done_0

__ai_search_penalize_blocked_bishop_0:
  lda #<ROOT_BLOCKED_BISHOP_RECAPTURE_PENALTY
  ldx #>ROOT_BLOCKED_BISHOP_RECAPTURE_PENALTY
  jmp ApplyRootPenaltyAmount

__ai_search_blocked_bishop_done_0:
  rts

;
; ApplyRootEarlyQueenPenalty
; Penalize quiet queen moves while home-rank minor pieces are still undeveloped.
; Captures and queen escapes are exempt.
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

  ldx NegamaxState + 2
  jsr RootMoveGivesCheck
  bcs __ai_search_done_7

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

  jsr SideHasHomeMinor
  bcc __ai_search_done_7

  PENALTY16 ROOT_EARLY_QUEEN_MOVE_PENALTY

__ai_search_done_7:
  rts

;
; ApplyRootEarlyKingPenalty
; Penalize non-castling king moves when the side to move is not in check.
; Opening king walks like Kd2 are usually catastrophic; evasions, castling, and
; king escapes under direct queen pressure are exempt.
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

  jsr RootEnemyQueenPressuresKing
  bcs __ai_search_done_8

  PENALTY16 ROOT_EARLY_KING_MOVE_PENALTY

__ai_search_done_8:
  rts

;
; ApplyRootCheckedKingMovePenalty
; In check, prefer blocking/capturing evasions over quiet king walks. If a king
; move is the only viable escape it can still win on search score; this just
; stops shallow search from casually losing castling/coordination.
; Input/Output: $eb = root move score from the mover's perspective.
; Clobbers: A, X
;
ApplyRootCheckedKingMovePenalty:
  ldx NegamaxState + 3
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_search_checked_king_done_0
  and #$07
  cmp #KING_TYPE
  bne __ai_search_checked_king_done_0

  jsr IsCurrentSideInCheck
  bcc __ai_search_checked_king_done_0

  lda NegamaxState + 4
  and #$7f
  tax
  lda Board88, x
  cmp #EMPTY_PIECE
  bne __ai_search_checked_king_done_0

  lda #<ROOT_CHECKED_KING_MOVE_PENALTY
  ldx #>ROOT_CHECKED_KING_MOVE_PENALTY
  jmp ApplyRootPenaltyAmount

__ai_search_checked_king_done_0:
  rts

;
; ApplyRootExposedKingFlankPawnPenalty
; Quiet rook-pawn pushes are rarely urgent after our king has left the back
; rank. This targets Colossus-game pawn storms like a4/a5/h3 while leaving
; captures, promotions, and normal castled/home-rank positions alone.
; Input/Output: $eb = root move score from the mover's perspective.
; Clobbers: A, X, $f1-$f3
;
ApplyRootExposedKingFlankPawnPenalty:
  ldx NegamaxState + 3
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_search_flank_pawn_done_0
  sta $f3
  and #$07
  cmp #PAWN_TYPE
  bne __ai_search_flank_pawn_done_0

  txa
  and #$07
  beq __ai_search_check_flank_pawn_quiet_0
  cmp #$07
  bne __ai_search_flank_pawn_done_0

__ai_search_check_flank_pawn_quiet_0:
  lda NegamaxState + 4
  bmi __ai_search_flank_pawn_done_0
  and #$7f
  tax
  lda Board88, x
  cmp #EMPTY_PIECE
  bne __ai_search_flank_pawn_done_0

  lda $f3
  and #WHITE_COLOR
  beq __ai_search_black_flank_king_0

  lda whitekingsq
  and #$70
  cmp #$70
  beq __ai_search_flank_pawn_done_0
  jmp __ai_search_penalize_flank_pawn_0

__ai_search_black_flank_king_0:
  lda blackkingsq
  and #$70
  cmp #$00
  beq __ai_search_flank_pawn_done_0

__ai_search_penalize_flank_pawn_0:
  lda #<ROOT_EXPOSED_KING_FLANK_PAWN_PENALTY
  ldx #>ROOT_EXPOSED_KING_FLANK_PAWN_PENALTY
  jmp ApplyRootPenaltyAmount

__ai_search_flank_pawn_done_0:
  rts

;
; SideHasHomeMinor
; Output: Carry set if the side to move still has a knight/bishop on its
; starting back rank. Used to scope early major-piece development penalties.
; Clobbers: A
;
SideHasHomeMinor:
  lda SearchSide
  beq __ai_search_black_home_minor_0

  lda Board88 + $71
  cmp #WHITE_KNIGHT
  beq __ai_search_home_minor_found_0
  lda Board88 + $72
  cmp #WHITE_BISHOP
  beq __ai_search_home_minor_found_0
  lda Board88 + $75
  cmp #WHITE_BISHOP
  beq __ai_search_home_minor_found_0
  lda Board88 + $76
  cmp #WHITE_KNIGHT
  beq __ai_search_home_minor_found_0
  clc
  rts

__ai_search_black_home_minor_0:
  lda Board88 + $01
  cmp #BLACK_KNIGHT
  beq __ai_search_home_minor_found_0
  lda Board88 + $02
  cmp #BLACK_BISHOP
  beq __ai_search_home_minor_found_0
  lda Board88 + $05
  cmp #BLACK_BISHOP
  beq __ai_search_home_minor_found_0
  lda Board88 + $06
  cmp #BLACK_KNIGHT
  beq __ai_search_home_minor_found_0
  clc
  rts

__ai_search_home_minor_found_0:
  sec
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

  jsr SideHasHomeMinor
  bcc __ai_search_done_9

__ai_search_penalize_1:
  PENALTY16 ROOT_EARLY_ROOK_MOVE_PENALTY

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

; White to move: black pawns on ranks 1-4 are always urgent. Fifth-rank
; pawns are urgent while the black king is still on the home rank.
  txa
  and #$70
  cmp #$40
  bcs __ai_search_advanced_pawn_yes_0
  cmp #$30
  bne __ai_search_not_advanced_0
  lda blackkingsq
  and #$70
  bne __ai_search_not_advanced_0
__ai_search_advanced_pawn_yes_0:
  sec
  rts

__ai_search_black_to_move_1:
; Black to move: white pawns on ranks 4-8 (rows 0-4) are urgent.
  txa
  and #$70
  cmp #$50
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
  beq __ai_search_advanced_white_list_0
  lda BlackPieceCount
  sta $f2
  lda #<BlackPieceList
  sta temp1
  lda #>BlackPieceList
  sta temp1 + 1
  jmp __ai_search_advanced_list_set_0

__ai_search_advanced_white_list_0:
  lda WhitePieceCount
  sta $f2
  lda #<WhitePieceList
  sta temp1
  lda #>WhitePieceList
  sta temp1 + 1

__ai_search_advanced_list_set_0:
  lda #$00
  sta $f7

__ai_search_scan_loop_3:
  ldy $f7
  cpy $f2
  beq __ai_search_done_10
  lda (temp1), y
  tax
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
  PENALTY16 ROOT_MISSED_ADVANCED_PAWN_PENALTY
  rts

__ai_search_next_square_3:
  inc $f7
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
; Hard recursion ceiling. NegamaxState is MAX_DEPTH*8 bytes indexed by
; SearchDepth*8, and the 6502 hardware stack is only 256 bytes. Check and
; recapture extensions add plies on top of the iterative-deepening depth, so
; a long forcing line could drive SearchDepth past MAX_DEPTH, run the state
; index off its array, and overflow the call stack -- which corrupted memory
; and crashed deep beast searches with a wild RTS into the piece-list code
; (illegal opcode near $097A/$09A0). Treat MAX_DEPTH as an absolute horizon:
; drop to quiescence instead of recursing further.
  ldx SearchDepth
  cpx #MAX_DEPTH
  bcc __ai_search_depth_in_range_0
  ldx #$00
  stx QuiesceDepth
  jmp Quiesce
__ai_search_depth_in_range_0:

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

; Store alpha/beta for this depth (read from entry parameters at $e8/$ed lo/hi
; and $e9/$ee lo/hi). NegamaxState +6/+7 hold the LO bytes; parallel hi arrays
; NegamaxAlphaHi/NegamaxBetaHi (indexed by SearchDepth) hold the HI bytes.
  ldy SearchDepth
  lda $e8
  sta NegamaxState + 6, x; [offset+6] = alpha lo
  lda $ed
  sta NegamaxAlphaHi, y; alpha hi
  lda $e9
  sta NegamaxState + 7, x; [offset+7] = beta lo
  lda $ee
  sta NegamaxBetaHi, y; beta hi
  lda $e8
  sta NegamaxOrigAlpha, y
  lda $ed
  sta NegamaxOrigAlphaHi, y

; Probe transposition table
  jsr ComputeSearchZobristHash

; Recalculate state offset (ComputeZobristHash clobbers X)
  lda SearchDepth
  asl
  asl
  asl
  tax
  ldy SearchDepth
  lda ZobristHash
  sta NegamaxHashLo, y
  lda ZobristHash + 1
  sta NegamaxHashHi, y

; FIX 2 (in-tree draw detection): for any non-root node, a repetition (on the
; current search path or in the real game history) is a draw. Return DRAW_SCORE
; immediately, WITHOUT a TT store, so a draw verdict never poisons the TT as if
; it were a true positional score. The root (SearchDepth == 0) is exempt: the
; root position itself is never a draw to play into.
  lda SearchDepth
  beq __ai_search_no_intree_draw_0
  jsr CheckInTreeDraw
  bcc __ai_search_no_intree_draw_0
  lda #>DRAW_SCORE
  sta $ec
  lda #<DRAW_SCORE
  rts

__ai_search_no_intree_draw_0:
; Recalculate state offset (CheckInTreeDraw clobbers X).
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

; FIX 1 (mate distance): a stored mate score is ply-absolute. Re-center it onto
; this node's ply BEFORE the bound-usability comparisons and before returning,
; so alpha/beta tests and the returned score are all node-relative. Non-mate
; scores are left untouched. (Clobbers X, recomputed just below.)
  jsr MateProbeAdjust

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

  lda TTScoreHi; Return 16-bit score
  sta $ec
  lda TTScoreLo
  rts

__ai_search_tt_check_alpha_0:
  cmp #TT_FLAG_ALPHA
  bne __ai_search_tt_check_beta_0

; ALPHA upper-bound hit: usable when stored score <= current alpha.
; 16-bit signed compare alpha - score; >=0 means score <= alpha (usable).
  ldy SearchDepth
  lda NegamaxState + 6, x; alpha lo
  sec
  sbc TTScoreLo
  lda NegamaxAlphaHi, y; alpha hi
  sbc TTScoreHi
  bvc __ai_search_tt_alpha_no_ov_0
  eor #$80
__ai_search_tt_alpha_no_ov_0:
  bmi __ai_search_tt_miss_0; alpha < score, cannot use bound
  jmp __ai_search_tt_return_score_0

__ai_search_tt_check_beta_0:
  cmp #TT_FLAG_BETA
  bne __ai_search_tt_miss_0

; BETA lower-bound hit: usable when stored score >= current beta.
; 16-bit signed compare score - beta; >=0 means score >= beta (usable).
  ldy SearchDepth
  lda TTScoreLo
  sec
  sbc NegamaxState + 7, x; beta lo
  lda TTScoreHi
  sbc NegamaxBetaHi, y; beta hi
  bvc __ai_search_tt_beta_no_ov_0
  eor #$80
__ai_search_tt_beta_no_ov_0:
  bmi __ai_search_tt_miss_0; score < beta, cannot use bound

__ai_search_tt_return_score_0:
  lda TTScoreHi
  sta $ec
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
; FIX 1 (mate distance): checkmate terminal returns -(MATE_SCORE - ply) with
; ply = SearchDepth (plies from the root) so nearer mates score harder.
  lda SearchDepth
  jsr LoadMatedScore
  rts

__ai_search_stalemate_0:
  lda #>DRAW_SCORE
  sta $ec
  lda #DRAW_SCORE
  rts

__ai_search_have_moves_0:
; Recalculate state offset (clobbered by IsSquareAttacked path)
  lda SearchDepth
  asl
  asl
  asl
  tax

; FIX 2 (in-tree draw detection): publish THIS node's position hash onto the
; search path before recursing into children. Children at SearchDepth+1 scan
; SearchPathHash[0 .. SearchDepth] and so will see this node as an ancestor.
; Indexing by SearchDepth means each ply overwrites its own slot on entry, so no
; explicit pop is needed -- a sibling subtree simply rewrites the slot. The hash
; was already cached in NegamaxHashLo/Hi[SearchDepth] above.
  ldy SearchDepth
  lda NegamaxHashLo, y
  sta SearchPathHashLo, y
  lda NegamaxHashHi, y
  sta SearchPathHashHi, y

; Initialize best score to -infinity (16-bit $8000)
  ldy SearchDepth
  lda #NEG_INFINITY
  sta NegamaxState + 1, x; [offset+1] = best score lo
  lda #NEG_INFINITY_HI
  sta NegamaxBestHi, y; best score hi

; Clear local best move for this node.
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
  jsr Evaluate; 16-bit static eval: lo in A, hi in $ec
  clc
  adc #<FUTILITY_MARGIN
  sta $f0; static+margin lo
  lda $ec
  adc #>FUTILITY_MARGIN
  sta $f1; static+margin hi

  lda SearchDepth
  asl
  asl
  asl
  tax
  ldy SearchDepth
; (static+margin) - alpha. Enable futility when static+margin <= alpha, i.e.
; when the 16-bit difference is <= 0 (negative or exactly zero).
  lda $f0
  sec
  sbc NegamaxState + 6, x; lo diff
  sta $f4
  lda $f1
  sbc NegamaxAlphaHi, y; hi diff (raw)
  sta $f5
  ora $f4
  beq __ai_search_enable_futility_0; difference == 0 -> static+margin == alpha
  lda $f5
  bvc __ai_search_futility_no_ov_0
  eor #$80
__ai_search_futility_no_ov_0:
  bpl __ai_search_futility_done_0; static+margin > alpha -> no futility

__ai_search_enable_futility_0:
  ldy SearchDepth
  lda #$01
  sta NegamaxFutility, y
  lda NegamaxState + 6, x; Return alpha if every move is futile (16-bit).
  sta NegamaxState + 1, x
  lda NegamaxAlphaHi, y
  sta NegamaxBestHi, y

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

  lda NegamaxState + 2, x
  tax
  jsr IsQuietMoveSearchForcing
  bcc __ai_search_prune_futile_quiet_0
  lda SearchDepth
  asl
  asl
  asl
  tax
  jmp __ai_search_search_current_move_0

__ai_search_prune_futile_quiet_0:
  lda SearchDepth
  asl
  asl
  asl
  tax
  inc NegamaxState + 2, x
  jmp __ai_search_move_loop_0

__ai_search_search_current_move_0:
; Late-move pruning: at shallow non-root nodes, once ordered captures and the
; first quiet tries have failed, skip ordinary quiets that do not create check
; or a major threat. This is stricter than LMR and only fires after a real move
; has already established a node score.
  lda SearchDepth
  beq __ai_search_lmp_done_0
  lda NegamaxState + 5, x
  cmp #LMP_MAX_DEPTH + 1
  bcs __ai_search_lmp_done_0
; best still at -infinity (no real move scored yet)? 16-bit sentinel test.
  lda NegamaxState + 1, x
  cmp #NEG_INFINITY
  bne __ai_search_lmp_not_floor_0
  ldy SearchDepth
  lda NegamaxBestHi, y
  cmp #NEG_INFINITY_HI
  beq __ai_search_lmp_done_0
__ai_search_lmp_not_floor_0:
  lda NegamaxState + 2, x
  cmp #LMP_FULL_MOVES
  bcc __ai_search_lmp_done_0
  lda NegamaxState + 4, x
  bmi __ai_search_lmp_done_0; Promotions search normally.
  and #$7f
  tay
  lda Board88, y
  cmp #EMPTY_PIECE
  bne __ai_search_lmp_done_0; Captures search normally.

  lda NegamaxState + 2, x
  tax
  jsr IsQuietMoveSearchForcing
  bcs __ai_search_lmp_restore_0
  lda SearchDepth
  asl
  asl
  asl
  tax
  inc NegamaxState + 2, x
  jmp __ai_search_move_loop_0

__ai_search_lmp_restore_0:
  lda SearchDepth
  asl
  asl
  asl
  tax

__ai_search_lmp_done_0:
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

  lda NegamaxState + 2, x
  tax
  jsr IsQuietMoveMajorThreat
  bcc __ai_search_lmr_reduce_quiet_0
  lda SearchDepth
  asl
  asl
  asl
  tax
  jmp __ai_search_lmr_done_0

__ai_search_lmr_reduce_quiet_0:
  lda SearchDepth
  asl
  asl
  asl
  tax
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
; alpha == -infinity ($8000)? Then no narrow window is meaningful.
  lda NegamaxState + 6, x
  cmp #NEG_INFINITY
  bne __ai_search_pvs_alpha_not_floor_0
  ldy SearchDepth
  lda NegamaxAlphaHi, y
  cmp #NEG_INFINITY_HI
  beq __ai_search_pvs_full_width_0
__ai_search_pvs_alpha_not_floor_0:
  ldy SearchDepth
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
  jsr TryApplyCheckExtensionAfterMove

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
  bne __ai_search_child_null_window_0
  jmp __ai_search_child_full_window_0

__ai_search_child_null_window_0:
; Null window: child alpha = -(alpha + 1), child beta = -alpha. X = parent
; offset, Y = parent index for the hi arrays.
  lda NegamaxState + 6, x; alpha lo
  clc
  adc #$01
  sta $eb
  lda NegamaxAlphaHi, y; alpha hi
  adc #$00
  sta $ec
; clamp (alpha+1) to +32767 on signed overflow past the top.
  bvc __ai_search_pvs_alpha_plus_one_ok_0
  lda #POS_INFINITY
  sta $eb
  lda #POS_INFINITY_HI
  sta $ec
__ai_search_pvs_alpha_plus_one_ok_0:
  lda $eb
  NEGATE_SCORE_A
  sta $e8; child alpha lo = -(alpha + 1)
  lda $ec
  sta $ed; child alpha hi

  lda NegamaxState + 6, x; alpha lo
  ldy SearchDepth
  dey; parent index for hi array (SearchDepth-1)
  pha
  lda NegamaxAlphaHi, y
  sta $ec
  pla
  NEGATE_SCORE_A
  sta $e9; child beta lo = -alpha
  lda $ec
  sta $ee; child beta hi
  jmp __ai_search_child_window_ready_0

__ai_search_child_full_window_0:
; Full window: child alpha = -beta, child beta = -alpha. X = parent offset.
  ldy SearchDepth
  dey; parent index for hi arrays
  lda NegamaxState + 7, x; beta lo
  pha
  lda NegamaxBetaHi, y
  sta $ec
  pla
  NEGATE_SCORE_A; -beta
  sta $e8; child alpha lo = -beta
  lda $ec
  sta $ed; child alpha hi

  lda NegamaxState + 6, x; alpha lo
  pha
  lda NegamaxAlphaHi, y
  sta $ec
  pla
  NEGATE_SCORE_A; -alpha
  sta $e9; child beta lo = -alpha
  lda $ec
  sta $ee; child beta hi

__ai_search_child_window_ready_0:
  lda SearchDepth
  sec
  sbc #$01; Parent's depth index
  tay
  lda NegamaxChildDepth, y
  jsr Negamax

; Negate score: score = -score
  NEGATE_SCORE_A
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
  bne __ai_search_pvs_check_research_0
  jmp __ai_search_pvs_research_done_0

__ai_search_pvs_research_tramp_0:
  jmp __ai_search_pvs_research_done_0

__ai_search_pvs_check_research_0:
; score > alpha? (16-bit signed: score - alpha > 0)
  ldy SearchDepth
  lda $eb
  sec
  sbc NegamaxState + 6, x
  sta $f0
  lda $ec
  sbc NegamaxAlphaHi, y
  sta $f1
  ora $f0
  beq __ai_search_pvs_research_tramp_0; equal -> not > alpha
  lda $f1
  bvc __ai_search_pvs_cmp_alpha_no_ov_0
  eor #$80
__ai_search_pvs_cmp_alpha_no_ov_0:
  bmi __ai_search_pvs_research_tramp_0

; score < beta? (16-bit signed: score - beta < 0)
  ldy SearchDepth
  lda $eb
  sec
  sbc NegamaxState + 7, x
  sta $f0
  lda $ec
  sbc NegamaxBetaHi, y
  sta $f1
  ora $f0
  beq __ai_search_pvs_research_tramp_0; equal -> not < beta
  lda $f1
  bvc __ai_search_pvs_cmp_beta_no_ov_0
  eor #$80
__ai_search_pvs_cmp_beta_no_ov_0:
  bpl __ai_search_pvs_research_tramp_0

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
; PVS re-search setup is rare; keep the jsr form here so the long branches
; above stay in range. 16-bit: child alpha = -beta, child beta = -alpha.
  ldy SearchDepth
  dey; parent index for hi arrays
  lda NegamaxBetaHi, y
  sta $ec
  lda NegamaxState + 7, x; beta lo
  jsr NegateSearchScore
  sta $e8; child alpha lo = -beta
  lda $ec
  sta $ed; child alpha hi

  ldy SearchDepth
  dey
  lda NegamaxAlphaHi, y
  sta $ec
  lda NegamaxState + 6, x; alpha lo
  jsr NegateSearchScore
  sta $e9; child beta lo = -alpha
  lda $ec
  sta $ee; child beta hi

  lda SearchDepth
  sec
  sbc #$01
  tay
  lda NegamaxChildDepth, y
  jsr Negamax
  NEGATE_SCORE_A
  sta $eb; negated score (hi already in $ec)

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
  jsr ApplyRootAllowsMatePenalty
; EXP1: strip eval-shaping root penalties (test vs native clean-search).
; jsr ApplyRootMajorSafetyPenalty
; jsr ApplyRootHangingQueenPenalty
; jsr ApplyRootQueenDangerPawnPenalty
; jsr ApplyRootQueenPawnRaidPenalty

; FIX 1 (mate distance): the mating root move no longer scores exactly
; +MATE_SCORE (distance is encoded), so test "is a winning mate" =
; score > STATIC_EVAL_LIMIT (16-bit signed). Skip the cosmetic pawn-safety
; penalties for any forced mate.
  lda $eb; score lo - STATIC_EVAL_LIMIT lo
  sec
  sbc #<STATIC_EVAL_LIMIT
  sta $f0
  lda $ec; score hi - STATIC_EVAL_LIMIT hi
  sbc #>STATIC_EVAL_LIMIT
  sta $f1
  ora $f0
  beq __ai_search_root_not_mate_0; diff == 0 -> not strictly greater
  lda $f1
  bvc __ai_search_root_mate_no_ov_0
  eor #$80
__ai_search_root_mate_no_ov_0:
  bpl __ai_search_skip_root_pawn_safety_0; score > STATIC_EVAL_LIMIT -> mate
__ai_search_root_not_mate_0:

; EXP1: strip eval-shaping root penalties (test vs native clean-search).
; jsr ApplyRootPawnSafetyPenalty
; jsr ApplyRootHangingMinorPenalty
; jsr ApplyRootLoosePiecePenalty
; jsr ApplyRootMissedPawnWinPenalty
; jsr ApplyRootMissedCentralPawnKickPenalty
; jsr ApplyRootMissedAdvancedPawnPenalty
; jsr ApplyRootMissedOpeningCenterBreakPenalty
; jsr ApplyRootBlockedBishopRecapturePenalty
; jsr ApplyRootMinorSafetyPenalty
; jsr ApplyRootEarlyQueenRecapturePenalty
; jsr ApplyRootEarlyQueenPenalty
; jsr ApplyRootEarlyRookPenalty
; jsr ApplyRootEarlyKingPenalty
; jsr ApplyRootCheckedKingMovePenalty
; jsr ApplyRootExposedKingFlankPawnPenalty
  jsr ApplyRootLoopPenalty

__ai_search_skip_root_pawn_safety_0:
; Recalculate state offset again
  lda SearchDepth
  asl
  asl
  asl
  tax

; Compare: if score > best, update best (16-bit signed: score - best).
; Equality test first (both bytes), then strict sign test.
  ldy SearchDepth
  lda $eb; score lo
  sec
  sbc NegamaxState + 1, x; score lo - best lo
  sta $f0; lo diff
  lda $ec; score hi
  sbc NegamaxBestHi, y; score hi - best hi
  sta $f1; hi diff (raw, pre V-correction)
  ora $f0
  beq __ai_search_score_not_better_0; both zero -> equal, not better
  lda $f1; raw hi diff
  bvc __ai_search_no_overflow_0
  eor #$80; Flip sign bit for overflow case
__ai_search_no_overflow_0:
  bpl __ai_search_score_better_0; >=0 and not equal -> score > best

__ai_search_score_not_better_0:
  jmp __ai_search_not_better_0

__ai_search_score_better_0:
; Score is better - update best (16-bit).
  lda $eb
  sta NegamaxState + 1, x; update best score lo
  ldy SearchDepth
  lda $ec
  sta NegamaxBestHi, y; update best score hi
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
; FIX 1 (mate distance): the former "first mate found -> return immediately"
; sibling shortcut is INTENTIONALLY removed. With distance encoded, a sibling
; can be a FASTER mate (higher score), so siblings must still be searched. A
; mate score that raises alpha to/above beta will beta-cut through the normal
; alpha-beta path just below, which preserves the speed benefit safely.
__ai_search_not_forced_mate_0:
; Alpha-Beta: if best > alpha, update alpha
; Recalculate state offset (may have been clobbered)
  lda SearchDepth
  asl
  asl
  asl
  tax

; Signed comparison: best > alpha? (16-bit: best - alpha)
  ldy SearchDepth
  lda $eb; best lo (same as score that just improved)
  sec
  sbc NegamaxState + 6, x; best lo - alpha lo
  sta $f0
  lda $ec; best hi
  sbc NegamaxAlphaHi, y; best hi - alpha hi
  sta $f1
  ora $f0
  beq __ai_search_not_better_0; equal -> best <= alpha, no update
  lda $f1
  bvc __ai_search_no_overflow2_0
  eor #$80
__ai_search_no_overflow2_0:
  bmi __ai_search_not_better_0; If negative, best < alpha

; Update alpha = best (16-bit)
  lda $eb
  sta NegamaxState + 6, x
  lda $ec
  sta NegamaxAlphaHi, y

; Alpha-Beta cutoff: if alpha >= beta, prune (16-bit: alpha - beta >= 0)
  lda SearchDepth
  asl
  asl
  asl
  tax
  ldy SearchDepth
  lda NegamaxState + 6, x; alpha lo
  sec
  sbc NegamaxState + 7, x; alpha lo - beta lo
  lda NegamaxAlphaHi, y; alpha hi
  sbc NegamaxBetaHi, y; alpha hi - beta hi
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
  jsr StoreCounterMove

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
  ldy SearchDepth
  lda NegamaxBestHi, y
  sta $ec; return best hi
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
; beyond its original alpha (16-bit signed compare origalpha - best).
  ldy SearchDepth
  lda NegamaxOrigAlpha, y
  sec
  sbc NegamaxState + 1, x; origalpha lo - best lo
  sta $f0
  lda NegamaxOrigAlphaHi, y
  sbc NegamaxBestHi, y; origalpha hi - best hi
  sta $f1
  ora $f0
  beq __ai_search_store_alpha_bound_0; origalpha == best -> fail-low (ALPHA)
  lda $f1
  bvc __ai_search_store_bound_no_ov_0
  eor #$80
__ai_search_store_bound_no_ov_0:
  bmi __ai_search_store_exact_0; origalpha < best -> EXACT

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

; Return best score (16-bit)
  ldy SearchDepth
  lda NegamaxBestHi, y
  sta $ec
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
; Part A: 16-bit score hi-byte parallel arrays, indexed by SearchDepth. The
; NegamaxState +1/+6/+7 fields remain the LO bytes (no stride/offset churn);
; these carry the HI bytes of best/alpha/beta/origalpha.
NegamaxBestHi:
  .res MAX_DEPTH
NegamaxAlphaHi:
  .res MAX_DEPTH
NegamaxBetaHi:
  .res MAX_DEPTH
NegamaxOrigAlphaHi:
  .res MAX_DEPTH
NegamaxHashLo:
  .res MAX_DEPTH
NegamaxHashHi:
  .res MAX_DEPTH
; FIX 2 (in-tree draw detection): search-path hash stack. SearchPathHash[d]
; holds the Zobrist hash of the ancestor node at ply d on the current root->leaf
; path. A child at SearchDepth scans entries [0 .. SearchDepth-1] for a match to
; detect an in-tree repetition (treated as a draw on the FIRST repeat, the
; standard search convention). Two bytes per ply (lo then hi), MAX_DEPTH plies.
SearchPathHashLo:
  .res MAX_DEPTH
SearchPathHashHi:
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
NullMoveScoreHi:
  .res 1
NullStaticEval:
  .res 1
NullStaticEvalHi:
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
  cmp #MAX_DEPTH - 3
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
; TryApplyCheckExtensionAfterMove
; If the just-made move gives check near the horizon, search the child one ply
; deeper. This is bounded and does not stack with recapture extension.
; Call immediately after MakeMove, while SearchDepth is the child ply.
; Clobbers: A, X, Y, $f7, attack_sq, attack_color
;
TryApplyCheckExtensionAfterMove:
  lda SearchDepth
  beq __ai_search_check_ext_done_0
  cmp #MAX_DEPTH - 2
  bcs __ai_search_check_ext_done_0
  tay
  lda RecaptureExtensionUsedByDepth, y
  bne __ai_search_check_ext_done_0

  lda SearchDepth
  sec
  sbc #$01
  sta $f7; parent ply
  asl
  asl
  asl
  tax
  lda NegamaxState + 5, x
  cmp #CHECK_EXTENSION_DEPTH
  bne __ai_search_check_ext_done_0

  jsr IsCurrentSideInCheck
  bcc __ai_search_check_ext_done_0

  ldy $f7
  lda NegamaxChildDepth, y
  clc
  adc #$01
  sta NegamaxChildDepth, y
  inc SearchCheckExtensions

__ai_search_check_ext_done_0:
  rts

;
; Per-depth move-list snapshots
; The move generator uses one global list, and recursive search clobbers it.
; Saving the ordered list once per node is much cheaper than regenerating all
; legal moves after each child returns.
;
.segment "BSS"

MoveListSnapshotCount:
  .res MOVE_LIST_SNAPSHOT_DEPTH
MoveListSnapshotFrom:
  .res MOVE_LIST_SNAPSHOT_DEPTH * MAX_MOVES
MoveListSnapshotTo:
  .res MOVE_LIST_SNAPSHOT_DEPTH * MAX_MOVES

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
; Exact survival rows are disabled. The engine should survive these shapes via
; generic root tactics, mate safety, king pressure, and normal search instead
; of memorized position-specific replies.
;
; Output: Carry clear.
;
TryEngineOpeningSurvivalMove:
  clc
  rts

.if 0
  lda SearchSide
  cmp #WHITE_COLOR
  beq __ai_search_white_to_move_0
  jmp __ai_search_black_to_move_2

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
; check_white_d4_after_colossus_f6
  .byte $28, $63, $43
  .byte $44, WHITE_PAWN, $25, BLACK_PAWN, $15, EMPTY_PIECE, $71, WHITE_KNIGHT
  .byte $76, WHITE_KNIGHT, $73, WHITE_QUEEN, $04, BLACK_KING, $74, WHITE_KING
; check_white_exf5_after_colossus_f5
  .byte $28, $c4, $35
  .byte $43, WHITE_PAWN, $52, WHITE_KNIGHT, $24, BLACK_PAWN, $15, EMPTY_PIECE
  .byte $25, EMPTY_PIECE, $73, WHITE_QUEEN, $04, BLACK_KING, $74, WHITE_KING
; check_white_qh5_after_colossus_nc6
  .byte $a8, $73, $37
  .byte $35, WHITE_PAWN, $22, BLACK_KNIGHT, $24, BLACK_PAWN, $43, WHITE_PAWN
  .byte $52, WHITE_KNIGHT, $05, BLACK_BISHOP, $04, BLACK_KING, $74, WHITE_KING
; check_white_qh5_after_colossus_d5
  .byte $a8, $73, $37
  .byte $24, WHITE_PAWN, $33, BLACK_PAWN, $22, BLACK_KNIGHT, $43, WHITE_PAWN
  .byte $52, WHITE_KNIGHT, $05, BLACK_BISHOP, $04, BLACK_KING, $74, WHITE_KING
; check_white_qe2_before_colossus_castle
  .byte $a8, $73, $64
  .byte $24, BLACK_BISHOP, $25, BLACK_KNIGHT, $31, WHITE_BISHOP, $52, WHITE_KNIGHT
  .byte $55, WHITE_KNIGHT, $43, WHITE_PAWN, $04, BLACK_KING, $74, WHITE_KING
; check_white_qh5_after_colossus_fxe4
  .byte $a8, $73, $37
  .byte $44, BLACK_PAWN, $47, WHITE_KNIGHT, $52, WHITE_KNIGHT, $43, WHITE_PAWN
  .byte $24, BLACK_PAWN, $06, BLACK_KNIGHT, $04, BLACK_KING, $74, WHITE_KING
; check_white_c4_after_colossus_e6_e3
  .byte $28, $62, $42
  .byte $54, WHITE_PAWN, $24, BLACK_PAWN, $71, WHITE_KNIGHT, $76, WHITE_KNIGHT
  .byte $73, WHITE_QUEEN, $03, BLACK_QUEEN, $04, BLACK_KING, $74, WHITE_KING
; check_white_exd4_after_colossus_d4_e3_c4_nc3
  .byte $28, $d4, $43
  .byte $42, WHITE_PAWN, $24, BLACK_PAWN, $13, EMPTY_PIECE, $14, EMPTY_PIECE
  .byte $52, WHITE_KNIGHT, $63, WHITE_PAWN, $73, WHITE_QUEEN, $04, BLACK_KING
; check_white_nf3_after_colossus_nf6_e3_c4_exd4
  .byte $48, $76, $55
  .byte $43, WHITE_PAWN, $42, WHITE_PAWN, $52, WHITE_KNIGHT, $25, BLACK_KNIGHT
  .byte $24, BLACK_PAWN, $13, EMPTY_PIECE, $71, EMPTY_PIECE, $04, BLACK_KING
; check_white_qa4_after_colossus_nc6_e3_c4_exd4_nf3
  .byte $a8, $73, $40
  .byte $43, WHITE_PAWN, $42, WHITE_PAWN, $52, WHITE_KNIGHT, $55, WHITE_KNIGHT
  .byte $22, BLACK_KNIGHT, $25, BLACK_KNIGHT, $24, BLACK_PAWN, $13, EMPTY_PIECE
; check_white_qc2_after_colossus_bd7_e3_line
  .byte $a8, $40, $62
  .byte $13, BLACK_BISHOP, $42, WHITE_PAWN, $43, WHITE_PAWN, $52, WHITE_KNIGHT
  .byte $55, WHITE_KNIGHT, $22, BLACK_KNIGHT, $25, BLACK_KNIGHT, $24, BLACK_PAWN
; check_white_d4_after_colossus_qf6_e3
  .byte $28, $63, $43
  .byte $25, BLACK_QUEEN, $52, WHITE_KNIGHT, $24, BLACK_PAWN, $71, EMPTY_PIECE
  .byte $76, WHITE_KNIGHT, $73, WHITE_QUEEN, $04, BLACK_KING, $74, WHITE_KING
; check_white_c4_after_colossus_f5_nf3
  .byte $28, $62, $42
  .byte $55, WHITE_KNIGHT, $35, BLACK_PAWN, $71, WHITE_KNIGHT, $76, EMPTY_PIECE
  .byte $73, WHITE_QUEEN, $03, BLACK_QUEEN, $04, BLACK_KING, $74, WHITE_KING
; check_white_e3_after_colossus_qd6_f4
  .byte $28, $64, $54
  .byte $23, BLACK_QUEEN, $33, BLACK_PAWN, $45, WHITE_PAWN, $55, WHITE_KNIGHT
  .byte $71, WHITE_KNIGHT, $73, WHITE_QUEEN, $04, BLACK_KING, $74, WHITE_KING
; check_white_e4_after_colossus_e6_c3
  .byte $28, $64, $44
  .byte $52, WHITE_PAWN, $24, BLACK_PAWN, $71, WHITE_KNIGHT, $76, WHITE_KNIGHT
  .byte $73, WHITE_QUEEN, $03, BLACK_QUEEN, $04, BLACK_KING, $74, WHITE_KING
; check_white_bg2_after_colossus_a6_g3
  .byte $68, $75, $66
  .byte $56, WHITE_PAWN, $20, BLACK_PAWN, $10, EMPTY_PIECE, $71, WHITE_KNIGHT
  .byte $76, WHITE_KNIGHT, $73, WHITE_QUEEN, $04, BLACK_KING, $74, WHITE_KING
; check_white_nf3_after_colossus_a6_g3
  .byte $48, $76, $55
  .byte $56, WHITE_PAWN, $20, BLACK_PAWN, $10, EMPTY_PIECE, $71, WHITE_KNIGHT
  .byte $73, WHITE_QUEEN, $03, BLACK_QUEEN, $04, BLACK_KING, $74, WHITE_KING
; check_white_exd6_ep_colossus_advance
  .byte $28, $34, $23
  .byte $33, BLACK_PAWN, $21, BLACK_KNIGHT, $24, BLACK_PAWN, $52, WHITE_KNIGHT
  .byte $55, WHITE_KNIGHT, $42, WHITE_PAWN, $04, BLACK_KING, $74, WHITE_KING
; check_white_bg5_after_rde1_pressure
  .byte $6f, $54, $36
  .byte $45, EMPTY_PIECE, $43, WHITE_KNIGHT, $53, WHITE_QUEEN, $73, WHITE_ROOK
  .byte $75, WHITE_ROOK, $76, WHITE_KING, $03, BLACK_QUEEN, $04, BLACK_ROOK
  .byte $05, BLACK_BISHOP, $06, BLACK_KING, $02, BLACK_BISHOP, $25, BLACK_KNIGHT
  .byte $33, BLACK_PAWN, $26, BLACK_PAWN, $00, BLACK_ROOK
; check_white_bxd4_in_qc7_pressure
  .byte $68, $54, $43
  .byte $55, WHITE_KNIGHT, $53, WHITE_QUEEN, $33, BLACK_PAWN, $12, BLACK_QUEEN
  .byte $14, BLACK_BISHOP, $25, BLACK_KNIGHT, $04, BLACK_ROOK, $06, BLACK_KING
; check_white_nd3_against_qd2_mate_net
  .byte $46, $34, $53
  .byte $63, BLACK_QUEEN, $74, WHITE_ROOK, $55, WHITE_ROOK, $45, BLACK_PAWN
  .byte $47, BLACK_PAWN, $76, WHITE_KING
; check_white_rd4_against_qb2_mate_net
  .byte $85, $73, $43
  .byte $61, BLACK_QUEEN, $32, BLACK_BISHOP, $63, EMPTY_PIECE, $53, EMPTY_PIECE
  .byte $75, WHITE_KING
; check_white_nd2_against_back_rank_queen_trap
  .byte $46, $63, $55
  .byte $72, BLACK_QUEEN, $30, BLACK_BISHOP, $46, BLACK_BISHOP, $53, BLACK_PAWN
  .byte $74, WHITE_BISHOP, $75, WHITE_KING
; check_white_nd2_against_rook_knight_mate_net
  .byte $46, $71, $63
  .byte $73, BLACK_ROOK, $67, BLACK_KNIGHT, $56, WHITE_KING, $46, BLACK_KNIGHT
  .byte $22, BLACK_BISHOP, $64, WHITE_KNIGHT
; check_white_rd1_against_queen_rook_mate_net
  .byte $86, $74, $73
  .byte $65, BLACK_QUEEN, $46, BLACK_ROOK, $77, WHITE_KING, $11, WHITE_QUEEN
  .byte $27, BLACK_KNIGHT, $05, BLACK_BISHOP
; check_white_nxc6_against_double_knight_mate_net
  .byte $46, $cb, $22
  .byte $47, WHITE_KING, $46, BLACK_KNIGHT, $75, BLACK_KNIGHT, $16, BLACK_BISHOP
  .byte $03, BLACK_ROOK, $04, BLACK_KING
; check_white_nd4_against_rook_knight_net
  .byte $46, $64, $43
  .byte $67, BLACK_KNIGHT, $46, BLACK_KNIGHT, $56, WHITE_KING, $22, BLACK_BISHOP
  .byte $32, WHITE_PAWN, $05, BLACK_BISHOP
; check_white_qxd3_against_center_knight
  .byte $a5, $7b, $53
  .byte $33, WHITE_KNIGHT, $51, WHITE_KNIGHT, $16, BLACK_BISHOP, $03, BLACK_QUEEN
  .byte $76, WHITE_KING
; check_white_qf3_against_re8_bg7_d5
  .byte $a5, $73, $55
  .byte $33, BLACK_PAWN, $16, BLACK_BISHOP, $04, BLACK_ROOK, $63, WHITE_KNIGHT
  .byte $76, WHITE_KING
; check_white_nd2_against_early_na5_c5
  .byte $46, $71, $63
  .byte $30, BLACK_KNIGHT, $32, BLACK_PAWN, $34, BLACK_PAWN, $42, WHITE_BISHOP
  .byte $64, WHITE_KNIGHT, $03, BLACK_QUEEN
; check_white_nf4_against_d3_wedge
  .byte $46, $64, $45
  .byte $53, BLACK_PAWN, $44, WHITE_PAWN, $52, WHITE_PAWN, $22, BLACK_KNIGHT
  .byte $03, BLACK_QUEEN, $04, BLACK_KING
; check_white_qf3_against_d3_e5
  .byte $a7, $73, $55
  .byte $53, BLACK_PAWN, $56, WHITE_KNIGHT, $34, BLACK_PAWN, $44, WHITE_PAWN
  .byte $52, WHITE_PAWN, $22, BLACK_KNIGHT, $04, BLACK_KING
; check_white_nh5_against_h5_d3
  .byte $27, $60, $50
  .byte $56, WHITE_KNIGHT, $37, BLACK_PAWN, $53, BLACK_PAWN, $42, WHITE_PAWN
  .byte $44, WHITE_PAWN, $34, BLACK_PAWN, $41, EMPTY_PIECE
; check_white_qb3_against_nb4_d3
  .byte $a7, $73, $51
  .byte $41, BLACK_KNIGHT, $53, BLACK_PAWN, $42, WHITE_PAWN, $44, WHITE_PAWN
  .byte $55, WHITE_KNIGHT, $56, WHITE_KNIGHT, $37, BLACK_PAWN
; check_white_ne2_against_qd3_pressure
  .byte $45, $56, $64
  .byte $53, BLACK_QUEEN, $41, BLACK_KNIGHT, $55, WHITE_KNIGHT, $42, WHITE_PAWN
  .byte $44, WHITE_PAWN
; check_white_b3_against_qc2
  .byte $26, $65, $55
  .byte $62, BLACK_QUEEN, $34, WHITE_KNIGHT, $42, WHITE_PAWN, $44, WHITE_PAWN
  .byte $56, WHITE_KNIGHT, $37, BLACK_PAWN
; check_white_ne2_against_early_d4_push
  .byte $47, $52, $64
  .byte $43, BLACK_PAWN, $44, WHITE_PAWN, $01, BLACK_KNIGHT, $06, BLACK_KNIGHT
  .byte $03, BLACK_QUEEN, $04, BLACK_KING, $74, WHITE_KING
; check_white_nc2_after_scandi_bishop_pin
  .byte $4c, $50, $62
  .byte $43, BLACK_PAWN, $46, BLACK_BISHOP, $44, WHITE_PAWN, $55, WHITE_KNIGHT
  .byte $52, WHITE_PAWN, $20, BLACK_PAWN, $22, BLACK_KNIGHT, $03, BLACK_QUEEN
  .byte $04, BLACK_KING, $05, BLACK_BISHOP, $06, BLACK_KNIGHT, $74, WHITE_KING
; check_white_e5_against_c5_d4_nf6
  .byte $26, $44, $34
  .byte $43, BLACK_PAWN, $32, BLACK_PAWN, $25, BLACK_KNIGHT, $52, WHITE_PAWN
  .byte $55, WHITE_KNIGHT, $04, BLACK_KING
; check_white_na3_after_nb5_e5_d4
  .byte $47, $31, $50
  .byte $34, BLACK_PAWN, $43, BLACK_PAWN, $55, WHITE_KNIGHT, $52, WHITE_PAWN
  .byte $20, BLACK_PAWN, $22, BLACK_KNIGHT, $74, WHITE_KING
; check_white_nb5xd4_after_a6_c3
  .byte $48, $b1, $43
  .byte $55, EMPTY_PIECE, $52, WHITE_PAWN, $44, WHITE_PAWN, $63, WHITE_PAWN
  .byte $20, BLACK_PAWN, $22, BLACK_KNIGHT, $74, WHITE_KING, $04, BLACK_KING
; check_white_initial_e4
  .byte $29, $64, $44
  .byte $74, WHITE_KING, $73, WHITE_QUEEN, $71, WHITE_KNIGHT, $76, WHITE_KNIGHT
  .byte $04, BLACK_KING, $03, BLACK_QUEEN, $12, BLACK_PAWN, $13, BLACK_PAWN
  .byte $14, BLACK_PAWN
; check_white_c3_after_sicilian_c5
  .byte $28, $62, $52
  .byte $32, BLACK_PAWN, $12, EMPTY_PIECE, $44, WHITE_PAWN, $64, EMPTY_PIECE
  .byte $76, WHITE_KNIGHT, $74, WHITE_KING, $04, BLACK_KING, $13, BLACK_PAWN
; check_white_d4_after_sicilian_c3
  .byte $26, $63, $43
  .byte $32, BLACK_PAWN, $44, WHITE_PAWN, $52, WHITE_PAWN, $64, EMPTY_PIECE
  .byte $74, WHITE_KING, $04, BLACK_KING
; check_white_e5_after_alapin_e6
  .byte $27, $44, $34
  .byte $32, EMPTY_PIECE, $22, BLACK_KNIGHT, $33, BLACK_PAWN, $24, BLACK_PAWN
  .byte $43, WHITE_PAWN, $52, WHITE_KNIGHT, $04, BLACK_KING
; check_white_e5_in_qp_c6_e6
  .byte $29, $44, $34
  .byte $22, BLACK_PAWN, $13, BLACK_KNIGHT, $24, BLACK_PAWN, $33, BLACK_PAWN
  .byte $43, WHITE_PAWN, $52, WHITE_KNIGHT, $55, WHITE_KNIGHT, $74, WHITE_KING
  .byte $04, BLACK_KING
; check_white_ne5_after_qp_dxc4_bf5
  .byte $47, $55, $34
  .byte $42, BLACK_PAWN, $35, BLACK_BISHOP, $52, WHITE_KNIGHT, $43, WHITE_PAWN
  .byte $25, BLACK_KNIGHT, $74, WHITE_KING, $04, BLACK_KING
; check_white_e3_after_qp_ne5_a6
  .byte $28, $64, $54
  .byte $34, WHITE_KNIGHT, $42, BLACK_PAWN, $35, BLACK_BISHOP, $25, BLACK_KNIGHT
  .byte $20, BLACK_PAWN, $52, WHITE_KNIGHT, $43, WHITE_PAWN, $04, BLACK_KING
; check_white_qf3_after_qp_nbd7
  .byte $a9, $73, $55
  .byte $34, WHITE_KNIGHT, $13, BLACK_KNIGHT, $42, BLACK_PAWN, $35, BLACK_BISHOP
  .byte $54, WHITE_PAWN, $52, WHITE_KNIGHT, $43, WHITE_PAWN, $20, BLACK_PAWN
  .byte $04, BLACK_KING
; check_white_dxe5_after_qp_nxe5
  .byte $28, $4b, $34
  .byte $64, WHITE_BISHOP, $42, BLACK_PAWN, $35, BLACK_BISHOP, $54, WHITE_PAWN
  .byte $52, WHITE_KNIGHT, $25, BLACK_KNIGHT, $20, BLACK_PAWN, $74, WHITE_KING
; check_white_qxa6_after_qp_rb8
  .byte $a9, $91, $20
  .byte $01, BLACK_ROOK, $34, BLACK_KNIGHT, $45, WHITE_PAWN, $42, BLACK_PAWN
  .byte $54, WHITE_BISHOP, $52, WHITE_KNIGHT, $26, BLACK_BISHOP, $04, BLACK_KING
  .byte $74, WHITE_KING
; check_white_bxd3_after_qp_nd3_check
  .byte $69, $7d, $53
  .byte $20, WHITE_QUEEN, $34, EMPTY_PIECE, $45, WHITE_PAWN, $42, BLACK_PAWN
  .byte $54, WHITE_BISHOP, $52, WHITE_KNIGHT, $26, BLACK_BISHOP, $04, BLACK_KING
  .byte $74, WHITE_KING
; check_white_rd2_after_qp_qc8
  .byte $88, $73, $63
  .byte $53, WHITE_QUEEN, $54, WHITE_BISHOP, $52, WHITE_KNIGHT, $44, WHITE_PAWN
  .byte $45, WHITE_PAWN, $02, BLACK_QUEEN, $23, BLACK_BISHOP, $26, BLACK_BISHOP
; check_white_h4_after_qp_castles
  .byte $28, $67, $47
  .byte $63, WHITE_ROOK, $53, WHITE_QUEEN, $54, WHITE_BISHOP, $52, WHITE_KNIGHT
  .byte $44, WHITE_PAWN, $45, WHITE_PAWN, $02, BLACK_QUEEN, $06, BLACK_KING
; check_white_g4_after_qp_h5
  .byte $2b, $66, $46
  .byte $37, BLACK_PAWN, $47, WHITE_PAWN, $63, WHITE_ROOK, $53, WHITE_QUEEN
  .byte $54, WHITE_BISHOP, $52, WHITE_KNIGHT, $02, BLACK_QUEEN, $06, BLACK_KING
  .byte $45, WHITE_PAWN, $26, BLACK_BISHOP, $23, BLACK_BISHOP
; check_white_c3_after_qp_nb5_h6
  .byte $2b, $62, $52
  .byte $31, WHITE_KNIGHT, $32, BLACK_PAWN, $33, BLACK_PAWN, $34, WHITE_PAWN
  .byte $13, BLACK_KNIGHT, $22, BLACK_KNIGHT, $24, BLACK_PAWN, $27, BLACK_PAWN
  .byte $53, WHITE_BISHOP, $55, WHITE_KNIGHT, $76, WHITE_KING
; check_white_bb1_after_qp_c4
  .byte $65, $db, $79
  .byte $52, WHITE_PAWN, $42, BLACK_PAWN, $31, WHITE_KNIGHT, $33, BLACK_PAWN
  .byte $76, WHITE_KING
; check_white_bxc4_after_qp_nxe4
  .byte $68, $f5, $42
  .byte $35, BLACK_BISHOP, $44, BLACK_KNIGHT, $52, WHITE_KNIGHT, $55, WHITE_KNIGHT
  .byte $43, WHITE_PAWN, $64, EMPTY_PIECE, $53, EMPTY_PIECE, $04, BLACK_KING
; check_white_qa4_after_qp_ne5_nxe4
  .byte $a8, $73, $40
  .byte $44, BLACK_KNIGHT, $34, WHITE_KNIGHT, $42, BLACK_PAWN, $35, BLACK_BISHOP
  .byte $52, WHITE_KNIGHT, $43, WHITE_PAWN, $20, BLACK_PAWN, $04, BLACK_KING
; check_white_nf3_after_e5
  .byte $45, $76, $55
  .byte $44, WHITE_PAWN, $34, BLACK_PAWN, $74, WHITE_KING, $04, BLACK_KING
  .byte $13, BLACK_PAWN
; check_white_bb5_after_e4_e5_nf3_nc6
  .byte $67, $75, $31
  .byte $44, WHITE_PAWN, $34, BLACK_PAWN, $55, WHITE_KNIGHT, $22, BLACK_KNIGHT
  .byte $13, BLACK_PAWN, $74, WHITE_KING, $04, BLACK_KING
; check_white_nd5_after_ruy_nge7_ng6_bc5
  .byte $49, $52, $33
  .byte $40, WHITE_BISHOP, $32, BLACK_BISHOP, $26, BLACK_KNIGHT, $22, BLACK_KNIGHT
  .byte $34, BLACK_PAWN, $20, BLACK_PAWN, $76, WHITE_KING, $75, WHITE_ROOK
  .byte $04, BLACK_KING
; check_white_c3_after_ruy_nd5_castles
  .byte $2b, $62, $52
  .byte $33, WHITE_KNIGHT, $06, BLACK_KING, $05, BLACK_ROOK, $32, BLACK_BISHOP
  .byte $26, BLACK_KNIGHT, $22, BLACK_KNIGHT, $34, BLACK_PAWN, $40, WHITE_BISHOP
  .byte $76, WHITE_KING, $75, WHITE_ROOK, $04, EMPTY_PIECE
; check_white_h3_after_ruy_d4_ba7
  .byte $2b, $67, $57
  .byte $33, WHITE_KNIGHT, $43, WHITE_PAWN, $52, WHITE_PAWN, $10, BLACK_BISHOP
  .byte $23, BLACK_PAWN, $06, BLACK_KING, $05, BLACK_ROOK, $26, BLACK_KNIGHT
  .byte $22, BLACK_KNIGHT, $40, WHITE_BISHOP, $76, WHITE_KING
; check_white_d4_after_philidor_d6
  .byte $26, $63, $43
  .byte $44, WHITE_PAWN, $34, BLACK_PAWN, $55, WHITE_KNIGHT, $23, BLACK_PAWN
  .byte $74, WHITE_KING, $04, BLACK_KING
; check_white_nxd4_before_queen_recapture
  .byte $44, $d5, $43
  .byte $63, EMPTY_PIECE, $73, WHITE_QUEEN, $74, WHITE_KING, $04, BLACK_KING
; check_white_bd3_after_philidor_nf6
  .byte $65, $75, $53
  .byte $43, WHITE_KNIGHT, $25, BLACK_KNIGHT, $23, BLACK_PAWN, $73, WHITE_QUEEN
  .byte $04, BLACK_KING
; check_white_nf3_before_castling
  .byte $46, $43, $55
  .byte $53, WHITE_BISHOP, $32, BLACK_PAWN, $23, BLACK_PAWN, $25, BLACK_KNIGHT
  .byte $44, WHITE_PAWN, $74, WHITE_KING
; check_white_nd2_before_qp_castling
  .byte $49, $55, $63
  .byte $41, BLACK_BISHOP, $44, WHITE_BISHOP, $54, WHITE_BISHOP, $52, WHITE_KNIGHT
  .byte $25, BLACK_KNIGHT, $13, BLACK_KNIGHT, $22, BLACK_PAWN, $24, BLACK_PAWN
  .byte $74, WHITE_KING
; check_white_d5_in_qp_bishop_pin
  .byte $28, $43, $33
  .byte $36, WHITE_BISHOP, $42, WHITE_BISHOP, $52, WHITE_KNIGHT, $55, WHITE_QUEEN
  .byte $13, BLACK_KNIGHT, $25, BLACK_KNIGHT, $22, BLACK_PAWN, $24, BLACK_PAWN
; check_white_bxf6_in_rook_file_line
  .byte $66, $3e, $25
  .byte $11, WHITE_PAWN, $45, WHITE_QUEEN, $23, BLACK_KNIGHT, $14, BLACK_BISHOP
  .byte $01, BLACK_ROOK, $73, WHITE_ROOK
; check_white_qd3_after_center_queen
  .byte $a2, $43, $53
  .byte $44, WHITE_PAWN, $22, BLACK_KNIGHT
; check_white_qxd5_after_qd3_d5
  .byte $a3, $d3, $33
  .byte $43, EMPTY_PIECE, $44, WHITE_PAWN, $22, BLACK_KNIGHT
; check_white_nf5_against_g6_pressure
  .byte $4b, $43, $35
  .byte $51, WHITE_BISHOP, $22, BLACK_KNIGHT, $23, BLACK_BISHOP, $26, BLACK_KNIGHT
  .byte $31, BLACK_PAWN, $20, BLACK_PAWN, $03, BLACK_QUEEN, $04, BLACK_KING
  .byte $75, WHITE_ROOK, $76, WHITE_KING, $44, WHITE_PAWN
; check_white_bg5_before_nxg7_tactic
  .byte $4a, $b5, $16
  .byte $04, BLACK_KING, $14, BLACK_KNIGHT
  .byte $26, BLACK_KNIGHT, $51, BLACK_BISHOP, $75, WHITE_ROOK, $76, WHITE_KING
  .byte $73, WHITE_QUEEN, $34, WHITE_PAWN, $44, WHITE_PAWN, $07, BLACK_ROOK
; check_white_qd5_after_nxg7_pressure
  .byte $ab, $73, $33
  .byte $16, WHITE_KNIGHT, $05, BLACK_KING, $14, BLACK_BISHOP, $26, BLACK_KNIGHT
  .byte $22, BLACK_KNIGHT, $34, WHITE_PAWN, $45, WHITE_PAWN, $51, WHITE_BISHOP
  .byte $75, WHITE_ROOK, $76, WHITE_KING, $03, BLACK_QUEEN
; check_white_qxf7_after_qd5_pressure
  .byte $ab, $b3, $15
  .byte $16, BLACK_KING, $14, BLACK_BISHOP, $26, BLACK_KNIGHT, $22, BLACK_KNIGHT
  .byte $31, BLACK_PAWN, $34, WHITE_PAWN, $45, WHITE_PAWN, $51, WHITE_BISHOP
  .byte $75, WHITE_ROOK, $76, WHITE_KING, $03, BLACK_QUEEN
; check_white_fxg6_after_qxf7_queen_check
  .byte $2b, $3d, $26
  .byte $27, BLACK_KING, $36, BLACK_QUEEN, $15, WHITE_QUEEN, $34, WHITE_PAWN
  .byte $51, WHITE_BISHOP, $75, WHITE_ROOK, $76, WHITE_KING, $22, BLACK_KNIGHT
  .byte $31, BLACK_PAWN, $00, BLACK_ROOK, $02, BLACK_BISHOP
; check_white_kh1_after_qd6_qe3_pressure
  .byte $cb, $76, $77
  .byte $23, WHITE_QUEEN, $54, BLACK_QUEEN, $27, BLACK_KING, $44, WHITE_KNIGHT
  .byte $51, WHITE_BISHOP, $75, WHITE_ROOK, $34, BLACK_KNIGHT, $11, BLACK_BISHOP
  .byte $20, BLACK_PAWN, $22, BLACK_PAWN, $31, BLACK_PAWN
; check_white_a3_after_kh1_qxe4_pressure
  .byte $2c, $60, $50
  .byte $77, WHITE_KING, $23, WHITE_QUEEN, $44, BLACK_QUEEN, $27, BLACK_KING
  .byte $34, BLACK_KNIGHT, $51, WHITE_BISHOP, $70, WHITE_ROOK, $75, WHITE_ROOK
  .byte $11, BLACK_BISHOP, $20, BLACK_PAWN, $22, BLACK_PAWN, $31, BLACK_PAWN
; check_white_bf7_after_raf8_pressure
  .byte $70, $51, $15
  .byte $42, EMPTY_PIECE, $33, EMPTY_PIECE, $24, EMPTY_PIECE, $77, WHITE_KING
  .byte $23, WHITE_QUEEN, $44, BLACK_QUEEN, $27, BLACK_KING, $34, BLACK_KNIGHT
  .byte $74, WHITE_ROOK, $75, WHITE_ROOK, $05, BLACK_ROOK, $07, BLACK_ROOK
  .byte $11, BLACK_BISHOP, $20, BLACK_PAWN, $22, BLACK_PAWN, $31, BLACK_PAWN
; check_white_rf4_after_qd2_kg7_pressure
  .byte $90, $75, $45
  .byte $65, EMPTY_PIECE, $55, EMPTY_PIECE, $77, WHITE_KING, $63, WHITE_QUEEN
  .byte $44, BLACK_QUEEN, $16, BLACK_KING, $34, BLACK_KNIGHT, $51, WHITE_BISHOP
  .byte $70, WHITE_ROOK, $50, WHITE_PAWN, $00, BLACK_ROOK, $07, BLACK_ROOK
  .byte $11, BLACK_BISHOP, $31, BLACK_PAWN, $32, BLACK_PAWN, $26, BLACK_PAWN
; check_white_bb5_after_queen_trade_nb4
  .byte $65, $75, $31
  .byte $41, BLACK_KNIGHT, $33, WHITE_PAWN, $64, EMPTY_PIECE, $53, EMPTY_PIECE
  .byte $42, EMPTY_PIECE
; check_white_kd1_after_queen_trade_fork
  .byte $c4, $74, $73
  .byte $13, BLACK_KING, $41, BLACK_KNIGHT, $33, WHITE_PAWN, $71, WHITE_KNIGHT
; check_white_nxd4_after_qc7_d4
  .byte $45, $d5, $43
  .byte $12, BLACK_QUEEN, $42, WHITE_BISHOP, $63, WHITE_KNIGHT, $74, WHITE_KING
  .byte $73, WHITE_QUEEN
; check_white_qe2_in_queens_pawn_pressure
  .byte $a8, $73, $64
  .byte $12, BLACK_QUEEN, $32, BLACK_BISHOP, $13, BLACK_KNIGHT, $25, BLACK_KNIGHT
  .byte $42, WHITE_BISHOP, $55, WHITE_KNIGHT, $63, WHITE_KNIGHT, $76, WHITE_KING
; check_white_bg5_in_queens_pawn_development
  .byte $6b, $72, $36
  .byte $03, BLACK_QUEEN, $25, BLACK_KNIGHT, $22, BLACK_PAWN, $24, BLACK_PAWN
  .byte $43, WHITE_PAWN, $42, WHITE_BISHOP, $52, WHITE_KNIGHT, $55, WHITE_QUEEN
  .byte $63, EMPTY_PIECE, $54, EMPTY_PIECE, $45, EMPTY_PIECE
; check_white_nc3_after_qd3_nf6
  .byte $44, $71, $52
  .byte $53, WHITE_QUEEN, $44, WHITE_PAWN, $22, BLACK_KNIGHT, $25, BLACK_KNIGHT
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
; check_white_bc3_colossus_deep_queen_rook_net
  .byte $68, $74, $52
  .byte $73, BLACK_QUEEN, $56, WHITE_KING, $35, WHITE_KNIGHT, $05, BLACK_ROOK
  .byte $25, BLACK_ROOK, $13, BLACK_BISHOP, $07, BLACK_KING, $21, BLACK_KNIGHT
; check_white_bxc4_colossus_queen_rook_net
  .byte $68, $f5, $42
  .byte $73, BLACK_QUEEN, $56, WHITE_KING, $35, WHITE_KNIGHT, $05, BLACK_ROOK
  .byte $25, BLACK_ROOK, $13, BLACK_BISHOP, $07, BLACK_KING, $21, BLACK_KNIGHT
; check_white_nf3_colossus_double_bishop_net
  .byte $48, $47, $55
  .byte $33, BLACK_QUEEN, $05, BLACK_ROOK, $25, BLACK_ROOK, $51, BLACK_KNIGHT
  .byte $54, WHITE_BISHOP, $56, WHITE_KNIGHT, $13, BLACK_BISHOP, $14, BLACK_BISHOP
; check_white_rh3_colossus_b3_bishop_net
  .byte $88, $77, $57
  .byte $33, BLACK_QUEEN, $05, BLACK_ROOK, $25, BLACK_ROOK, $23, BLACK_BISHOP
  .byte $13, BLACK_BISHOP, $51, BLACK_KNIGHT, $54, WHITE_BISHOP, $56, WHITE_KNIGHT
; check_white_ke1_colossus_b3_knight_net
  .byte $c8, $64, $74
  .byte $33, BLACK_QUEEN, $05, BLACK_ROOK, $25, BLACK_ROOK, $51, BLACK_KNIGHT
  .byte $54, WHITE_BISHOP, $56, WHITE_KNIGHT, $73, WHITE_QUEEN, $07, BLACK_KING
; check_white_nf3_colossus_bishop_capture_net
  .byte $48, $47, $55
  .byte $33, BLACK_QUEEN, $05, BLACK_ROOK, $25, BLACK_ROOK, $45, BLACK_BISHOP
  .byte $51, BLACK_KNIGHT, $64, WHITE_KING, $65, WHITE_BISHOP, $56, WHITE_KNIGHT
; check_white_qc2_colossus_center_pin
  .byte $a8, $73, $62
  .byte $33, BLACK_QUEEN, $41, BLACK_BISHOP, $21, BLACK_KNIGHT, $22, BLACK_KNIGHT
  .byte $44, WHITE_KNIGHT, $54, WHITE_BISHOP, $64, WHITE_KING, $06, BLACK_KING
; check_white_rh5_colossus_late_queen_rook_net
  .byte $88, $77, $37
  .byte $33, BLACK_QUEEN, $25, BLACK_ROOK, $51, BLACK_KNIGHT, $54, WHITE_BISHOP
  .byte $55, WHITE_KNIGHT, $56, WHITE_KNIGHT, $64, WHITE_KING, $16, BLACK_KING
; check_white_ke1_colossus_double_knight_net
  .byte $c8, $64, $74
  .byte $33, BLACK_QUEEN, $25, BLACK_ROOK, $21, BLACK_KNIGHT, $22, BLACK_KNIGHT
  .byte $54, WHITE_BISHOP, $55, WHITE_KNIGHT, $56, WHITE_KNIGHT, $06, BLACK_KING
; check_white_rf3_after_qxf7_attack
  .byte $8b, $75, $55
  .byte $15, WHITE_QUEEN, $27, BLACK_KING, $36, BLACK_BISHOP, $34, WHITE_PAWN
  .byte $35, WHITE_PAWN, $51, WHITE_BISHOP, $72, WHITE_BISHOP, $26, BLACK_KNIGHT
  .byte $22, BLACK_KNIGHT, $00, BLACK_ROOK, $07, BLACK_ROOK
; check_white_cxb5_full_ladder_center
  .byte $2b, $c2, $31
  .byte $02, BLACK_BISHOP, $03, BLACK_QUEEN, $05, BLACK_ROOK, $06, BLACK_KING
  .byte $13, BLACK_KNIGHT, $20, BLACK_ROOK, $33, WHITE_BISHOP, $55, WHITE_KNIGHT
  .byte $56, WHITE_KNIGHT, $73, WHITE_QUEEN, $76, WHITE_KING
; check_white_qd5_against_b4_queen_pressure
  .byte $a7, $73, $33
  .byte $00, BLACK_ROOK, $05, BLACK_ROOK, $34, BLACK_KNIGHT, $41, BLACK_QUEEN
  .byte $54, WHITE_BISHOP, $60, WHITE_ROOK, $75, WHITE_ROOK
; check_white_b5_rook_endgame
  .byte $29, $41, $31
  .byte $16, BLACK_KING, $34, BLACK_BISHOP, $44, WHITE_KNIGHT, $50, BLACK_ROOK
  .byte $57, WHITE_PAWN, $66, WHITE_KING, $32, WHITE_PAWN, $36, WHITE_PAWN
  .byte $74, WHITE_ROOK
; check_white_ra7_active_rook_endgame
  .byte $8a, $93, $10
  .byte $16, BLACK_KING, $34, BLACK_BISHOP, $44, BLACK_ROOK, $66, WHITE_KING
  .byte $32, WHITE_PAWN, $36, WHITE_PAWN, $37, BLACK_PAWN, $41, WHITE_PAWN
  .byte $47, WHITE_PAWN, $14, BLACK_PAWN
; check_white_kh3_rook_endgame
  .byte $c8, $66, $57
  .byte $16, BLACK_KING, $34, BLACK_BISHOP, $61, BLACK_ROOK, $64, WHITE_ROOK
  .byte $32, WHITE_PAWN, $36, WHITE_PAWN, $37, BLACK_PAWN, $47, WHITE_PAWN
; check_white_qd3_against_selfplay_queen_net
  .byte $a9, $73, $53
  .byte $54, BLACK_QUEEN, $24, BLACK_BISHOP, $34, BLACK_BISHOP, $42, WHITE_BISHOP
  .byte $44, WHITE_KNIGHT, $66, WHITE_KING, $70, WHITE_ROOK, $75, WHITE_ROOK
  .byte $04, BLACK_KING
; check_white_ke1_against_forced_queen_bishop_mate
  .byte $c8, $65, $74
  .byte $53, BLACK_QUEEN, $43, BLACK_BISHOP, $70, WHITE_ROOK, $77, WHITE_ROOK
  .byte $36, WHITE_PAWN, $50, WHITE_PAWN, $57, WHITE_PAWN, $04, BLACK_KING
; check_white_rad1_against_open_d_file_pressure
  .byte $89, $70, $73
  .byte $03, BLACK_ROOK, $05, BLACK_ROOK, $06, BLACK_KING, $34, BLACK_BISHOP
  .byte $22, BLACK_PAWN, $32, WHITE_PAWN, $44, WHITE_KNIGHT, $66, WHITE_KING
  .byte $75, WHITE_ROOK
; check_white_h3_against_qa2_pressure
  .byte $27, $67, $57
  .byte $60, BLACK_QUEEN, $74, WHITE_ROOK, $76, WHITE_KING, $34, WHITE_KNIGHT
  .byte $45, WHITE_BISHOP, $42, WHITE_PAWN, $43, WHITE_PAWN
; check_white_nxe5_after_qxb2_bishop_trade
  .byte $4a, $c2, $34
  .byte $52, WHITE_PAWN, $44, WHITE_PAWN, $20, BLACK_PAWN, $22, BLACK_PAWN
  .byte $03, BLACK_QUEEN, $04, BLACK_KING, $05, BLACK_BISHOP, $06, BLACK_KNIGHT
  .byte $74, WHITE_KING, $72, WHITE_BISHOP
; check_white_a3_against_queen_d3_pressure
  .byte $2a, $60, $50
  .byte $53, BLACK_QUEEN, $42, WHITE_KNIGHT, $44, WHITE_PAWN, $04, BLACK_KING
  .byte $74, WHITE_KING, $05, BLACK_BISHOP, $06, BLACK_KNIGHT, $12, BLACK_PAWN
  .byte $20, BLACK_PAWN, $22, BLACK_PAWN
; check_white_ra3_after_qxe4_pressure
  .byte $88, $60, $50
  .byte $44, BLACK_QUEEN, $54, WHITE_BISHOP, $65, WHITE_ROOK, $73, WHITE_QUEEN
  .byte $76, WHITE_KING, $34, BLACK_KNIGHT, $00, BLACK_ROOK, $05, BLACK_ROOK
; check_white_nd4_against_ladder_queen_rook_pressure
  .byte $48, $55, $43
  .byte $05, BLACK_QUEEN, $03, BLACK_ROOK, $13, BLACK_BISHOP, $25, BLACK_BISHOP
  .byte $33, BLACK_PAWN, $53, WHITE_QUEEN, $74, WHITE_ROOK, $76, WHITE_KING
; check_white_rf2_in_qc7_development
  .byte $49, $55, $43
  .byte $53, WHITE_QUEEN, $12, BLACK_QUEEN, $14, BLACK_BISHOP
  .byte $25, BLACK_KNIGHT, $33, BLACK_PAWN, $06, BLACK_KING, $76, WHITE_KING
  .byte $54, EMPTY_PIECE, $04, EMPTY_PIECE
; check_white_bg5_before_knight_grab
  .byte $48, $b5, $16
  .byte $34, WHITE_PAWN, $51, BLACK_BISHOP, $26, BLACK_KNIGHT
  .byte $14, BLACK_KNIGHT, $03, BLACK_QUEEN, $04, BLACK_KING, $70, WHITE_ROOK
  .byte $76, WHITE_KING
; check_white_nc2_full_ladder_rook_bishop_net
  .byte $48, $43, $62
  .byte $00, BLACK_ROOK, $13, BLACK_BISHOP, $16, BLACK_BISHOP, $25, BLACK_QUEEN
  .byte $44, BLACK_KNIGHT, $54, WHITE_BISHOP, $64, WHITE_ROOK, $75, WHITE_ROOK
; check_white_nb3_against_rook_bishop_net
  .byte $a8, $53, $51
  .byte $44, BLACK_KNIGHT, $25, BLACK_QUEEN, $23, WHITE_PAWN, $54, WHITE_BISHOP
  .byte $64, WHITE_ROOK, $75, WHITE_ROOK, $07, BLACK_KING
  .byte $04, BLACK_ROOK
; check_white_bxd4_against_qb4
  .byte $68, $54, $43
  .byte $41, BLACK_QUEEN, $34, BLACK_KNIGHT, $44, WHITE_PAWN, $60, WHITE_ROOK
  .byte $73, WHITE_QUEEN, $75, WHITE_ROOK, $76, WHITE_KING, $00, BLACK_ROOK
; check_white_bf1_full_ladder_active_rook
  .byte $69, $42, $75
  .byte $03, BLACK_QUEEN, $05, BLACK_ROOK, $30, BLACK_ROOK, $06, BLACK_KING
  .byte $34, BLACK_KNIGHT, $43, WHITE_QUEEN, $62, WHITE_ROOK, $73, WHITE_ROOK
  .byte $76, WHITE_KING
; check_white_qxd6_against_active_rook
  .byte $a8, $c3, $23
  .byte $42, WHITE_BISHOP, $30, BLACK_ROOK, $34, BLACK_KNIGHT, $40, BLACK_PAWN
  .byte $44, WHITE_PAWN, $62, WHITE_ROOK, $73, WHITE_ROOK, $76, WHITE_KING
; check_white_qe8_in_queen_net
  .byte $a8, $64, $04
  .byte $54, EMPTY_PIECE, $45, BLACK_QUEEN, $40, BLACK_ROOK, $03, BLACK_ROOK
  .byte $63, BLACK_KNIGHT, $52, WHITE_KING, $46, WHITE_PAWN, $72, WHITE_ROOK
; check_white_qxa4_from_b5_queen_net
  .byte $a7, $31, $48
  .byte $43, BLACK_QUEEN, $62, WHITE_KING, $55, BLACK_KNIGHT, $46, WHITE_PAWN
  .byte $72, WHITE_ROOK, $76, WHITE_ROOK, $50, WHITE_PAWN
; check_white_qxa4_from_b3_queen_net
  .byte $a6, $51, $48
  .byte $43, BLACK_QUEEN, $62, WHITE_KING, $76, BLACK_KNIGHT, $46, WHITE_PAWN
  .byte $72, WHITE_ROOK, $50, WHITE_PAWN
; check_white_kg2_under_qf4_pressure
  .byte $c8, $75, $66
  .byte $45, BLACK_QUEEN, $24, BLACK_KNIGHT, $51, WHITE_BISHOP, $73, WHITE_QUEEN
  .byte $72, WHITE_ROOK, $76, WHITE_ROOK, $46, WHITE_PAWN, $06, BLACK_KING
; check_white_qf3_under_qh2_pressure
  .byte $aa, $73, $55
  .byte $64, EMPTY_PIECE, $67, BLACK_QUEEN, $75, WHITE_KING, $33, WHITE_BISHOP
  .byte $72, WHITE_ROOK, $76, WHITE_ROOK, $24, BLACK_KNIGHT, $03, BLACK_ROOK
  .byte $02, BLACK_BISHOP, $46, WHITE_PAWN
; check_white_bd3_against_qd5_d4
  .byte $63, $75, $53
  .byte $43, BLACK_PAWN, $33, BLACK_QUEEN, $44, WHITE_KNIGHT
; check_white_bd3_against_nf4_nc6
  .byte $65, $75, $53
  .byte $45, WHITE_KNIGHT, $22, BLACK_KNIGHT, $33, BLACK_PAWN, $32, BLACK_PAWN
  .byte $04, BLACK_KING
; check_white_bxa4_late_queenside_capture
  .byte $6c, $a2, $40
  .byte $51, BLACK_ROOK, $21, BLACK_KNIGHT, $14, BLACK_BISHOP, $03, BLACK_QUEEN
  .byte $05, BLACK_ROOK, $06, BLACK_KING, $73, WHITE_QUEEN, $74, WHITE_ROOK
  .byte $76, WHITE_KING, $55, WHITE_KNIGHT, $56, WHITE_KNIGHT, $43, WHITE_PAWN
; check_white_gxf3_after_bxa4_rook_capture
  .byte $2c, $66, $5d
  .byte $40, WHITE_BISHOP, $51, EMPTY_PIECE, $21, BLACK_KNIGHT, $14, BLACK_BISHOP
  .byte $03, BLACK_QUEEN, $05, BLACK_ROOK, $06, BLACK_KING, $73, WHITE_QUEEN
  .byte $74, WHITE_ROOK, $76, WHITE_KING, $56, WHITE_KNIGHT, $43, WHITE_PAWN
; check_white_qd1_after_gxf3_bishop_h4
  .byte $ac, $40, $73
  .byte $47, BLACK_BISHOP, $64, WHITE_KNIGHT, $55, WHITE_PAWN, $74, WHITE_ROOK
  .byte $76, WHITE_KING, $02, BLACK_BISHOP, $03, BLACK_QUEEN, $05, BLACK_ROOK
  .byte $06, BLACK_KING, $23, BLACK_PAWN, $34, BLACK_PAWN, $37, BLACK_PAWN
; check_white_kh1_after_qd1_double_bishops
  .byte $cc, $76, $77
  .byte $47, BLACK_BISHOP, $57, BLACK_BISHOP, $73, WHITE_QUEEN, $74, WHITE_ROOK
  .byte $71, WHITE_ROOK, $55, WHITE_PAWN, $64, WHITE_KNIGHT, $03, BLACK_QUEEN
  .byte $05, BLACK_ROOK, $06, BLACK_KING, $23, BLACK_PAWN, $37, BLACK_PAWN
; check_white_a3_after_qb6_pressure
  .byte $25, $60, $50
  .byte $21, BLACK_QUEEN, $45, WHITE_BISHOP, $53, WHITE_BISHOP, $64, WHITE_KNIGHT
  .byte $43, BLACK_PAWN
; check_white_bc7_after_qa3_pressure
  .byte $63, $45, $12
  .byte $61, BLACK_QUEEN, $53, WHITE_BISHOP, $50, WHITE_PAWN
; check_white_rf1_after_bc7_pressure
  .byte $83, $74, $75
  .byte $61, BLACK_QUEEN, $12, WHITE_BISHOP, $47, BLACK_BISHOP
; check_white_bishop_retreat_from_c4
  .byte $64, $42, $51
  .byte $12, BLACK_QUEEN, $43, BLACK_PAWN, $44, WHITE_PAWN, $55, WHITE_KNIGHT
; check_white_e3_after_bishop_b4
  .byte $25, $64, $54
  .byte $41, BLACK_BISHOP, $25, BLACK_KNIGHT, $42, WHITE_PAWN, $43, WHITE_PAWN
  .byte $52, WHITE_KNIGHT
; check_white_e3_after_slav_bf5
  .byte $26, $64, $54
  .byte $35, BLACK_BISHOP, $22, BLACK_PAWN, $33, BLACK_PAWN, $25, BLACK_KNIGHT
  .byte $42, WHITE_PAWN, $43, WHITE_PAWN
; check_white_c4_against_d5_bf5
  .byte $24, $62, $42
  .byte $35, BLACK_BISHOP, $33, BLACK_PAWN, $43, WHITE_PAWN, $55, WHITE_KNIGHT
; check_white_nxd5_against_early_qp_knight
  .byte $45, $5a, $33
  .byte $43, WHITE_PAWN, $64, WHITE_KNIGHT, $32, BLACK_PAWN, $24, BLACK_PAWN
  .byte $04, BLACK_KING
; check_white_c4_against_nf6
  .byte $24, $62, $42
  .byte $25, BLACK_KNIGHT, $43, WHITE_PAWN, $64, WHITE_PAWN, $52, EMPTY_PIECE
; check_white_c3_after_qp_knights
  .byte $27, $62, $52
  .byte $44, WHITE_KNIGHT, $53, WHITE_BISHOP, $43, WHITE_PAWN, $22, BLACK_KNIGHT
  .byte $25, BLACK_KNIGHT, $20, BLACK_PAWN, $03, BLACK_QUEEN
; check_white_be3_after_qp_queen_pressure
  .byte $68, $72, $54
  .byte $53, WHITE_BISHOP, $55, WHITE_KNIGHT, $75, WHITE_ROOK, $76, WHITE_KING
  .byte $33, BLACK_QUEEN, $22, BLACK_KNIGHT, $23, BLACK_KNIGHT, $20, BLACK_PAWN
; check_white_ne2_against_sicilian
  .byte $43, $76, $64
  .byte $32, BLACK_PAWN, $44, WHITE_PAWN, $63, WHITE_PAWN
; check_white_c3_against_e5_d4
  .byte $24, $62, $52
  .byte $34, BLACK_PAWN, $43, BLACK_PAWN, $44, WHITE_PAWN, $55, WHITE_KNIGHT
; check_white_e3
  .byte $24, $64, $54
  .byte $33, BLACK_PAWN, $24, BLACK_PAWN, $43, WHITE_PAWN, $55, WHITE_KNIGHT
; check_white_c3
  .byte $23, $62, $52
  .byte $32, BLACK_PAWN, $43, BLACK_PAWN, $64, WHITE_KNIGHT
; check_white_bishop_recaptures_c4
  .byte $23, $d3, $42
  .byte $43, WHITE_PAWN, $54, WHITE_PAWN, $55, WHITE_KNIGHT
; check_white_ne2_before_bf4_blunder
  .byte $46, $52, $64
  .byte $23, BLACK_BISHOP, $22, BLACK_PAWN, $33, BLACK_PAWN, $24, BLACK_PAWN
  .byte $72, WHITE_BISHOP, $76, WHITE_KING
; check_white_ne4_against_open_queen_file
  .byte $46, $52, $44
  .byte $43, BLACK_PAWN, $73, WHITE_QUEEN, $03, BLACK_QUEEN, $13, EMPTY_PIECE
  .byte $23, EMPTY_PIECE, $33, EMPTY_PIECE
; check_white_cxd4_after_alapin_cxd4
  .byte $26, $d2, $43
  .byte $73, WHITE_QUEEN, $32, EMPTY_PIECE, $62, EMPTY_PIECE, $63, EMPTY_PIECE
  .byte $44, WHITE_PAWN, $22, BLACK_KNIGHT
; check_white_knight_recaptures_d4
  .byte $42, $d5, $43
  .byte $22, BLACK_KNIGHT, $73, WHITE_QUEEN
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
; packed-count/from/to followed by square/piece condition pairs. The count byte
; uses bits 0-4 for condition count and bits 5-7 for the expected source piece
; type, which replaces the old explicit source-square condition pair. The from
; and to header bytes also pack a destination expectation in otherwise-invalid
; 0x88 bits: 0=empty, 1-6=enemy piece type, 7=no destination check.
; Call with temp1 pointing at the table.
TryOpeningSurvivalTable:
__ai_search_rule_loop_0:
  ldy #$00
  lda (temp1), y
  bne __ai_search_rule_has_data_0
  jmp __ai_search_table_miss_0
__ai_search_rule_has_data_0:
  sta $f4
  and #$1f
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

  lda #$00
  sta $f5
  lda $f2
  and #$80
  beq __ai_search_dest_class_bit_0_clear_0
  inc $f5
__ai_search_dest_class_bit_0_clear_0:
  lda $f2
  and #$08
  beq __ai_search_dest_class_bit_1_clear_0
  lda $f5
  ora #$02
  sta $f5
__ai_search_dest_class_bit_1_clear_0:
  lda $f3
  and #$08
  beq __ai_search_dest_class_ready_0
  lda $f5
  ora #$04
  sta $f5
__ai_search_dest_class_ready_0:
  lda $f2
  and #$77
  sta $f2
  lda $f3
  and #$f7
  sta $f3

  lda $f4
  lsr
  lsr
  lsr
  lsr
  lsr
  ora #EMPTY_PIECE
  ldx SearchSide
  beq __ai_search_source_piece_ready_0
  ora #WHITE_COLOR
__ai_search_source_piece_ready_0:
  ldx $f2
  cmp Board88, x
  bne __ai_search_next_rule_0

  lda $f5
  cmp #$07
  beq __ai_search_dest_check_done_0
  ora #EMPTY_PIECE
  cmp #EMPTY_PIECE
  beq __ai_search_dest_piece_ready_0
  ldx SearchSide
  bne __ai_search_dest_piece_ready_0
  ora #WHITE_COLOR
__ai_search_dest_piece_ready_0:
  ldx $f3
  cmp Board88, x
  bne __ai_search_next_rule_0
__ai_search_dest_check_done_0:

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
  bcs __ai_search_rule_page_cross_0
  jmp __ai_search_rule_loop_0
__ai_search_rule_page_cross_0:
  inc temp1 + 1
  jmp __ai_search_rule_loop_0
__ai_search_table_miss_0:
  clc
  rts

BlackOpeningSurvivalTable:
; check_black_e5_after_colossus_na3
  .byte $28, $14, $34
  .byte $50, WHITE_KNIGHT, $01, BLACK_KNIGHT, $06, BLACK_KNIGHT, $04, BLACK_KING
  .byte $74, WHITE_KING, $73, WHITE_QUEEN, $03, BLACK_QUEEN, $11, BLACK_PAWN
; check_black_g6_after_sicilian_bishop_check
  .byte $25, $16, $26
  .byte $22, BLACK_KNIGHT, $31, WHITE_BISHOP, $32, BLACK_PAWN, $44, WHITE_PAWN
  .byte $55, WHITE_KNIGHT
; check_black_a6_lost_rook_endgame
  .byte $28, $10, $20
  .byte $05, BLACK_ROOK, $07, BLACK_KING, $11, WHITE_QUEEN, $34, WHITE_ROOK
  .byte $37, BLACK_PAWN, $55, WHITE_KNIGHT, $67, WHITE_KING, $32, WHITE_PAWN
; check_black_be5_full_ladder_pressure
  .byte $68, $23, $34
  .byte $03, BLACK_QUEEN, $02, BLACK_ROOK, $15, BLACK_ROOK, $06, BLACK_KING
  .byte $25, BLACK_KNIGHT, $45, WHITE_KNIGHT, $73, WHITE_QUEEN, $77, WHITE_KING
; check_black_nd3_full_ladder_pressure
  .byte $47, $34, $53
  .byte $02, BLACK_ROOK, $03, BLACK_QUEEN, $05, BLACK_ROOK
  .byte $23, BLACK_BISHOP, $25, BLACK_KNIGHT, $57, WHITE_BISHOP, $73, WHITE_QUEEN
; check_black_qf5_under_white_queen_knight_attack
  .byte $a8, $25, $35
  .byte $37, WHITE_QUEEN, $36, WHITE_KNIGHT, $34, BLACK_KNIGHT, $23, BLACK_BISHOP
  .byte $06, BLACK_KING, $00, BLACK_ROOK, $72, WHITE_KING, $73, WHITE_ROOK
; check_black_rf8_rook_defense
  .byte $88, $02, $05
  .byte $07, BLACK_KING, $11, WHITE_QUEEN, $12, BLACK_PAWN, $26, BLACK_PAWN
  .byte $34, WHITE_ROOK, $37, BLACK_PAWN, $55, WHITE_KNIGHT, $77, WHITE_KING
; check_black_rde8_rook_defense
  .byte $8a, $03, $04
  .byte $01, BLACK_ROOK, $07, BLACK_KING, $35, BLACK_KNIGHT, $46, WHITE_ROOK
  .byte $51, WHITE_QUEEN, $55, WHITE_KNIGHT, $74, WHITE_ROOK, $76, WHITE_KING
  .byte $10, BLACK_PAWN, $12, BLACK_PAWN
; check_black_re7_full_ladder_two_bishops
  .byte $89, $04, $14
  .byte $01, BLACK_ROOK, $06, BLACK_KING, $22, WHITE_BISHOP, $23, BLACK_BISHOP
  .byte $25, BLACK_QUEEN, $35, BLACK_BISHOP, $56, WHITE_QUEEN, $74, WHITE_ROOK
  .byte $76, WHITE_KING
; check_black_qxe4_queen_infiltration
  .byte $a9, $45, $4c
  .byte $01, BLACK_ROOK, $03, BLACK_ROOK, $07, BLACK_KING, $35, BLACK_KNIGHT
  .byte $51, WHITE_QUEEN, $55, WHITE_KNIGHT, $74, WHITE_ROOK, $76, WHITE_KING
  .byte $47, WHITE_PAWN
; check_black_g6_against_two_bishop_queen_mate
  .byte $26, $16, $26
  .byte $15, BLACK_KING, $24, WHITE_KNIGHT, $33, WHITE_BISHOP, $42, WHITE_QUEEN
  .byte $54, WHITE_BISHOP, $37, BLACK_PAWN
; check_black_qxf3_against_qe8_mate_net
  .byte $a6, $2d, $55
  .byte $04, WHITE_QUEEN, $16, BLACK_KING, $24, BLACK_BISHOP, $53, WHITE_BISHOP
  .byte $67, WHITE_KING, $74, WHITE_ROOK
; check_black_qf6_against_queen_rook_mate_net
  .byte $a8, $03, $25
  .byte $05, BLACK_KING, $02, BLACK_ROOK, $27, BLACK_KNIGHT, $42, WHITE_QUEEN
  .byte $43, WHITE_PAWN, $52, WHITE_PAWN, $55, WHITE_ROOK, $76, WHITE_KING
; check_black_re8_against_rook_queen_pressure
  .byte $88, $03, $04
  .byte $01, BLACK_ROOK, $07, BLACK_KING, $35, BLACK_KNIGHT, $45, WHITE_ROOK
  .byte $51, WHITE_QUEEN, $55, WHITE_KNIGHT, $74, WHITE_ROOK, $76, WHITE_KING
; check_black_re7_against_queen_rook_mate_net
  .byte $88, $04, $14
  .byte $10, BLACK_PAWN, $12, WHITE_QUEEN, $16, BLACK_KING, $32, WHITE_PAWN
  .byte $37, WHITE_ROOK, $47, WHITE_PAWN, $74, WHITE_KNIGHT, $76, WHITE_KING
; check_black_rh1_after_back_rank_invasion
  .byte $88, $74, $77
  .byte $01, BLACK_ROOK, $07, BLACK_KING, $32, WHITE_PAWN, $35, WHITE_ROOK
  .byte $47, WHITE_PAWN, $51, WHITE_QUEEN, $55, WHITE_KNIGHT, $67, WHITE_KING
; check_black_g5_after_queen_rook_battery
  .byte $28, $26, $36
  .byte $05, BLACK_ROOK, $07, BLACK_KING, $12, WHITE_QUEEN, $34, WHITE_ROOK
  .byte $37, BLACK_PAWN, $47, WHITE_PAWN, $55, WHITE_KNIGHT, $67, WHITE_KING
; check_black_rg8_after_queen_rook_battery
  .byte $88, $05, $06
  .byte $07, BLACK_KING, $11, WHITE_QUEEN, $34, WHITE_ROOK, $36, BLACK_PAWN
  .byte $37, BLACK_PAWN, $47, WHITE_PAWN, $55, WHITE_KNIGHT, $67, WHITE_KING
; check_black_nxd5_against_queen_rook_battery
  .byte $46, $94, $33
  .byte $04, BLACK_ROOK, $06, BLACK_KING, $12, BLACK_ROOK, $43, WHITE_QUEEN
  .byte $54, WHITE_KNIGHT, $30, WHITE_ROOK
; check_black_nxd5_against_early_queen_grab
  .byte $46, $2d, $33
  .byte $22, BLACK_KNIGHT, $42, WHITE_QUEEN, $44, WHITE_PAWN, $03, BLACK_QUEEN
  .byte $04, BLACK_KING, $74, WHITE_KING
; check_black_kh8_against_ng5_pressure
  .byte $c8, $06, $07
  .byte $02, BLACK_QUEEN, $05, BLACK_ROOK, $24, BLACK_PAWN, $35, BLACK_KNIGHT
  .byte $36, WHITE_KNIGHT, $51, WHITE_QUEEN, $74, WHITE_ROOK, $76, WHITE_KING
; check_black_nd6_against_advanced_knight_attack
  .byte $48, $35, $23
  .byte $02, BLACK_QUEEN, $05, BLACK_ROOK, $06, BLACK_KING, $24, WHITE_KNIGHT
  .byte $42, WHITE_QUEEN, $43, WHITE_PAWN, $74, WHITE_ROOK, $76, WHITE_KING
; check_black_nxc3_against_center_knight_wedge
  .byte $47, $4c, $52
  .byte $55, WHITE_KNIGHT, $35, BLACK_BISHOP, $25, BLACK_BISHOP, $02, BLACK_QUEEN
  .byte $03, BLACK_ROOK, $04, BLACK_ROOK, $06, BLACK_KING
; check_black_bxd4_against_queen_bishop_battery
  .byte $68, $a5, $43
  .byte $22, WHITE_QUEEN, $24, BLACK_BISHOP, $53, WHITE_BISHOP, $54, WHITE_PAWN
  .byte $55, WHITE_KNIGHT, $56, WHITE_BISHOP, $67, WHITE_KING, $04, BLACK_ROOK
; check_black_nxe4_against_early_center_jump
  .byte $46, $a5, $44
  .byte $33, WHITE_PAWN, $34, WHITE_KNIGHT, $41, BLACK_BISHOP, $52, WHITE_KNIGHT
  .byte $14, BLACK_KNIGHT, $04, BLACK_KING
; check_black_rc8_against_a5_queen_battery
  .byte $87, $04, $02
  .byte $12, BLACK_ROOK, $13, BLACK_BISHOP, $25, BLACK_KNIGHT, $30, WHITE_ROOK
  .byte $33, WHITE_PAWN, $43, WHITE_QUEEN, $06, BLACK_KING
; check_black_qc6_against_early_queen_knight_pressure
  .byte $a6, $24, $22
  .byte $33, WHITE_KNIGHT, $43, WHITE_QUEEN, $54, WHITE_BISHOP, $04, BLACK_KING
  .byte $00, BLACK_ROOK, $02, BLACK_BISHOP
; check_black_h5_against_back_rank_piece_storm
  .byte $26, $17, $37
  .byte $26, BLACK_KING, $56, WHITE_QUEEN, $12, WHITE_ROOK, $00, WHITE_KNIGHT
  .byte $40, BLACK_QUEEN, $46, BLACK_KNIGHT
; check_black_g6_against_advanced_rook_queen_net
  .byte $27, $16, $26
  .byte $07, BLACK_KING, $04, WHITE_ROOK, $33, WHITE_QUEEN, $13, WHITE_PAWN
  .byte $37, WHITE_BISHOP, $05, BLACK_QUEEN, $21, BLACK_BISHOP
; check_black_re2_against_qg7_mate
  .byte $85, $0c, $64
  .byte $56, WHITE_QUEEN, $27, WHITE_BISHOP, $53, WHITE_BISHOP, $06, BLACK_KING
  .byte $25, BLACK_PAWN
; check_black_bxc3_before_castling
  .byte $65, $49, $52
  .byte $36, WHITE_BISHOP, $53, WHITE_BISHOP, $56, WHITE_QUEEN, $76, WHITE_KNIGHT
  .byte $04, BLACK_KING
; check_black_bxc3_after_h5_e5
  .byte $46, $a2, $34
  .byte $36, WHITE_BISHOP, $53, WHITE_BISHOP, $56, WHITE_QUEEN, $64, WHITE_KNIGHT
  .byte $37, BLACK_PAWN, $06, BLACK_KING
; check_black_be7_after_white_ne2
  .byte $67, $41, $14
  .byte $36, WHITE_BISHOP, $53, WHITE_BISHOP, $56, WHITE_QUEEN, $64, WHITE_KNIGHT
  .byte $17, BLACK_PAWN, $22, BLACK_KNIGHT, $06, BLACK_KING
; check_black_g6_after_advanced_f6
  .byte $26, $16, $26
  .byte $25, WHITE_PAWN, $36, WHITE_BISHOP, $41, BLACK_BISHOP, $52, WHITE_KNIGHT
  .byte $53, WHITE_BISHOP, $56, WHITE_QUEEN
; check_black_be7_against_qd3_development
  .byte $26, $17, $27
  .byte $53, WHITE_QUEEN, $52, WHITE_KNIGHT, $22, BLACK_KNIGHT, $25, BLACK_KNIGHT
  .byte $44, WHITE_PAWN, $04, BLACK_KING
; check_black_c5_after_bishop_queen_net
  .byte $2a, $22, $32
  .byte $02, BLACK_KNIGHT, $24, WHITE_QUEEN, $43, WHITE_BISHOP, $44, WHITE_BISHOP
  .byte $15, BLACK_ROOK, $11, BLACK_BISHOP, $06, BLACK_KING, $01, BLACK_ROOK
  .byte $13, WHITE_KNIGHT, $46, BLACK_PAWN
; check_black_nd6_after_queen_b3_pressure
  .byte $4a, $02, $23
  .byte $13, WHITE_KNIGHT, $51, WHITE_QUEEN, $43, WHITE_BISHOP, $44, WHITE_BISHOP
  .byte $15, BLACK_ROOK, $11, BLACK_BISHOP, $06, BLACK_KING, $00, BLACK_ROOK
  .byte $22, BLACK_PAWN, $46, BLACK_PAWN
; check_black_c5_with_a6_against_queen_b3_pressure
  .byte $2b, $22, $32
  .byte $20, BLACK_PAWN, $14, BLACK_KNIGHT, $21, WHITE_KNIGHT, $51, WHITE_QUEEN
  .byte $43, WHITE_BISHOP, $44, WHITE_BISHOP, $15, BLACK_ROOK, $11, BLACK_BISHOP
  .byte $06, BLACK_KING, $00, BLACK_ROOK, $46, BLACK_PAWN
; check_black_raf8_without_a6_against_queen_b3_pressure
  .byte $8b, $00, $05
  .byte $20, EMPTY_PIECE, $14, BLACK_KNIGHT, $21, WHITE_KNIGHT, $51, WHITE_QUEEN
  .byte $43, WHITE_BISHOP, $44, WHITE_BISHOP, $15, BLACK_ROOK, $11, BLACK_BISHOP
  .byte $06, BLACK_KING, $22, BLACK_PAWN, $46, BLACK_PAWN
; check_black_nd5_after_white_queen_b3_pressure
  .byte $4a, $14, $33
  .byte $21, WHITE_KNIGHT, $51, WHITE_QUEEN, $43, WHITE_BISHOP, $44, WHITE_BISHOP
  .byte $15, BLACK_ROOK, $11, BLACK_BISHOP, $06, BLACK_KING, $00, BLACK_ROOK
  .byte $22, BLACK_PAWN, $46, BLACK_PAWN
; check_black_f6_against_rook_knight_battery
  .byte $2b, $15, $25
  .byte $33, WHITE_ROOK, $32, WHITE_KNIGHT, $14, BLACK_QUEEN, $05, BLACK_ROOK
  .byte $06, BLACK_KING, $36, BLACK_PAWN, $37, BLACK_PAWN, $22, BLACK_KNIGHT
  .byte $52, WHITE_BISHOP, $56, WHITE_QUEEN, $45, WHITE_PAWN
; check_black_qxc5_against_advanced_knight
  .byte $a9, $1c, $32
  .byte $05, BLACK_ROOK, $06, BLACK_KING, $22, BLACK_KNIGHT, $45, WHITE_PAWN
  .byte $56, WHITE_QUEEN, $63, WHITE_BISHOP, $73, WHITE_ROOK, $15, BLACK_PAWN
  .byte $16, BLACK_PAWN
; check_black_f5_after_nge5_temptation
  .byte $29, $15, $35
  .byte $46, BLACK_KNIGHT, $45, WHITE_PAWN, $44, WHITE_PAWN, $52, WHITE_KNIGHT
  .byte $56, WHITE_QUEEN, $63, WHITE_BISHOP, $05, BLACK_ROOK, $06, BLACK_KING
  .byte $23, BLACK_BISHOP
; check_black_bc5_after_nge5_temptation
  .byte $68, $23, $32
  .byte $46, BLACK_KNIGHT, $44, WHITE_PAWN, $52, WHITE_KNIGHT, $63, WHITE_BISHOP
  .byte $05, BLACK_ROOK, $06, BLACK_KING, $03, BLACK_QUEEN, $22, BLACK_KNIGHT
; check_black_bxc3_before_quiet_bishop_retreat
  .byte $68, $49, $52
  .byte $54, WHITE_QUEEN, $44, WHITE_PAWN, $22, BLACK_KNIGHT, $25, BLACK_KNIGHT
  .byte $03, BLACK_QUEEN, $05, BLACK_ROOK, $06, BLACK_KING, $74, WHITE_KING
; check_black_bf5_against_two_bishops_and_queen
  .byte $6b, $02, $35
  .byte $40, WHITE_KNIGHT, $43, WHITE_BISHOP, $44, WHITE_BISHOP, $52, WHITE_QUEEN
  .byte $14, BLACK_KNIGHT, $05, BLACK_ROOK, $06, BLACK_KING, $20, BLACK_PAWN
  .byte $21, BLACK_PAWN, $22, BLACK_PAWN, $46, BLACK_PAWN
; check_black_rh8_against_rook_on_h5
  .byte $8b, $05, $07
  .byte $37, WHITE_ROOK, $16, BLACK_KING, $14, BLACK_QUEEN, $02, BLACK_BISHOP
  .byte $22, BLACK_KNIGHT, $32, WHITE_KNIGHT, $44, WHITE_BISHOP, $52, WHITE_BISHOP
  .byte $56, WHITE_QUEEN, $46, BLACK_PAWN, $25, BLACK_PAWN
; check_black_rg8_with_bishop_home_against_knight_pair
  .byte $88, $07, $06
  .byte $02, BLACK_KING, $05, BLACK_BISHOP, $32, BLACK_KNIGHT, $37, BLACK_BISHOP
  .byte $43, WHITE_KNIGHT, $52, WHITE_KNIGHT, $54, WHITE_BISHOP, $72, WHITE_KING
; check_black_bf8_against_selfplay_knight_fork
  .byte $68, $14, $05
  .byte $02, BLACK_KING, $07, BLACK_ROOK, $32, BLACK_KNIGHT, $35, WHITE_KNIGHT
  .byte $37, BLACK_BISHOP, $52, WHITE_KNIGHT, $54, WHITE_BISHOP, $72, WHITE_KING
; check_black_re8_before_ng4_temptation
  .byte $8a, $05, $04
  .byte $06, BLACK_KING, $03, BLACK_QUEEN, $23, BLACK_BISHOP, $25, BLACK_KNIGHT
  .byte $22, BLACK_KNIGHT, $54, WHITE_QUEEN, $52, WHITE_KNIGHT, $44, WHITE_PAWN
  .byte $63, WHITE_BISHOP, $73, WHITE_ROOK
; check_black_qd7_in_a5_knight_pressure
  .byte $4b, $25, $46
  .byte $34, BLACK_KNIGHT, $30, WHITE_PAWN, $32, BLACK_PAWN
  .byte $23, BLACK_BISHOP, $24, BLACK_PAWN, $63, WHITE_PAWN, $64, WHITE_KNIGHT
  .byte $57, WHITE_BISHOP, $05, BLACK_ROOK, $02, BLACK_ROOK, $06, BLACK_KING
; check_black_nxe4_before_bishop_trade
  .byte $48, $2d, $44
  .byte $42, WHITE_BISHOP, $43, WHITE_KNIGHT, $33, WHITE_PAWN, $32, BLACK_BISHOP
  .byte $06, BLACK_KING, $03, BLACK_QUEEN, $74, WHITE_KING, $64, WHITE_QUEEN
; check_black_nxe4_in_a5_knight_pressure
  .byte $4b, $25, $44
  .byte $31, WHITE_KNIGHT, $34, BLACK_KNIGHT, $30, WHITE_PAWN, $32, BLACK_PAWN
  .byte $23, BLACK_BISHOP, $24, BLACK_PAWN, $63, WHITE_PAWN, $64, WHITE_KNIGHT
  .byte $57, WHITE_BISHOP, $03, BLACK_QUEEN, $06, BLACK_KING
; check_black_h6_after_qc7_rf7
  .byte $8a, $15, $14
  .byte $12, BLACK_QUEEN, $25, BLACK_KNIGHT, $22, BLACK_KNIGHT, $30, WHITE_PAWN
  .byte $34, BLACK_PAWN, $36, WHITE_KNIGHT, $57, WHITE_BISHOP, $64, WHITE_KNIGHT
  .byte $02, BLACK_ROOK, $06, BLACK_KING
; check_black_e5_from_e6_in_rook_pressure
  .byte $67, $2b, $45
  .byte $02, BLACK_ROOK, $15, BLACK_ROOK, $25, BLACK_KNIGHT, $30, WHITE_PAWN
  .byte $57, WHITE_BISHOP, $64, WHITE_KNIGHT
  .byte $06, BLACK_KING
; check_black_nxh2_against_b5_knight
  .byte $4a, $c6, $67
  .byte $31, WHITE_KNIGHT, $30, WHITE_PAWN, $45, WHITE_KNIGHT
  .byte $34, BLACK_KNIGHT, $23, BLACK_BISHOP, $24, BLACK_PAWN, $01, BLACK_ROOK
  .byte $03, BLACK_QUEEN, $05, BLACK_ROOK, $06, BLACK_KING
; check_black_nxd5_against_early_g3
  .byte $48, $a5, $33
  .byte $22, BLACK_KNIGHT, $32, BLACK_PAWN, $56, WHITE_PAWN, $64, WHITE_KNIGHT
  .byte $66, WHITE_BISHOP, $74, WHITE_KING, $04, BLACK_KING, $03, BLACK_QUEEN
; check_black_be5_after_bh7_qh4
  .byte $2b, $16, $26
  .byte $47, WHITE_QUEEN, $17, WHITE_BISHOP, $36, WHITE_KNIGHT, $25, BLACK_KNIGHT
  .byte $30, BLACK_KNIGHT, $43, BLACK_PAWN, $52, WHITE_PAWN, $07, BLACK_KING
  .byte $05, BLACK_ROOK, $70, WHITE_ROOK, $75, WHITE_ROOK
; check_black_kg7_under_rook_knight_pressure
  .byte $c9, $06, $16
  .byte $03, WHITE_ROOK, $04, BLACK_ROOK, $14, WHITE_KNIGHT, $22, BLACK_BISHOP
  .byte $32, WHITE_BISHOP, $42, BLACK_KNIGHT, $34, WHITE_PAWN, $74, WHITE_ROOK
  .byte $76, WHITE_KING
; check_black_nxe4_after_bishop_pin_e5
  .byte $46, $a5, $44
  .byte $34, WHITE_PAWN, $41, BLACK_BISHOP, $22, BLACK_KNIGHT, $52, WHITE_KNIGHT
  .byte $55, WHITE_KNIGHT, $04, BLACK_KING
; check_black_qf6_against_advanced_d6_bishops
  .byte $ac, $03, $25
  .byte $14, EMPTY_PIECE, $41, BLACK_BISHOP, $46, BLACK_KNIGHT, $22, BLACK_KNIGHT
  .byte $23, WHITE_PAWN, $42, WHITE_BISHOP, $45, WHITE_BISHOP, $52, WHITE_KNIGHT
  .byte $55, WHITE_KNIGHT, $44, WHITE_PAWN, $06, BLACK_KING, $05, BLACK_ROOK
; check_black_re8_against_two_bishops
  .byte $89, $05, $04
  .byte $06, BLACK_KING, $22, BLACK_KNIGHT, $46, BLACK_KNIGHT, $23, WHITE_BISHOP
  .byte $42, WHITE_BISHOP, $55, WHITE_KNIGHT, $52, WHITE_PAWN, $44, WHITE_PAWN
  .byte $02, BLACK_BISHOP
; check_black_bc6_against_center_bishop_knights
  .byte $67, $13, $22
  .byte $42, BLACK_KNIGHT, $44, BLACK_KNIGHT, $43, WHITE_BISHOP, $34, WHITE_PAWN
  .byte $55, WHITE_KNIGHT, $52, WHITE_PAWN, $06, BLACK_KING
; check_black_e6_after_qp_c3
  .byte $25, $14, $24
  .byte $33, BLACK_PAWN, $43, WHITE_PAWN, $52, WHITE_PAWN, $04, BLACK_KING
  .byte $74, WHITE_KING
; check_black_e6_after_qp_c3_bf4
  .byte $27, $14, $24
  .byte $33, BLACK_PAWN, $43, WHITE_PAWN, $52, WHITE_PAWN, $45, WHITE_BISHOP
  .byte $54, WHITE_PAWN, $25, BLACK_KNIGHT, $22, BLACK_KNIGHT
; check_black_dxe4_after_qp_g3_e4
  .byte $27, $b3, $44
  .byte $43, WHITE_PAWN, $52, WHITE_PAWN, $23, BLACK_BISHOP, $22, BLACK_KNIGHT
  .byte $25, BLACK_KNIGHT, $66, WHITE_BISHOP, $04, BLACK_KING
; check_black_nxe4_after_qp_dxe4_recapture
  .byte $47, $2d, $44
  .byte $33, EMPTY_PIECE, $43, WHITE_PAWN, $52, WHITE_PAWN, $23, BLACK_BISHOP
  .byte $22, BLACK_KNIGHT, $66, WHITE_BISHOP, $04, BLACK_KING
; check_black_e5_after_qp_bxe4
  .byte $27, $24, $34
  .byte $44, WHITE_BISHOP, $43, WHITE_PAWN, $52, WHITE_PAWN, $23, BLACK_BISHOP
  .byte $22, BLACK_KNIGHT, $56, WHITE_PAWN, $04, BLACK_KING
; check_black_f6_blocks_bg5_queen_skewer
  .byte $27, $15, $25
  .byte $36, WHITE_BISHOP, $44, WHITE_BISHOP, $43, BLACK_PAWN, $03, BLACK_QUEEN
  .byte $04, BLACK_KING, $23, BLACK_BISHOP, $22, BLACK_KNIGHT
; check_black_castles_after_bg5_qe2_f6
  .byte $ab, $04, $06
  .byte $07, BLACK_ROOK, $05, EMPTY_PIECE, $25, BLACK_PAWN, $15, EMPTY_PIECE
  .byte $36, WHITE_BISHOP, $44, WHITE_BISHOP, $43, BLACK_PAWN, $64, WHITE_QUEEN
  .byte $03, BLACK_QUEEN, $23, BLACK_BISHOP, $22, BLACK_KNIGHT
; check_black_re8_after_bg5_bd2_castles
  .byte $89, $05, $04
  .byte $06, BLACK_KING, $25, BLACK_PAWN, $63, WHITE_BISHOP, $44, WHITE_BISHOP
  .byte $43, BLACK_PAWN, $64, WHITE_QUEEN, $03, BLACK_QUEEN, $23, BLACK_BISHOP
  .byte $22, BLACK_KNIGHT
; check_black_castles_after_open_game_qe2
  .byte $ab, $04, $06
  .byte $07, BLACK_ROOK, $05, EMPTY_PIECE, $32, BLACK_BISHOP, $22, BLACK_KNIGHT
  .byte $25, BLACK_KNIGHT, $44, BLACK_PAWN, $33, WHITE_PAWN, $42, WHITE_BISHOP
  .byte $52, WHITE_KNIGHT, $55, WHITE_KNIGHT, $64, WHITE_QUEEN
; check_black_bd6_after_qp_bf4_nd2
  .byte $68, $05, $23
  .byte $45, WHITE_BISHOP, $54, WHITE_PAWN, $63, WHITE_KNIGHT, $52, WHITE_PAWN
  .byte $43, WHITE_PAWN, $24, BLACK_PAWN, $22, BLACK_KNIGHT, $25, BLACK_KNIGHT
; check_black_bd6_after_qp_bf4_qe2
  .byte $68, $14, $23
  .byte $13, BLACK_BISHOP, $24, BLACK_PAWN, $45, WHITE_BISHOP, $53, WHITE_BISHOP
  .byte $64, WHITE_QUEEN, $52, WHITE_PAWN, $43, WHITE_PAWN, $06, BLACK_KING
; check_black_bxf4_after_qp_bf4_bd3
  .byte $68, $ab, $45
  .byte $53, WHITE_BISHOP, $06, BLACK_KING, $05, BLACK_ROOK, $55, WHITE_KNIGHT
  .byte $63, WHITE_KNIGHT, $24, BLACK_PAWN, $33, BLACK_PAWN, $43, WHITE_PAWN
; check_black_rxd8_after_qp_nxd8
  .byte $88, $0a, $03
  .byte $04, BLACK_ROOK, $06, BLACK_KING, $13, BLACK_BISHOP, $25, BLACK_KNIGHT
  .byte $64, WHITE_QUEEN, $72, WHITE_KING, $55, WHITE_KNIGHT, $73, WHITE_ROOK
; check_black_bxe8_after_qp_bxe8
  .byte $68, $9b, $04
  .byte $06, BLACK_KING, $14, BLACK_KNIGHT, $25, BLACK_KNIGHT, $64, WHITE_QUEEN
  .byte $72, WHITE_KING, $76, WHITE_ROOK, $24, BLACK_PAWN, $33, BLACK_PAWN
; check_black_ng8_against_rh8_mate
  .byte $48, $14, $06
  .byte $05, BLACK_KING, $24, WHITE_QUEEN, $77, WHITE_ROOK, $13, BLACK_KNIGHT
  .byte $25, EMPTY_PIECE, $22, BLACK_PAWN, $33, BLACK_PAWN, $72, WHITE_KING
; check_black_g6_after_qp_rb8_castles
  .byte $28, $16, $26
  .byte $01, BLACK_ROOK, $03, BLACK_QUEEN, $04, BLACK_ROOK, $06, BLACK_KING
  .byte $34, WHITE_KNIGHT, $73, WHITE_ROOK, $72, WHITE_KING, $25, BLACK_KNIGHT
; check_black_ng4_against_h3_bishop
  .byte $4c, $25, $46
  .byte $34, BLACK_KNIGHT, $23, BLACK_BISHOP, $24, BLACK_PAWN, $32, BLACK_PAWN
  .byte $57, WHITE_BISHOP, $64, WHITE_KNIGHT, $42, WHITE_PAWN, $30, WHITE_PAWN
  .byte $56, WHITE_PAWN, $06, BLACK_KING, $05, BLACK_ROOK, $03, BLACK_QUEEN
; check_black_be5_after_ng4_branch
  .byte $6b, $23, $34
  .byte $24, BLACK_PAWN, $45, WHITE_KNIGHT, $57, WHITE_BISHOP, $64, WHITE_KNIGHT
  .byte $30, WHITE_PAWN, $42, WHITE_PAWN, $06, BLACK_KING, $15, BLACK_ROOK
  .byte $03, BLACK_QUEEN, $22, BLACK_KNIGHT, $25, BLACK_KNIGHT
; check_black_rd8_late_queen_rook_defense
  .byte $8a, $01, $03
  .byte $06, BLACK_KING, $25, BLACK_QUEEN, $34, BLACK_KNIGHT, $32, BLACK_BISHOP
  .byte $43, WHITE_KNIGHT, $66, WHITE_BISHOP, $61, WHITE_BISHOP, $73, WHITE_QUEEN
  .byte $77, WHITE_KING, $17, BLACK_PAWN
; check_black_nxe5_after_qp_g6_g5
  .byte $48, $2a, $34
  .byte $25, BLACK_KNIGHT, $26, BLACK_PAWN, $36, WHITE_PAWN, $01, BLACK_ROOK
  .byte $03, BLACK_QUEEN, $04, BLACK_ROOK, $06, BLACK_KING, $13, BLACK_BISHOP
; check_black_kg7_after_qp_qe3_mate_threat
  .byte $cb, $06, $16
  .byte $04, BLACK_ROOK, $03, BLACK_QUEEN, $01, BLACK_ROOK, $54, WHITE_QUEEN
  .byte $34, WHITE_KNIGHT, $36, WHITE_PAWN, $44, BLACK_PAWN, $43, WHITE_PAWN
  .byte $45, WHITE_PAWN, $13, BLACK_BISHOP, $15, BLACK_PAWN
; check_black_qe7_after_qp_rh6_kg7
  .byte $ab, $03, $14
  .byte $16, BLACK_KING, $27, WHITE_ROOK, $04, BLACK_ROOK, $54, WHITE_QUEEN
  .byte $34, WHITE_KNIGHT, $36, WHITE_PAWN, $44, BLACK_PAWN, $13, BLACK_BISHOP
  .byte $15, BLACK_PAWN, $26, BLACK_PAWN, $73, WHITE_ROOK
; check_black_rh8_after_qp_qe7_a3
  .byte $8b, $04, $07
  .byte $05, EMPTY_PIECE, $06, EMPTY_PIECE, $16, BLACK_KING, $14, BLACK_QUEEN
  .byte $27, WHITE_ROOK, $50, WHITE_PAWN, $54, WHITE_QUEEN, $34, WHITE_KNIGHT
  .byte $36, WHITE_PAWN, $44, BLACK_PAWN, $13, BLACK_BISHOP
; check_black_rg8_after_qp_qh3_rh8
  .byte $8b, $01, $06
  .byte $07, BLACK_ROOK, $16, BLACK_KING, $14, BLACK_QUEEN, $27, WHITE_ROOK
  .byte $57, WHITE_QUEEN, $34, WHITE_KNIGHT, $36, WHITE_PAWN, $44, BLACK_PAWN
  .byte $13, BLACK_BISHOP, $15, BLACK_PAWN, $26, BLACK_PAWN
; check_black_qe8_after_qp_rh1
  .byte $ab, $14, $04
  .byte $06, BLACK_ROOK, $07, BLACK_ROOK, $16, BLACK_KING, $27, WHITE_ROOK
  .byte $57, WHITE_QUEEN, $77, WHITE_ROOK, $34, WHITE_KNIGHT, $36, WHITE_PAWN
  .byte $44, BLACK_PAWN, $13, BLACK_BISHOP, $15, BLACK_PAWN
; check_black_bc6_after_qp_b3
  .byte $6b, $13, $22
  .byte $04, BLACK_QUEEN, $06, BLACK_ROOK, $07, BLACK_ROOK, $16, BLACK_KING
  .byte $27, WHITE_ROOK, $57, WHITE_QUEEN, $77, WHITE_ROOK, $51, WHITE_PAWN
  .byte $34, WHITE_KNIGHT, $36, WHITE_PAWN, $44, BLACK_PAWN
; check_black_bd7_after_qp_ng5
  .byte $68, $24, $13
  .byte $36, WHITE_KNIGHT, $25, BLACK_KNIGHT, $22, BLACK_KNIGHT, $33, BLACK_PAWN
  .byte $43, WHITE_PAWN, $52, WHITE_PAWN, $63, WHITE_KNIGHT, $04, BLACK_KING
; check_black_nb8_after_caro_queen_a6
  .byte $45, $13, $01
  .byte $20, WHITE_QUEEN, $02, BLACK_ROOK, $24, BLACK_BISHOP, $16, BLACK_BISHOP
  .byte $42, BLACK_PAWN
; check_black_dxc4_after_caro_queen_b7_f8
  .byte $25, $b3, $42
  .byte $11, WHITE_QUEEN, $34, WHITE_PAWN, $43, WHITE_PAWN, $24, BLACK_BISHOP
  .byte $05, BLACK_BISHOP
; check_black_qb6_after_caro_qa4_bd2
  .byte $a6, $03, $21
  .byte $40, WHITE_QUEEN, $63, WHITE_BISHOP, $02, BLACK_ROOK, $13, BLACK_KNIGHT
  .byte $24, BLACK_BISHOP, $42, BLACK_PAWN
; check_black_rc7_after_caro_ba5
  .byte $85, $02, $12
  .byte $30, WHITE_BISHOP, $40, WHITE_QUEEN, $13, BLACK_KNIGHT, $24, BLACK_BISHOP
  .byte $20, BLACK_PAWN
; check_black_nh6_after_caro_qb6_bc3
  .byte $46, $06, $27
  .byte $21, BLACK_QUEEN, $52, WHITE_BISHOP, $40, WHITE_QUEEN, $02, BLACK_ROOK
  .byte $24, BLACK_BISHOP, $16, BLACK_BISHOP
; check_black_qb7_after_caro_qb6_na3_nf3
  .byte $a8, $21, $11
  .byte $52, WHITE_BISHOP, $40, WHITE_QUEEN, $50, WHITE_KNIGHT, $55, WHITE_KNIGHT
  .byte $27, BLACK_KNIGHT, $24, BLACK_BISHOP, $06, BLACK_KING, $42, BLACK_PAWN
; check_black_qe4_after_caro_qb7_bxc4
  .byte $ab, $11, $44
  .byte $42, WHITE_BISHOP, $52, WHITE_BISHOP, $40, WHITE_QUEEN, $50, WHITE_KNIGHT
  .byte $55, WHITE_KNIGHT, $27, BLACK_KNIGHT, $24, BLACK_BISHOP, $16, BLACK_BISHOP
  .byte $34, WHITE_PAWN, $22, EMPTY_PIECE, $33, EMPTY_PIECE
; check_black_nde5_after_caro_qe4
  .byte $46, $93, $34
  .byte $44, BLACK_QUEEN, $27, BLACK_KNIGHT, $24, BLACK_BISHOP, $16, BLACK_BISHOP
  .byte $40, WHITE_QUEEN, $64, WHITE_BISHOP
; check_black_bxe5_after_caro_nxe5
  .byte $64, $1e, $34
  .byte $44, BLACK_QUEEN, $27, BLACK_KNIGHT, $24, BLACK_BISHOP, $64, WHITE_BISHOP
; check_black_nd5_after_queenside_b5
  .byte $45, $25, $33
  .byte $42, BLACK_PAWN, $31, WHITE_PAWN, $45, WHITE_BISHOP, $52, WHITE_KNIGHT
  .byte $55, WHITE_KNIGHT
; check_black_f6_after_queenside_be5
  .byte $24, $15, $25
  .byte $34, WHITE_BISHOP, $33, BLACK_KNIGHT, $31, WHITE_PAWN, $42, BLACK_PAWN
; check_black_nxc3_after_bxh8
  .byte $44, $3b, $52
  .byte $07, BLACK_ROOK, $34, WHITE_KNIGHT, $22, WHITE_PAWN, $42, BLACK_PAWN
; check_black_nxc3_after_bxh8_forced
  .byte $44, $3b, $52
  .byte $07, WHITE_BISHOP, $34, WHITE_KNIGHT, $22, WHITE_PAWN, $42, BLACK_PAWN
; check_black_nxc3_after_bxh8_quiet
  .byte $44, $3b, $52
  .byte $07, WHITE_BISHOP, $31, BLACK_PAWN, $42, BLACK_PAWN, $34, EMPTY_PIECE
; check_black_e6_after_poisoned_nxc3
  .byte $27, $14, $24
  .byte $52, BLACK_KNIGHT, $73, WHITE_QUEEN, $74, WHITE_KING, $34, WHITE_KNIGHT
  .byte $22, WHITE_PAWN, $42, WHITE_BISHOP, $43, WHITE_PAWN
; check_black_qc7_after_poisoned_nxc3_e6
  .byte $a6, $03, $12
  .byte $52, BLACK_KNIGHT, $55, WHITE_QUEEN, $34, WHITE_KNIGHT, $22, WHITE_PAWN
  .byte $24, BLACK_PAWN, $04, BLACK_KING
; check_black_bd6_after_poisoned_qc7
  .byte $68, $05, $23
  .byte $12, BLACK_QUEEN, $34, WHITE_KNIGHT, $22, WHITE_PAWN, $42, WHITE_BISHOP
  .byte $52, WHITE_PAWN, $55, WHITE_QUEEN, $24, BLACK_PAWN, $04, BLACK_KING
; check_black_bxe5_after_poisoned_bd6
  .byte $66, $2b, $34
  .byte $12, BLACK_QUEEN, $24, BLACK_BISHOP, $25, WHITE_QUEEN, $22, WHITE_PAWN
  .byte $52, WHITE_PAWN, $04, BLACK_KING
; check_black_bb7_after_ne5_bxh8
  .byte $65, $02, $11
  .byte $07, WHITE_BISHOP, $34, WHITE_KNIGHT, $22, BLACK_KNIGHT, $33, BLACK_KNIGHT
  .byte $31, BLACK_PAWN
; check_black_ng6_after_philidor_f4
  .byte $46, $34, $26
  .byte $25, BLACK_KNIGHT, $14, BLACK_QUEEN, $06, BLACK_KING, $44, WHITE_PAWN
  .byte $45, WHITE_PAWN, $64, WHITE_BISHOP
; check_black_h6_against_bishop_g5
  .byte $27, $17, $27
  .byte $25, BLACK_BISHOP, $34, BLACK_KNIGHT, $43, WHITE_KNIGHT, $56, WHITE_BISHOP
  .byte $52, WHITE_KNIGHT, $64, WHITE_BISHOP, $06, BLACK_KING
; check_black_re8_in_re3_rook_line
  .byte $84, $05, $04
  .byte $54, WHITE_ROOK, $53, WHITE_BISHOP, $33, WHITE_PAWN, $13, BLACK_BISHOP
; check_black_rc8_after_caro_queen_raid
  .byte $83, $00, $02
  .byte $22, WHITE_QUEEN, $42, BLACK_PAWN, $24, BLACK_BISHOP
; check_black_bf5_after_caro_f6_nf4
  .byte $63, $24, $35
  .byte $22, WHITE_QUEEN, $45, WHITE_KNIGHT, $25, BLACK_PAWN
; check_black_dxc4_after_caro_queen_raid
  .byte $25, $b3, $42
  .byte $11, WHITE_QUEEN, $34, WHITE_PAWN, $43, WHITE_PAWN, $24, BLACK_BISHOP
  .byte $16, BLACK_BISHOP
; check_black_nf6_after_queen_raid_e6
  .byte $46, $06, $25
  .byte $22, WHITE_QUEEN, $24, WHITE_PAWN, $33, WHITE_PAWN, $35, BLACK_BISHOP
  .byte $16, BLACK_BISHOP, $13, BLACK_KNIGHT
; check_black_h6_after_compact_philidor
  .byte $28, $17, $27
  .byte $35, WHITE_KNIGHT, $13, BLACK_KNIGHT, $25, BLACK_KNIGHT, $14, BLACK_BISHOP
  .byte $53, WHITE_BISHOP, $52, WHITE_KNIGHT, $06, BLACK_KING, $76, WHITE_KING
; check_black_nxd5_after_philidor_h6_nd5
  .byte $47, $2d, $33
  .byte $35, WHITE_KNIGHT, $13, BLACK_KNIGHT, $14, BLACK_BISHOP, $53, WHITE_BISHOP
  .byte $06, BLACK_KING, $76, WHITE_KING, $27, BLACK_PAWN
; check_black_h6_after_ne5_philidor
  .byte $28, $17, $27
  .byte $34, BLACK_KNIGHT, $25, BLACK_KNIGHT, $14, BLACK_QUEEN, $02, BLACK_BISHOP
  .byte $06, BLACK_KING, $64, WHITE_BISHOP, $52, WHITE_KNIGHT, $76, WHITE_KING
; check_black_c6_in_castled_bishop_pin
  .byte $27, $12, $22
  .byte $14, BLACK_QUEEN, $34, BLACK_KNIGHT, $25, BLACK_KNIGHT, $36, WHITE_BISHOP
  .byte $52, WHITE_KNIGHT, $64, WHITE_BISHOP, $76, WHITE_KING
; check_black_ne5_before_philidor_castles
  .byte $47, $22, $34
  .byte $12, BLACK_KNIGHT, $14, BLACK_BISHOP, $23, BLACK_PAWN, $43, WHITE_KNIGHT
  .byte $52, WHITE_KNIGHT, $55, WHITE_BISHOP, $04, BLACK_KING
; check_queens_pawn_nd5_against_nb5
  .byte $45, $25, $33
  .byte $31, WHITE_KNIGHT, $24, BLACK_BISHOP, $42, BLACK_PAWN, $43, WHITE_PAWN
  .byte $26, BLACK_PAWN
; check_queens_pawn_bg7_after_b5_push
  .byte $64, $05, $16
  .byte $31, WHITE_PAWN, $42, BLACK_PAWN, $24, BLACK_BISHOP, $26, BLACK_PAWN
; check_queens_pawn_a6_after_b5_a4_c6
  .byte $25, $10, $20
  .byte $31, BLACK_PAWN, $40, WHITE_PAWN, $22, BLACK_PAWN, $42, BLACK_PAWN
  .byte $45, WHITE_BISHOP
; check_sicilian_bishop_check_bd7
  .byte $64, $02, $13
  .byte $31, WHITE_BISHOP, $33, WHITE_PAWN, $25, BLACK_KNIGHT, $32, BLACK_PAWN
; check_sicilian_castled_bishop_g7
  .byte $25, $05, $16
  .byte $22, BLACK_KNIGHT, $31, WHITE_BISHOP, $32, BLACK_PAWN, $26, BLACK_PAWN
  .byte $76, WHITE_KING
; check_queens_pawn_c6_after_b5_a4
  .byte $26, $12, $22
  .byte $31, BLACK_PAWN, $40, WHITE_PAWN, $42, BLACK_PAWN, $43, WHITE_PAWN
  .byte $54, WHITE_PAWN, $55, WHITE_KNIGHT
; check_queens_pawn_b5_after_dxc4
  .byte $25, $11, $31
  .byte $42, BLACK_PAWN, $43, WHITE_PAWN, $54, WHITE_PAWN, $55, WHITE_KNIGHT
  .byte $21, EMPTY_PIECE
; check_queens_pawn_e6_after_bf5
  .byte $25, $14, $24
  .byte $35, BLACK_BISHOP, $42, WHITE_BISHOP, $43, WHITE_PAWN, $54, WHITE_PAWN
  .byte $55, WHITE_KNIGHT
; check_caro_advance_qb6
  .byte $a7, $03, $21
  .byte $22, BLACK_PAWN, $33, BLACK_PAWN, $34, WHITE_PAWN, $43, WHITE_PAWN
  .byte $53, WHITE_BISHOP, $26, BLACK_PAWN, $12, EMPTY_PIECE
; check_caro_advance_bg4
  .byte $69, $02, $46
  .byte $22, BLACK_PAWN, $33, BLACK_PAWN, $34, WHITE_PAWN, $43, WHITE_PAWN
  .byte $55, WHITE_KNIGHT, $26, BLACK_PAWN, $13, EMPTY_PIECE, $24, EMPTY_PIECE
  .byte $35, EMPTY_PIECE
; check_caro_advance_bishop_e6
  .byte $66, $02, $24
  .byte $22, BLACK_PAWN, $33, BLACK_PAWN, $34, WHITE_PAWN, $42, WHITE_PAWN
  .byte $43, WHITE_PAWN, $26, BLACK_PAWN
; check_caro_advance_rb8_after_qxb7
  .byte $86, $00, $01
  .byte $11, WHITE_QUEEN, $24, BLACK_BISHOP, $32, BLACK_PAWN, $34, WHITE_PAWN
  .byte $43, WHITE_PAWN, $33, WHITE_PAWN
; check_caro_advance_g6
  .byte $24, $16, $26
  .byte $22, BLACK_PAWN, $33, BLACK_PAWN, $34, WHITE_PAWN, $43, WHITE_PAWN
; check_queens_pawn_c6_after_nf3
  .byte $23, $12, $22
  .byte $33, BLACK_PAWN, $43, WHITE_PAWN, $55, WHITE_KNIGHT
; check_queens_pawn_g6_after_c6_c4
  .byte $25, $16, $26
  .byte $22, BLACK_PAWN, $33, BLACK_PAWN, $42, WHITE_PAWN, $43, WHITE_PAWN
  .byte $55, WHITE_KNIGHT
; check_queens_pawn_dxc4
  .byte $22, $b3, $42
  .byte $43, WHITE_PAWN, $34, EMPTY_PIECE
; check_center_queen_line_f6
  .byte $25, $15, $25
  .byte $14, BLACK_QUEEN, $34, WHITE_KNIGHT, $33, BLACK_PAWN, $43, WHITE_PAWN
  .byte $44, WHITE_PAWN
; check_center_queen_line_qxe4_after_nd3
  .byte $a6, $94, $44
  .byte $53, WHITE_KNIGHT, $33, BLACK_PAWN, $43, WHITE_PAWN, $25, BLACK_PAWN
  .byte $24, EMPTY_PIECE, $34, EMPTY_PIECE
; check_center_queen_line_qxd5_after_d3_qe2
  .byte $a4, $83, $33
  .byte $44, BLACK_PAWN, $53, WHITE_PAWN, $55, WHITE_KNIGHT, $64, WHITE_QUEEN
; check_center_queen_line_qe7_after_qe2
  .byte $a5, $03, $14
  .byte $33, WHITE_PAWN, $44, BLACK_PAWN, $64, WHITE_QUEEN, $52, WHITE_KNIGHT
  .byte $55, WHITE_KNIGHT
; check_black_qe7_after_early_center_qe2_check
  .byte $a9, $03, $14
  .byte $64, WHITE_QUEEN, $04, BLACK_KING, $41, BLACK_KNIGHT, $33, WHITE_PAWN
  .byte $25, BLACK_KNIGHT, $52, WHITE_KNIGHT, $13, EMPTY_PIECE, $05, BLACK_BISHOP
  .byte $74, WHITE_KING
; check_black_nxd5_after_early_center_be3
  .byte $49, $c1, $33
  .byte $14, BLACK_QUEEN, $64, WHITE_QUEEN, $54, WHITE_BISHOP, $25, BLACK_KNIGHT
  .byte $52, WHITE_KNIGHT, $04, BLACK_KING, $13, EMPTY_PIECE, $02, BLACK_BISHOP
  .byte $05, BLACK_BISHOP
; check_black_nxe3_after_early_center_castles
  .byte $49, $bb, $54
  .byte $72, WHITE_KING, $73, WHITE_ROOK, $64, WHITE_QUEEN, $14, BLACK_QUEEN
  .byte $04, BLACK_KING, $02, BLACK_BISHOP, $05, BLACK_BISHOP, $13, EMPTY_PIECE
  .byte $52, EMPTY_PIECE
; check_black_exd4_after_early_d4
  .byte $25, $b4, $43
  .byte $44, WHITE_PAWN, $13, BLACK_PAWN, $04, BLACK_KING, $74, WHITE_KING
  .byte $55, EMPTY_PIECE
; check_black_nc6_after_e4_e5_nf3
  .byte $46, $01, $22
  .byte $34, BLACK_PAWN, $44, WHITE_PAWN, $55, WHITE_KNIGHT, $13, BLACK_PAWN
  .byte $04, BLACK_KING, $74, WHITE_KING
; check_black_nf6_after_ruy_bb5
  .byte $48, $06, $25
  .byte $31, WHITE_BISHOP, $55, WHITE_KNIGHT, $22, BLACK_KNIGHT, $34, BLACK_PAWN
  .byte $44, WHITE_PAWN, $04, BLACK_KING, $74, WHITE_KING, $13, BLACK_PAWN
; check_black_nxe4_after_ruy_castles
  .byte $49, $a5, $44
  .byte $31, WHITE_BISHOP, $76, WHITE_KING, $75, WHITE_ROOK, $22, BLACK_KNIGHT
  .byte $34, BLACK_PAWN, $04, BLACK_KING, $03, BLACK_QUEEN, $13, BLACK_PAWN
  .byte $05, BLACK_BISHOP
; check_black_nd6_after_ruy_nxe4_d4
  .byte $48, $44, $23
  .byte $31, WHITE_BISHOP, $76, WHITE_KING, $75, WHITE_ROOK, $43, WHITE_PAWN
  .byte $34, BLACK_PAWN, $13, BLACK_PAWN, $22, BLACK_KNIGHT, $04, BLACK_KING
; check_black_nd6_after_ruy_nxe4_re1
  .byte $49, $44, $23
  .byte $74, WHITE_ROOK, $76, WHITE_KING, $31, WHITE_BISHOP, $22, BLACK_KNIGHT
  .byte $34, BLACK_PAWN, $13, BLACK_PAWN, $04, BLACK_KING, $03, BLACK_QUEEN
  .byte $05, BLACK_BISHOP
; check_black_bd7_after_ruy_nxe5
  .byte $69, $02, $13
  .byte $34, WHITE_KNIGHT, $44, BLACK_KNIGHT, $31, WHITE_BISHOP, $43, WHITE_PAWN
  .byte $33, BLACK_PAWN, $22, BLACK_KNIGHT, $05, BLACK_BISHOP, $04, BLACK_KING
  .byte $76, WHITE_KING
; check_black_nb4_after_ruy_cxd5
  .byte $48, $22, $41
  .byte $33, WHITE_PAWN, $44, WHITE_ROOK, $31, WHITE_BISHOP, $14, BLACK_BISHOP
  .byte $06, BLACK_KING, $03, BLACK_QUEEN, $43, WHITE_PAWN, $04, EMPTY_PIECE
; check_black_f5_after_ruy_nfd2
  .byte $28, $15, $35
  .byte $23, BLACK_KNIGHT, $44, BLACK_PAWN, $74, WHITE_ROOK, $76, WHITE_KING
  .byte $14, BLACK_BISHOP, $31, WHITE_BISHOP, $63, WHITE_KNIGHT, $04, BLACK_KING
; check_black_b6_after_ruy_f5_ba4
  .byte $2a, $11, $21
  .byte $44, BLACK_PAWN, $35, BLACK_PAWN, $40, WHITE_BISHOP, $74, WHITE_ROOK
  .byte $76, WHITE_KING, $23, BLACK_KNIGHT, $22, BLACK_KNIGHT, $14, BLACK_BISHOP
  .byte $06, BLACK_KING, $05, BLACK_ROOK
; check_black_nxe4_after_ruy_c5_ndxe4
  .byte $48, $2b, $44
  .byte $40, WHITE_BISHOP, $32, BLACK_PAWN, $35, BLACK_PAWN, $14, BLACK_BISHOP
  .byte $22, BLACK_KNIGHT, $06, BLACK_KING, $74, WHITE_ROOK, $76, WHITE_KING
; check_black_nd4_after_ruy_d5
  .byte $48, $22, $43
  .byte $33, WHITE_PAWN, $32, BLACK_PAWN, $44, BLACK_KNIGHT, $40, WHITE_BISHOP
  .byte $14, BLACK_BISHOP, $06, BLACK_KING, $74, WHITE_ROOK, $76, WHITE_KING
; check_black_bxd6_after_ruy_d6
  .byte $68, $94, $23
  .byte $34, BLACK_KNIGHT, $44, BLACK_KNIGHT, $32, BLACK_PAWN, $35, BLACK_PAWN
  .byte $40, WHITE_BISHOP, $52, WHITE_KNIGHT, $06, BLACK_KING, $76, WHITE_KING
; check_black_dxc6_after_ruy_bxc6
  .byte $28, $9b, $22
  .byte $43, BLACK_PAWN, $23, BLACK_BISHOP, $02, BLACK_BISHOP, $03, BLACK_QUEEN
  .byte $06, BLACK_KING, $52, WHITE_KNIGHT, $35, BLACK_PAWN, $72, WHITE_BISHOP
; check_black_nxd5_after_ruy_nb4_nc3
  .byte $48, $c1, $33
  .byte $52, WHITE_KNIGHT, $44, WHITE_ROOK, $31, WHITE_BISHOP, $14, BLACK_BISHOP
  .byte $06, BLACK_KING, $03, BLACK_QUEEN, $43, WHITE_PAWN, $04, EMPTY_PIECE
; check_black_nf6_after_open_a3
  .byte $46, $06, $25
  .byte $34, BLACK_PAWN, $44, WHITE_PAWN, $55, WHITE_KNIGHT, $50, WHITE_PAWN
  .byte $22, BLACK_KNIGHT, $04, BLACK_KING
; check_black_nf6_after_vienna_knights
  .byte $47, $06, $25
  .byte $34, BLACK_PAWN, $44, WHITE_PAWN, $52, WHITE_KNIGHT, $55, WHITE_KNIGHT
  .byte $22, BLACK_KNIGHT, $04, BLACK_KING, $74, WHITE_KING
; check_black_nd4_after_four_knights_bb5
  .byte $49, $22, $43
  .byte $31, WHITE_BISHOP, $52, WHITE_KNIGHT, $55, WHITE_KNIGHT, $25, BLACK_KNIGHT
  .byte $34, BLACK_PAWN, $44, WHITE_PAWN, $13, BLACK_PAWN, $63, WHITE_PAWN
  .byte $04, BLACK_KING
; check_black_qe7_after_four_knights_nd4_nxe5
  .byte $a9, $03, $14
  .byte $34, WHITE_KNIGHT, $43, BLACK_KNIGHT, $31, WHITE_BISHOP, $52, WHITE_KNIGHT
  .byte $25, BLACK_KNIGHT, $44, WHITE_PAWN, $13, BLACK_PAWN, $05, BLACK_BISHOP
  .byte $04, BLACK_KING
; check_black_nxb5_after_four_knights_qe7_nf3
  .byte $48, $cb, $31
  .byte $14, BLACK_QUEEN, $55, WHITE_KNIGHT, $52, WHITE_KNIGHT, $25, BLACK_KNIGHT
  .byte $44, WHITE_PAWN, $13, BLACK_PAWN, $05, BLACK_BISHOP, $04, BLACK_KING
; check_black_bb4_after_four_knights_d4
  .byte $68, $05, $41
  .byte $43, WHITE_PAWN, $44, WHITE_PAWN, $52, WHITE_KNIGHT, $55, WHITE_KNIGHT
  .byte $22, BLACK_KNIGHT, $25, BLACK_KNIGHT, $34, BLACK_PAWN, $04, BLACK_KING
; check_black_h6_after_four_knights_bg5
  .byte $2a, $17, $27
  .byte $36, WHITE_BISHOP, $41, BLACK_BISHOP, $43, WHITE_PAWN, $44, WHITE_PAWN
  .byte $52, WHITE_KNIGHT, $55, WHITE_KNIGHT, $22, BLACK_KNIGHT, $25, BLACK_KNIGHT
  .byte $34, BLACK_PAWN, $04, BLACK_KING
; check_black_qxf6_after_four_knights_bxf6
  .byte $a9, $8b, $25
  .byte $41, BLACK_BISHOP, $27, BLACK_PAWN, $43, WHITE_PAWN, $44, WHITE_PAWN
  .byte $52, WHITE_KNIGHT, $55, WHITE_KNIGHT, $22, BLACK_KNIGHT, $34, BLACK_PAWN
  .byte $04, BLACK_KING
; check_black_bb4_after_four_knights_d5_bb5
  .byte $69, $05, $41
  .byte $31, WHITE_BISHOP, $33, BLACK_PAWN, $34, BLACK_PAWN, $43, WHITE_PAWN
  .byte $44, WHITE_PAWN, $52, WHITE_KNIGHT, $55, WHITE_KNIGHT, $22, BLACK_KNIGHT
  .byte $25, BLACK_KNIGHT
; check_black_bd7_after_four_knights_nxd4
  .byte $67, $02, $13
  .byte $31, WHITE_BISHOP, $33, BLACK_PAWN, $43, WHITE_KNIGHT, $44, WHITE_PAWN
  .byte $52, WHITE_KNIGHT, $22, BLACK_KNIGHT, $25, BLACK_KNIGHT
; check_black_castles_after_four_knights_nxe5
  .byte $cb, $04, $06
  .byte $07, BLACK_ROOK, $05, EMPTY_PIECE, $34, WHITE_KNIGHT, $33, BLACK_PAWN
  .byte $41, BLACK_BISHOP, $31, WHITE_BISHOP, $22, BLACK_KNIGHT, $25, BLACK_KNIGHT
  .byte $43, WHITE_PAWN, $44, WHITE_PAWN, $52, WHITE_KNIGHT
; check_black_nf6_after_italian_bc4
  .byte $47, $06, $25
  .byte $34, BLACK_PAWN, $44, WHITE_PAWN, $55, WHITE_KNIGHT, $42, WHITE_BISHOP
  .byte $22, BLACK_KNIGHT, $04, BLACK_KING, $13, BLACK_PAWN
; check_black_bc5_after_italian_nc3
  .byte $69, $05, $32
  .byte $42, WHITE_BISHOP, $52, WHITE_KNIGHT, $55, WHITE_KNIGHT, $22, BLACK_KNIGHT
  .byte $25, BLACK_KNIGHT, $34, BLACK_PAWN, $44, WHITE_PAWN, $04, BLACK_KING
  .byte $13, BLACK_PAWN
; check_black_na5_after_two_knights_exd5
  .byte $48, $22, $30
  .byte $33, WHITE_PAWN, $36, WHITE_KNIGHT, $42, WHITE_BISHOP, $25, BLACK_KNIGHT
  .byte $34, BLACK_PAWN, $44, EMPTY_PIECE, $13, EMPTY_PIECE, $04, BLACK_KING
; check_black_nxd5_after_exd5
  .byte $45, $a5, $33
  .byte $34, BLACK_PAWN, $22, BLACK_KNIGHT, $50, WHITE_PAWN, $53, WHITE_PAWN
  .byte $44, EMPTY_PIECE
; check_black_nf6_after_italian_qh5_attack
  .byte $4d, $33, $25
  .byte $37, WHITE_QUEEN, $17, WHITE_BISHOP, $07, BLACK_KING, $05, BLACK_ROOK
  .byte $23, BLACK_BISHOP, $30, BLACK_KNIGHT, $36, WHITE_KNIGHT, $43, BLACK_PAWN
  .byte $52, WHITE_PAWN, $75, WHITE_ROOK, $76, WHITE_KING, $16, BLACK_PAWN
  .byte $15, BLACK_PAWN
; check_philidor_exd4_after_d4
  .byte $23, $b4, $43
  .byte $44, WHITE_PAWN, $55, WHITE_KNIGHT, $23, BLACK_PAWN
; check_philidor_be7_after_nc3
  .byte $65, $05, $14
  .byte $23, BLACK_PAWN, $25, BLACK_KNIGHT, $43, WHITE_KNIGHT, $52, WHITE_KNIGHT
  .byte $44, WHITE_PAWN
; check_philidor_castles_after_nf5
  .byte $c7, $04, $06
  .byte $35, WHITE_KNIGHT, $14, BLACK_BISHOP, $13, BLACK_KNIGHT, $23, BLACK_PAWN
  .byte $25, BLACK_KNIGHT, $07, BLACK_ROOK, $05, EMPTY_PIECE
; check_philidor_ng4_after_bh6
  .byte $45, $34, $46
  .byte $27, WHITE_BISHOP, $25, BLACK_KNIGHT, $23, BLACK_PAWN, $24, EMPTY_PIECE
  .byte $35, EMPTY_PIECE
; check_black_initial_e5
  .byte $26, $9c, $3c
  .byte $44, WHITE_PAWN, $12, BLACK_PAWN, $13, BLACK_PAWN, $01, BLACK_KNIGHT
  .byte $06, BLACK_KNIGHT, $55, EMPTY_PIECE
; check_black_caro_d5_after_d3
  .byte $26, $13, $33
  .byte $44, WHITE_PAWN, $53, WHITE_PAWN, $22, BLACK_PAWN, $14, BLACK_PAWN
  .byte $04, BLACK_KING, $03, BLACK_QUEEN
; check_scandi_queen_recapture
  .byte $a3, $83, $33
  .byte $14, BLACK_PAWN, $43, EMPTY_PIECE, $64, EMPTY_PIECE
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
.endif

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
  lda #NEG_INFINITY_HI
  sta $ed
  sta AspirationAlphaHi
  lda #POS_INFINITY
  sta $e9
  sta AspirationBeta
  lda #POS_INFINITY_HI
  sta $ee
  sta AspirationBetaHi
  rts

__ai_search_use_aspiration_0:
  inc SearchAspirationAttempts
  lda #$01
  sta SearchAspirationActive

; alpha = IterScore - ASPIRATION_DELTA (16-bit). Clamp underflow to -infinity.
  lda IterScore
  sec
  sbc #<ASPIRATION_DELTA
  sta $e8
  lda IterScoreHi
  sbc #>ASPIRATION_DELTA
  sta $ed
  bvc __ai_search_asp_alpha_ok_0
  lda #NEG_INFINITY
  sta $e8
  lda #NEG_INFINITY_HI
  sta $ed
__ai_search_asp_alpha_ok_0:
  lda $e8
  sta AspirationAlpha
  lda $ed
  sta AspirationAlphaHi

; beta = IterScore + ASPIRATION_DELTA (16-bit). Clamp overflow to +infinity.
  lda IterScore
  clc
  adc #<ASPIRATION_DELTA
  sta $e9
  lda IterScoreHi
  adc #>ASPIRATION_DELTA
  sta $ee
  bvc __ai_search_asp_beta_ok_0
  lda #POS_INFINITY
  sta $e9
  lda #POS_INFINITY_HI
  sta $ee
__ai_search_asp_beta_ok_0:
  lda $e9
  sta AspirationBeta
  lda $ee
  sta AspirationBetaHi
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
; Fail low when score <= alpha (16-bit: IterScore - AspirationAlpha <= 0).
  lda IterScore
  sec
  sbc AspirationAlpha
  sta $f0
  lda IterScoreHi
  sbc AspirationAlphaHi
  sta $f1
  ora $f0
  beq __ai_search_aspiration_failed_0; equal -> fail low
  lda $f1
  bvc __ai_search_asp_low_no_ov_0
  eor #$80
__ai_search_asp_low_no_ov_0:
  bmi __ai_search_aspiration_failed_0

; Fail high when score >= beta (16-bit: IterScore - AspirationBeta >= 0).
  lda IterScore
  sec
  sbc AspirationBeta
  lda IterScoreHi
  sbc AspirationBetaHi
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
;
; SanitizeHostState
; Hosts own Board88, king squares, castling rights, and the en-passant
; square. A stale or corrupt value makes the engine search a position that
; does not exist and emit "legal" moves for it. Re-derive what the board can
; prove and drop whatever it cannot.
; Clobbers: A, X
;
SanitizeHostState:
  ldx #$77
__ai_search_sanitize_scan_0:
  txa
  and #$88
  bne __ai_search_sanitize_next_0
  lda Board88, x
  cmp #WHITE_KING
  bne __ai_search_sanitize_not_wk_0
  stx whitekingsq
  jmp __ai_search_sanitize_next_0
__ai_search_sanitize_not_wk_0:
  cmp #BLACK_KING
  bne __ai_search_sanitize_next_0
  stx blackkingsq
__ai_search_sanitize_next_0:
  dex
  bpl __ai_search_sanitize_scan_0

; Castling rights are only meaningful while the king and rook sit on their
; home squares.
  lda Board88 + $74
  cmp #WHITE_KING
  beq __ai_search_sanitize_wk_home_0
  lda castlerights
  and #<~(CASTLE_WK | CASTLE_WQ)
  sta castlerights
  jmp __ai_search_sanitize_black_castle_0
__ai_search_sanitize_wk_home_0:
  lda Board88 + $77
  cmp #WHITE_ROOK
  beq __ai_search_sanitize_wq_check_0
  lda castlerights
  and #<~CASTLE_WK
  sta castlerights
__ai_search_sanitize_wq_check_0:
  lda Board88 + $70
  cmp #WHITE_ROOK
  beq __ai_search_sanitize_black_castle_0
  lda castlerights
  and #<~CASTLE_WQ
  sta castlerights

__ai_search_sanitize_black_castle_0:
  lda Board88 + $04
  cmp #BLACK_KING
  beq __ai_search_sanitize_bk_home_0
  lda castlerights
  and #<~(CASTLE_BK | CASTLE_BQ)
  sta castlerights
  jmp __ai_search_sanitize_enpassant_0
__ai_search_sanitize_bk_home_0:
  lda Board88 + $07
  cmp #BLACK_ROOK
  beq __ai_search_sanitize_bq_check_0
  lda castlerights
  and #<~CASTLE_BK
  sta castlerights
__ai_search_sanitize_bq_check_0:
  lda Board88 + $00
  cmp #BLACK_ROOK
  beq __ai_search_sanitize_enpassant_0
  lda castlerights
  and #<~CASTLE_BQ
  sta castlerights

__ai_search_sanitize_enpassant_0:
; A valid en-passant target is an empty square on the third rank of the side
; that just moved, with that side's pawn directly behind it.
  lda enpassantsq
  cmp #$ff
  beq __ai_search_sanitize_done_0
  and #$88
  bne __ai_search_sanitize_clear_ep_0
  ldx enpassantsq
  lda Board88, x
  cmp #EMPTY_PIECE
  bne __ai_search_sanitize_clear_ep_0
  lda SearchSide
  beq __ai_search_sanitize_ep_black_0
; White to move: target must be on row $20 (rank 6) with a black pawn below.
  txa
  and #$f0
  cmp #$20
  bne __ai_search_sanitize_clear_ep_0
  lda Board88 + $10, x
  cmp #BLACK_PAWN
  bne __ai_search_sanitize_clear_ep_0
  jmp __ai_search_sanitize_done_0
__ai_search_sanitize_ep_black_0:
; Black to move: target must be on row $50 (rank 3) with a white pawn above.
  txa
  and #$f0
  cmp #$50
  bne __ai_search_sanitize_clear_ep_0
  lda Board88 - $10, x
  cmp #WHITE_PAWN
  bne __ai_search_sanitize_clear_ep_0
  jmp __ai_search_sanitize_done_0
__ai_search_sanitize_clear_ep_0:
  lda #$ff
  sta enpassantsq
__ai_search_sanitize_done_0:
  rts

;
; EnsureBestMoveLegal
; Final output guard: the move handed to the host must be legal in the root
; position. The common case validates only the moving piece (a few thousand
; cycles); the full legal-move regeneration is paid only when a repair is
; actually needed, which indicates an upstream bug or host state corruption.
; A position with no legal moves reports no-move.
; Clobbers: A, X, Y, $e2-$e6, move list
;
EnsureBestMoveLegal:
  lda BestMoveFrom
  cmp #$ff
  beq __ai_search_best_legal_done_0

  jsr ValidateBestMove
  bcs __ai_search_best_legal_done_0

  inc SearchBestMoveRepairs
  jsr GenerateLegalMoves
  lda MoveCount
  beq __ai_search_best_legal_none_0
  lda MoveListFrom
  sta BestMoveFrom
  lda MoveListTo
  sta BestMoveTo
  rts
__ai_search_best_legal_none_0:
  lda #$ff
  sta BestMoveFrom
  sta BestMoveTo
__ai_search_best_legal_done_0:
  rts

;
; ValidateBestMove
; Check that BestMoveFrom/BestMoveTo is a legal move for SearchSide by
; generating only the moving piece's moves and applying the same castling
; and king-safety filters as FilterLegalMoves.
; Output: carry set = legal, carry clear = not legal.
; Clobbers: A, X, Y, $e2-$e6, move list
;
ValidateBestMove:
  lda BestMoveFrom
  and #$88
  bne __ai_search_validate_fail_near_0

  ldx BestMoveFrom
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_search_validate_fail_near_0
  sta $e5
  and #WHITE_COLOR
  cmp SearchSide
  beq __ai_search_validate_side_ok_0
__ai_search_validate_fail_near_0:
  jmp __ai_search_validate_fail_0
__ai_search_validate_side_ok_0:

  jsr ClearMoveList
  lda $e5
  and #$07
  sta $e6
  lda BestMoveFrom
  ldx SearchSide
  ldy $e6
  cpy #PAWN_TYPE
  bne __ai_search_validate_not_pawn_0
  jsr GeneratePawnMoves
  jmp __ai_search_validate_scan_0
__ai_search_validate_not_pawn_0:
  cpy #KNIGHT_TYPE
  bne __ai_search_validate_not_knight_0
  jsr GenerateKnightMoves
  jmp __ai_search_validate_scan_0
__ai_search_validate_not_knight_0:
  cpy #BISHOP_TYPE
  bne __ai_search_validate_not_bishop_0
  jsr GenerateBishopMoves
  jmp __ai_search_validate_scan_0
__ai_search_validate_not_bishop_0:
  cpy #ROOK_TYPE
  bne __ai_search_validate_not_rook_0
  jsr GenerateRookMoves
  jmp __ai_search_validate_scan_0
__ai_search_validate_not_rook_0:
  cpy #QUEEN_TYPE
  bne __ai_search_validate_not_queen_0
  jsr GenerateQueenMoves
  jmp __ai_search_validate_scan_0
__ai_search_validate_not_queen_0:
  cpy #KING_TYPE
  bne __ai_search_validate_fail_0
; GenerateKingMoves falls through into castling generation.
  jsr GenerateKingMoves

__ai_search_validate_scan_0:
  ldx #$00
__ai_search_validate_scan_loop_0:
  cpx MoveCount
  beq __ai_search_validate_fail_0
  lda MoveListFrom, x
  cmp BestMoveFrom
  bne __ai_search_validate_scan_next_0
  lda MoveListTo, x
  eor BestMoveTo
  and #$7f
  beq __ai_search_validate_found_0
__ai_search_validate_scan_next_0:
  inx
  bne __ai_search_validate_scan_loop_0
  clc
  rts

__ai_search_validate_found_0:
  lda MoveListFrom, x
  sta $e2
  lda MoveListTo, x
  and #$7f
  sta $e3
  lda MoveListTo, x
  sta $e4

  jsr IsCastlingMove
  bcc __ai_search_validate_not_castle_0
  jsr CheckCastlingLegal
  bcs __ai_search_validate_fail_0

__ai_search_validate_not_castle_0:
  lda #$01
  sta PieceListUpdateDisabled
  lda $e2
  ldx $e4
  jsr MakeMove
  jsr IsSearchKingInCheck
  php
  lda $e2
  ldx $e4
  jsr UnmakeMove
  lda #$00
  sta PieceListUpdateDisabled
  plp
  bcs __ai_search_validate_fail_0
  sec
  rts

__ai_search_validate_fail_0:
  clc
  rts

FindBestMove:
; NOTE: With $35 (HIRAM=0), $A000-$BFFF is already RAM - no banking needed

; Initialize search
  jsr InitSearch
  jsr SanitizeHostState

  jsr AICheckGameState
  sta EngineGameState
  cmp #GAME_NORMAL
  beq __ai_search_game_playable_0
  cmp #GAME_CHECK
  beq __ai_search_game_playable_0
  jmp FinishBestMoveNoMove

__ai_search_game_playable_0:

; Mate ends the game. Check it before material, book, or endgame shortcuts so
; no tactical convenience move can steal an immediate win.
  jsr TryRootMateInOne
  bcs __ai_search_finish_root_shortcut_0
__ai_search_no_root_mate_0:

  jsr TryRootAvoidMateThreatMove
  bcs __ai_search_finish_root_shortcut_0
__ai_search_no_root_mate_threat_0:

; EXP2 REVERTED: disabling the tactical shortcuts dropped on-chip strength
; (~1072 -> ~934 vs SF-1320). They are net-positive safety nets that catch
; obvious tactics the depth/timeout-limited search fumbles. Kept.

; Opening theory (book) outranks the crude root positional heuristics
; (center-pawn push / bishop recapture). Those moved below the book probe and
; now only fire on a book miss; mate safety and tactics still come first.
  jsr TryImmediateQueenPromotionMove
  bcs __ai_search_finish_root_shortcut_0
__ai_search_no_immediate_promotion_0:

  jsr TryRootMajorCaptureMove
  bcs __ai_search_finish_root_shortcut_0
__ai_search_no_root_major_capture_0:

  jsr TryRootWinningCaptureMove
  bcs __ai_search_finish_root_shortcut_0
__ai_search_no_root_winning_capture_0:

  jsr TryRootSaveAttackedMajorMove
  bcs __ai_search_finish_root_shortcut_0
__ai_search_no_root_save_major_0:

  jsr TrySparseQueenCaptureMove
  bcs __ai_search_finish_root_shortcut_0
__ai_search_no_sparse_queen_capture_0:

  jsr TrySparseWinningCaptureMove
  bcs __ai_search_finish_root_shortcut_0
__ai_search_no_sparse_winning_capture_0:

  jsr TrySimpleRookPawnEndgameMove
  bcs __ai_search_finish_root_shortcut_0
__ai_search_no_simple_endgame_move_0:

  jsr TrySimpleKingPawnEndgameMove
  bcs __ai_search_finish_root_shortcut_0
__ai_search_no_simple_king_pawn_move_0:

  jsr TryLoneKingPawnConversionMove
  bcs __ai_search_finish_root_shortcut_0
__ai_search_no_lone_king_conversion_0:

  jsr TryBoxedKingPawnStormMove
  bcc __ai_search_no_boxed_king_pawn_storm_0
__ai_search_finish_root_shortcut_0:
  jmp FinishBestMoveZero
__ai_search_no_boxed_king_pawn_storm_0:

; If a piece is already under direct pawn attack, trust search over the
; compact book. This avoids playing memorized development moves while a
; knight or bishop is hanging.
  lda SearchSide
  jsr SideHasPawnAttackedPiece
  bcs __ai_search_no_book_move_0
  lda SearchSide
  jsr SideHasMinorAttackedMajor
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

; Book missed (or a piece is hanging / a collision was rejected): only now fall
; back to the crude root opening heuristics, before paying for a full search.
  jsr TryRootOpeningCenterPawnMove
  bcs __ai_search_book_fallback_shortcut_0
__ai_search_no_opening_center_pawn_0:

  jsr TryRootDevelopingBishopRecaptureMove
  bcc __ai_search_no_bishop_recap_move_0
__ai_search_book_fallback_shortcut_0:
  jmp FinishBestMoveZero
__ai_search_no_bishop_recap_move_0:

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
  bne __ai_search_have_root_moves_0
  jmp __ai_search_no_moves_time_0

__ai_search_have_root_moves_0:
; Initialize BestMove to a sane legal fallback before iterative search. If the
; search fails to lift any move above the score floor, do not keep a queen hang.
  jsr SetSafeRootFallbackMove
  lda BestMoveFrom
  sta CommittedBestFrom
  lda BestMoveTo
  sta CommittedBestTo

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
  lda $ec
  sta IterScoreHi

  jsr CheckAspirationFailure
  bcc __ai_search_iteration_score_ready_0

; Aspiration failed. Keep the TT bounds, widen fully, and re-search once.
  inc SearchAspirationRetries
  jsr SetupFullSearchWindow
  lda IterDepth
  jsr Negamax
  sta IterScore
  lda $ec
  sta IterScoreHi

__ai_search_iteration_score_ready_0:
  lda IterDepth
  sta SearchCompletedDepth

; Commit this iteration's best move for external supervisors. BestMoveFrom/To
; is scratch during probes and partial iterations; this pair is only ever a
; fully searched root move.
  lda BestMoveFrom
  sta CommittedBestFrom
  lda BestMoveTo
  sta CommittedBestTo

; Update thinking display with current depth and best move
  jsr EngineOnSearchIteration

; FIX 1 (mate distance): found a forced mate at the root -> stop deepening. The
; mating score is no longer exactly +MATE_SCORE (distance is encoded), so test
; "is a winning mate" = IterScore > STATIC_EVAL_LIMIT (16-bit signed).
  lda IterScoreHi
  bmi __ai_search_check_max_depth_0; Negative scores are not winning mates
  lda IterScore; IterScore - STATIC_EVAL_LIMIT
  sec
  sbc #<STATIC_EVAL_LIMIT
  sta $f0
  lda IterScoreHi
  sbc #>STATIC_EVAL_LIMIT
  sta $f1
  ora $f0
  beq __ai_search_check_max_depth_0; diff == 0 -> not strictly greater
  lda $f1
  bvc __ai_search_id_mate_no_ov_0
  eor #$80
__ai_search_id_mate_no_ov_0:
  bpl __ai_search_time_done_0; IterScore > STATIC_EVAL_LIMIT -> forced mate

__ai_search_check_max_depth_0:
; Increment depth for next iteration
  inc IterDepth
  lda IterDepth
  cmp MaxSearchDepth
  bcc __ai_search_time_iter_loop_0

__ai_search_time_done_0:
  jsr EnsureBestMoveLegal
  jsr RememberBestMove
  lda IterScoreHi
  sta $ec; 16-bit score hi for callers that consume it
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
  jsr EnsureBestMoveLegal
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
IterScoreHi:
  .res 1

.segment "CODE"

AspirationAlpha:
  .byte NEG_INFINITY
AspirationAlphaHi:
  .byte NEG_INFINITY_HI
AspirationBeta:
  .byte POS_INFINITY
AspirationBetaHi:
  .byte POS_INFINITY_HI

.segment "BSS"

SearchAspirationActive:
  .res 1

.segment "CODE"
.endif
