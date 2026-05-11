; Generated ca65 port from Chess/engine/pieces.asm.
; Keep source changes in this repository in ca65 syntax.

; import-once was handled by the ca65 include topology

.segment "CODE"

; 
; Piece-list maintenance for the reusable engine.
; 
; The lists keep active pieces contiguous so move generation can scan actual
; pieces instead of the whole 0x88 board.
; 

InitPieceLists:
; Clear both lists
  ldx #15
  lda #$ff
__engine_pieces_clear_loop_0:
  sta WhitePieceList, x
  sta BlackPieceList, x
  dex
  bpl __engine_pieces_clear_loop_0

; Reset counts
  lda #$00
  sta WhitePieceCount
  sta BlackPieceCount

; Scan Board88 for pieces
  ldx #$00
__engine_pieces_scan_loop_0:
  txa
  and #OFFBOARD_MASK
  bne __engine_pieces_next_square_0

  lda Board88, x
  cmp #EMPTY_SPR
  beq __engine_pieces_next_square_0

  and #BIT8
  bne __engine_pieces_white_piece_0

  ldy BlackPieceCount
  txa
  sta BlackPieceList, y
  inc BlackPieceCount
  jmp __engine_pieces_next_square_0

__engine_pieces_white_piece_0:
  ldy WhitePieceCount
  txa
  sta WhitePieceList, y
  inc WhitePieceCount

__engine_pieces_next_square_0:
  inx
  cpx #BOARD_SIZE
  bne __engine_pieces_scan_loop_0

  rts

;
; Generic piece-list helpers used by search MakeMove/UnmakeMove.
; These take explicit squares instead of relying on currentplayer or the UI
; move globals, so recursive search can keep the lists authoritative.
;

MoveWhitePieceListSquare:
  sta piecelist_idx
  stx temp1
  ldx #$00
__engine_pieces_move_white_loop_0:
  cpx WhitePieceCount
  beq __engine_pieces_move_white_done_0
  lda WhitePieceList, x
  cmp piecelist_idx
  beq __engine_pieces_move_white_found_0
  inx
  bne __engine_pieces_move_white_loop_0
__engine_pieces_move_white_found_0:
  lda temp1
  sta WhitePieceList, x
__engine_pieces_move_white_done_0:
  rts

MoveBlackPieceListSquare:
  sta piecelist_idx
  stx temp1
  ldx #$00
__engine_pieces_move_black_loop_0:
  cpx BlackPieceCount
  beq __engine_pieces_move_black_done_0
  lda BlackPieceList, x
  cmp piecelist_idx
  beq __engine_pieces_move_black_found_0
  inx
  bne __engine_pieces_move_black_loop_0
__engine_pieces_move_black_found_0:
  lda temp1
  sta BlackPieceList, x
__engine_pieces_move_black_done_0:
  rts

RemoveWhitePieceListSquare:
  sta piecelist_idx
  ldx #$00
__engine_pieces_remove_white_loop_0:
  cpx WhitePieceCount
  beq __engine_pieces_remove_white_done_0
  lda WhitePieceList, x
  cmp piecelist_idx
  beq __engine_pieces_remove_white_found_0
  inx
  bne __engine_pieces_remove_white_loop_0
__engine_pieces_remove_white_found_0:
  dec WhitePieceCount
  ldy WhitePieceCount
  lda WhitePieceList, y
  sta WhitePieceList, x
  lda #$ff
  sta WhitePieceList, y
__engine_pieces_remove_white_done_0:
  rts

RemoveBlackPieceListSquare:
  sta piecelist_idx
  ldx #$00
__engine_pieces_remove_black_loop_0:
  cpx BlackPieceCount
  beq __engine_pieces_remove_black_done_0
  lda BlackPieceList, x
  cmp piecelist_idx
  beq __engine_pieces_remove_black_found_0
  inx
  bne __engine_pieces_remove_black_loop_0
__engine_pieces_remove_black_found_0:
  dec BlackPieceCount
  ldy BlackPieceCount
  lda BlackPieceList, y
  sta BlackPieceList, x
  lda #$ff
  sta BlackPieceList, y
__engine_pieces_remove_black_done_0:
  rts

AddWhitePieceListSquare:
  ldy WhitePieceCount
  cpy #$10
  bcs __engine_pieces_add_white_done_0
  sta WhitePieceList, y
  inc WhitePieceCount
__engine_pieces_add_white_done_0:
  rts

AddBlackPieceListSquare:
  ldy BlackPieceCount
  cpy #$10
  bcs __engine_pieces_add_black_done_0
  sta BlackPieceList, y
  inc BlackPieceCount
__engine_pieces_add_black_done_0:
  rts
