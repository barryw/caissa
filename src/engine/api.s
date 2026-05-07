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

ChessUnmakeMove:
  jmp UnmakeMove

ChessIsSquareAttacked:
  jmp IsSquareAttacked

ChessCheckKingInCheck:
  jmp CheckKingInCheck
