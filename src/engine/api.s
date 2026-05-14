; Generated ca65 port from Chess/engine/api.asm.
; Keep source changes in this repository in ca65 syntax.

; import-once was handled by the ca65 include topology

.segment "CODE"

; 
; Stable public entry points for host applications. The older routine names are
; kept for the C64 app and tests; Nova can target these Chess* labels.
; 

ChessInitPieceLists:
  jmp InitPieceLists

ChessGenerateLegalMoves:
  jsr InitSearch
  jmp GenerateLegalMoves

.ifndef CHESS_RULES_ONLY
ChessFindBestMove:
  jmp FindBestMove

ChessPonderClear:
  lda #$00
  sta PonderValid
  lda #$ff
  sta PonderPredictedFrom
  sta PonderPredictedTo
  sta PonderReplyFrom
  sta PonderReplyTo
  clc
  rts

ChessPonderSearch:
  sta $f0
  stx $f1

  lda currentplayer
  sta PonderSavedCurrentPlayer
  lda BestMoveFrom
  sta PonderSavedBestFrom
  lda BestMoveTo
  sta PonderSavedBestTo
  lda LastEngineMoveFrom
  sta PonderSavedLastFrom
  lda LastEngineMoveTo
  sta PonderSavedLastTo
  lda EngineGameState
  sta PonderSavedGameState

  jsr ChessPonderClear
  lda $f0
  sta PonderPredictedFrom
  ldx $f1
  stx PonderPredictedTo
  lda PonderPredictedFrom
  cmp #$ff
  bne __engine_api_ponder_have_move_0
  clc
  rts

__engine_api_ponder_have_move_0:
  jsr EnsureZobristTablesInitialized
  jsr InitSearch

  lda PonderPredictedFrom
  ldx PonderPredictedTo
  jsr MakeMove

  ldx #$05
__engine_api_ponder_save_undo_0:
  lda UndoStack, x
  sta PonderUndo, x
  dex
  bpl __engine_api_ponder_save_undo_0

  lda currentplayer
  beq __engine_api_ponder_black_predicted_0
  lda #BLACKS_TURN
  sta currentplayer
  jmp __engine_api_ponder_side_ready_0
__engine_api_ponder_black_predicted_0:
  lda #WHITES_TURN
  sta currentplayer

__engine_api_ponder_side_ready_0:
  jsr FindBestMove

  lda BestMoveFrom
  cmp #$ff
  beq __engine_api_ponder_no_reply_0
  sta PonderReplyFrom
  lda BestMoveTo
  sta PonderReplyTo
  lda #$01
  sta PonderValid
  jmp __engine_api_ponder_restore_0

__engine_api_ponder_no_reply_0:
  lda #$00
  sta PonderValid

__engine_api_ponder_restore_0:
  lda PonderSavedCurrentPlayer
  sta currentplayer

  ldx #$05
__engine_api_ponder_restore_undo_0:
  lda PonderUndo, x
  sta UndoStack, x
  dex
  bpl __engine_api_ponder_restore_undo_0

  lda #$01
  sta SearchDepth
  lda PonderSavedCurrentPlayer
  beq __engine_api_ponder_restore_black_0
  lda #BLACK_COLOR
  jmp __engine_api_ponder_restore_side_ready_0
__engine_api_ponder_restore_black_0:
  lda #WHITE_COLOR
__engine_api_ponder_restore_side_ready_0:
  sta SearchSide

  lda PonderPredictedFrom
  ldx PonderPredictedTo
  jsr UnmakeMove
  lda #$00
  sta SearchDepth

  lda PonderSavedBestFrom
  sta BestMoveFrom
  lda PonderSavedBestTo
  sta BestMoveTo
  lda PonderSavedLastFrom
  sta LastEngineMoveFrom
  lda PonderSavedLastTo
  sta LastEngineMoveTo
  lda PonderSavedGameState
  sta EngineGameState

  lda PonderValid
  beq __engine_api_ponder_search_miss_0
  sec
  rts
__engine_api_ponder_search_miss_0:
  clc
  rts

ChessPonderUse:
  sta $f0
  stx $f1
  lda PonderValid
  beq __engine_api_ponder_use_miss_0
  lda $f0
  cmp PonderPredictedFrom
  bne __engine_api_ponder_use_miss_0
  lda $f1
  cmp PonderPredictedTo
  bne __engine_api_ponder_use_miss_0

  lda PonderReplyFrom
  sta BestMoveFrom
  lda PonderReplyTo
  sta BestMoveTo
  lda #$00
  sta PonderValid
  sec
  rts

__engine_api_ponder_use_miss_0:
  lda #$00
  sta PonderValid
  clc
  rts
.endif

ChessMakeMove:
  jmp MakeMove

ChessBeginGame:
  jsr ClearPositionHistory
  lda #$01
  sta FullmoveNumber
  lda #$00
  sta FullmoveNumber + 1
  jsr InitPieceLists
  jsr ComputeZobristHash
  jsr RecordPosition
  jmp ChessCheckGameState

ChessCommitMove:
  sta CommitMoveFrom
  stx CommitMoveTo
  txa
  and #$7f
  sta CommitMoveCleanTo

  jsr EnsureZobristTablesInitialized
  jsr InitSearch

  lda #$00
  sta CommitMoveWasPawn
  sta CommitMoveWasCapture

  ldy CommitMoveFrom
  lda Board88, y
  and #$07
  cmp #PAWN_TYPE
  bne __engine_api_commit_not_pawn_0
  lda #$01
  sta CommitMoveWasPawn
__engine_api_commit_not_pawn_0:

  ldy CommitMoveCleanTo
  lda Board88, y
  cmp #EMPTY_PIECE
  beq __engine_api_commit_check_ep_0
  lda #$01
  sta CommitMoveWasCapture
  jmp __engine_api_commit_flags_ready_0

__engine_api_commit_check_ep_0:
  lda CommitMoveWasPawn
  beq __engine_api_commit_flags_ready_0
  lda CommitMoveCleanTo
  cmp enpassantsq
  bne __engine_api_commit_flags_ready_0
  lda #$01
  sta CommitMoveWasCapture

__engine_api_commit_flags_ready_0:
  lda CommitMoveFrom
  ldx CommitMoveTo
  jsr MakeMove

; MakeMove is also used by search, where SearchDepth tracks recursion. A
; committed game move is permanent, so reset the search frame after applying it.
  lda #$00
  sta SearchDepth

  lda CommitMoveWasCapture
  beq __engine_api_commit_no_capture_0
  sec
  jmp __engine_api_commit_clock_ready_0
__engine_api_commit_no_capture_0:
  clc
__engine_api_commit_clock_ready_0:
  lda CommitMoveWasPawn
  jsr UpdateHalfmoveClock

  lda currentplayer
  beq __engine_api_commit_black_moved_0
  lda #BLACKS_TURN
  sta currentplayer
  jmp __engine_api_commit_side_done_0

__engine_api_commit_black_moved_0:
  inc FullmoveNumber
  bne __engine_api_commit_fullmove_done_0
  inc FullmoveNumber + 1
__engine_api_commit_fullmove_done_0:
  lda #WHITES_TURN
  sta currentplayer

__engine_api_commit_side_done_0:
  jsr InitPieceLists
  jsr ComputeZobristHash
  jsr RecordPosition
  jmp ChessCheckGameState

ChessUnmakeMove:
  jmp UnmakeMove

ChessIsSquareAttacked:
  jmp IsSquareAttacked

ChessCheckKingInCheck:
  jmp CheckKingInCheck

ChessRecordPosition:
  jsr EnsureZobristTablesInitialized
  jsr ComputeZobristHash
  jmp RecordPosition

ChessClearPositionHistory:
  jmp ClearPositionHistory

ChessCheckRepetition:
  jsr EnsureZobristTablesInitialized
  jsr ComputeZobristHash
  jmp CheckRepetition

ChessCheckGameState:
  jsr InitSearch
  jsr AICheckGameState
  sta EngineGameState
  rts

.segment "BSS"

CommitMoveFrom:
  .res 1
CommitMoveTo:
  .res 1
CommitMoveCleanTo:
  .res 1
CommitMoveWasPawn:
  .res 1
CommitMoveWasCapture:
  .res 1
.ifndef CHESS_RULES_ONLY
PonderPredictedFrom:
  .res 1
PonderPredictedTo:
  .res 1
PonderReplyFrom:
  .res 1
PonderReplyTo:
  .res 1
PonderValid:
  .res 1
PonderSavedCurrentPlayer:
  .res 1
PonderSavedBestFrom:
  .res 1
PonderSavedBestTo:
  .res 1
PonderSavedLastFrom:
  .res 1
PonderSavedLastTo:
  .res 1
PonderSavedGameState:
  .res 1
PonderUndo:
  .res 6
.endif

.segment "CODE"
