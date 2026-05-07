; Generated ca65 port from Chess/engine/state.asm.
; Keep source changes in this repository in ca65 syntax.

; import-once was handled by the ca65 include topology

.segment "CODE"

; 
; Reusable chess-engine state.
; 
; Board88 is the engine's single source of truth. Platform renderers should
; translate these piece IDs into their own graphics instead of writing display
; state back into the engine.
; 

;
; Public engine configuration/state
;

; The difficulty level for the current search.
difficulty:
  .byte $00

; Keep track of the current player. 0 = black, 1 = white
currentplayer:
  .byte WHITES_TURN

; Last reported game state. See GAME_* constants in constants.s.
EngineGameState:
  .byte GAME_NORMAL

; Store the 0x88 offset in Board88 for the piece to move here.
movefromindex:
  .byte BIT8

; Store the 0x88 offset in Board88 for the location to move to here.
movetoindex:
  .byte BIT8

;
; 0x88 Board Representation
;
; Index = row * 16 + col, where:
; - Valid squares: (index & $88) == 0
; - Invalid/off-board: (index & $88) != 0
;
Board88:
; Row 0 ($00-$0F): Black back rank + invalid padding
  .byte BLACK_ROOK, BLACK_KNIGHT, BLACK_BISHOP, BLACK_QUEEN, BLACK_KING, BLACK_BISHOP, BLACK_KNIGHT, BLACK_ROOK
  .res 8, EMPTY_PIECE

; Row 1 ($10-$1F): Black pawns + invalid padding
  .byte BLACK_PAWN, BLACK_PAWN, BLACK_PAWN, BLACK_PAWN, BLACK_PAWN, BLACK_PAWN, BLACK_PAWN, BLACK_PAWN
  .res 8, EMPTY_PIECE

; Rows 2-5: Empty board + invalid padding
  .res 16, EMPTY_PIECE
  .res 16, EMPTY_PIECE
  .res 16, EMPTY_PIECE
  .res 16, EMPTY_PIECE

; Row 6 ($60-$6F): White pawns + invalid padding
  .byte WHITE_PAWN, WHITE_PAWN, WHITE_PAWN, WHITE_PAWN, WHITE_PAWN, WHITE_PAWN, WHITE_PAWN, WHITE_PAWN
  .res 8, EMPTY_PIECE

; Row 7 ($70-$7F): White back rank + invalid padding
  .byte WHITE_ROOK, WHITE_KNIGHT, WHITE_BISHOP, WHITE_QUEEN, WHITE_KING, WHITE_BISHOP, WHITE_KNIGHT, WHITE_ROOK
  .res 8, EMPTY_PIECE

;
; Auxiliary Game State for Move Validation
;

; 0x88 index of white king (starts at e1)
whitekingsq:
  .byte $74

; 0x88 index of black king (starts at e8)
blackkingsq:
  .byte $04

; Castling rights bitmap: bit 0=WK, 1=WQ, 2=BK, 3=BQ
castlerights:
  .byte $0f

; 0x88 index of en passant target square, $ff = none available
enpassantsq:
  .byte $ff

;
; Draw Detection State
;

; Halfmove clock for 50-move rule
HalfmoveClock:
  .byte $00

; Full move number (increments after Black's move)
FullmoveNumber:
  .word $0001

; Position history for threefold repetition detection
MAX_HISTORY = 200
PositionHistoryLo:
  .res MAX_HISTORY, $00
PositionHistoryHi:
  .res MAX_HISTORY, $00
HistoryCount:
  .byte $00

;
; Direction Offset Tables
;

; Orthogonal directions (rook, queen)
OrthogonalOffsets:
  .byte $f0, $10, $ff, $01; N(-16), S(+16), W(-1), E(+1)
OrthogonalOffsetsEnd:

; Diagonal directions (bishop, queen)
DiagonalOffsets:
  .byte $ef, $f1, $0f, $11; NW(-17), NE(-15), SW(+15), SE(+17)
DiagonalOffsetsEnd:

; All 8 directions (queen, king)
AllDirectionOffsets:
  .byte $ef, $f0, $f1, $ff, $01, $0f, $10, $11
AllDirectionOffsetsEnd:

; Knight move offsets
KnightOffsets:
  .byte $df, $e1, $ee, $f2, $0e, $12, $1f, $21
; -33, -31, -18, -14, +14, +18, +31, +33
KnightOffsetsEnd:

; Pawn capture offsets (indexed by color: 0=black, 1=white)
PawnCaptureOffsets:
  .byte $0f, $11; Black: SW(+15), SE(+17)
  .byte $ef, $f1; White: NW(-17), NE(-15)

;
; Promotion State
;

; Square where pawn is promoting ($ff = not promoting)
promotionsq:
  .byte $ff

; Selected promotion piece type
promotionpiece:
  .byte $00

;
; Piece Lists for Optimized Move Generation
;

WhitePieceList:
  .byte $70, $71, $72, $73, $74, $75, $76, $77
  .byte $60, $61, $62, $63, $64, $65, $66, $67

BlackPieceList:
  .byte $00, $01, $02, $03, $04, $05, $06, $07
  .byte $10, $11, $12, $13, $14, $15, $16, $17

WhitePieceCount:
  .byte 16
BlackPieceCount:
  .byte 16

; Temp storage for piece list operations
piecelist_idx:
  .byte $00
