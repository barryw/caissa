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

ChessFindBestMove:
  jmp FindBestMove

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

CommitMoveFrom:
  .byte $ff
CommitMoveTo:
  .byte $ff
CommitMoveCleanTo:
  .byte $ff
CommitMoveWasPawn:
  .byte $00
CommitMoveWasCapture:
  .byte $00
