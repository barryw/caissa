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

UpdatePieceListForMove:
  ldx movetoindex
  lda Board88, x
  cmp #EMPTY_SPR
  beq __engine_pieces_no_capture_0

  lda currentplayer
  beq __engine_pieces_capture_white_0

  jsr RemoveFromBlackPieceList
  jmp __engine_pieces_no_capture_0

__engine_pieces_capture_white_0:
  jsr RemoveFromWhitePieceList

__engine_pieces_no_capture_0:
  lda currentplayer
  beq __engine_pieces_update_black_0

  jsr UpdateWhitePiecePosition
  rts

__engine_pieces_update_black_0:
  jsr UpdateBlackPiecePosition
  rts

RemoveFromWhitePieceList:
  lda movetoindex
  ldx #$00
__engine_pieces_find_loop_0:
  cpx WhitePieceCount
  beq __engine_pieces_not_found_0
  cmp WhitePieceList, x
  beq __engine_pieces_found_0
  inx
  bne __engine_pieces_find_loop_0

__engine_pieces_found_0:
  dec WhitePieceCount
  ldy WhitePieceCount
  lda WhitePieceList, y
  sta WhitePieceList, x
  lda #$ff
  sta WhitePieceList, y
__engine_pieces_not_found_0:
  rts

RemoveFromBlackPieceList:
  lda movetoindex
  ldx #$00
__engine_pieces_find_loop_1:
  cpx BlackPieceCount
  beq __engine_pieces_not_found_1
  cmp BlackPieceList, x
  beq __engine_pieces_found_1
  inx
  bne __engine_pieces_find_loop_1

__engine_pieces_found_1:
  dec BlackPieceCount
  ldy BlackPieceCount
  lda BlackPieceList, y
  sta BlackPieceList, x
  lda #$ff
  sta BlackPieceList, y
__engine_pieces_not_found_1:
  rts

UpdateWhitePiecePosition:
  lda movefromindex
  ldx #$00
__engine_pieces_find_loop_2:
  cpx WhitePieceCount
  beq __engine_pieces_not_found_2
  cmp WhitePieceList, x
  beq __engine_pieces_found_2
  inx
  bne __engine_pieces_find_loop_2

__engine_pieces_found_2:
  lda movetoindex
  sta WhitePieceList, x
__engine_pieces_not_found_2:
  rts

UpdateBlackPiecePosition:
  lda movefromindex
  ldx #$00
__engine_pieces_find_loop_3:
  cpx BlackPieceCount
  beq __engine_pieces_not_found_3
  cmp BlackPieceList, x
  beq __engine_pieces_found_3
  inx
  bne __engine_pieces_find_loop_3

__engine_pieces_found_3:
  lda movetoindex
  sta BlackPieceList, x
__engine_pieces_not_found_3:
  rts

RemovePawnEnPassant:
  sta piecelist_idx
  lda currentplayer
  beq __engine_pieces_remove_white_pawn_0

  lda piecelist_idx
  ldx #$00
__engine_pieces_find_black_0:
  cpx BlackPieceCount
  beq __engine_pieces_done_0
  cmp BlackPieceList, x
  beq __engine_pieces_found_black_0
  inx
  bne __engine_pieces_find_black_0
__engine_pieces_found_black_0:
  dec BlackPieceCount
  ldy BlackPieceCount
  lda BlackPieceList, y
  sta BlackPieceList, x
  lda #$ff
  sta BlackPieceList, y
  rts

__engine_pieces_remove_white_pawn_0:
  lda piecelist_idx
  ldx #$00
__engine_pieces_find_white_0:
  cpx WhitePieceCount
  beq __engine_pieces_done_0
  cmp WhitePieceList, x
  beq __engine_pieces_found_white_0
  inx
  bne __engine_pieces_find_white_0
__engine_pieces_found_white_0:
  dec WhitePieceCount
  ldy WhitePieceCount
  lda WhitePieceList, y
  sta WhitePieceList, x
  lda #$ff
  sta WhitePieceList, y
__engine_pieces_done_0:
  rts

UpdateCastlingRook:
  sta piecelist_idx
  stx temp1

  lda currentplayer
  beq __engine_pieces_update_black_rook_0

  lda piecelist_idx
  ldx #$00
__engine_pieces_find_white_rook_0:
  cpx WhitePieceCount
  beq __engine_pieces_castling_done_0
  cmp WhitePieceList, x
  beq __engine_pieces_found_white_rook_0
  inx
  bne __engine_pieces_find_white_rook_0
__engine_pieces_found_white_rook_0:
  lda temp1
  sta WhitePieceList, x
  rts

__engine_pieces_update_black_rook_0:
  lda piecelist_idx
  ldx #$00
__engine_pieces_find_black_rook_0:
  cpx BlackPieceCount
  beq __engine_pieces_castling_done_0
  cmp BlackPieceList, x
  beq __engine_pieces_found_black_rook_0
  inx
  bne __engine_pieces_find_black_rook_0
__engine_pieces_found_black_rook_0:
  lda temp1
  sta BlackPieceList, x
__engine_pieces_castling_done_0:
  rts
