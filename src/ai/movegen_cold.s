; Generated ca65 port from Chess/ai/movegen_cold.asm.
; Keep source changes in this repository in ca65 syntax.

; import-once was handled by the ca65 include topology

; Cold move-generation helpers. Keep rare promotion handling after the hot
; search modules so ordinary move ordering/search layout stays stable.

.segment "CODE"

;
; AddPawnPromotionMoves - Add queen and knight promotion moves
; Uses $f7 = from square, $fa = to square
; Quiet promotions are inserted before already-generated quiet moves so search
; considers the queening move early. Promotion captures keep generator order;
; MVV-LVA already treats them as tactical captures.
; Clobbers: A, X
;
AddPawnPromotionMoves:
  ldx $fa
  lda Board88, x
  cmp #EMPTY_PIECE
  beq AddQuietPromotionMovesFront

  lda $f7
  ldx $fa
  jsr AddMove
  lda $fa
  ora #PROMO_FLAG_KNIGHT
  tax
  lda $f7
  jsr AddMove
  rts

AddQuietPromotionMovesFront:
  lda MoveCount
  beq __ai_movegen_cold_promotion_front_done_0
  tax

__ai_movegen_cold_promotion_front_shift_0:
  dex
  lda MoveListFrom, x
  sta MoveListFrom + 2, x
  lda MoveListTo, x
  sta MoveListTo + 2, x
  cpx #$00
  bne __ai_movegen_cold_promotion_front_shift_0

__ai_movegen_cold_promotion_front_done_0:
  lda $f7
  sta MoveListFrom
  sta MoveListFrom + 1
  lda $fa
  sta MoveListTo
  ora #PROMO_FLAG_KNIGHT
  sta MoveListTo + 1
  lda MoveCount
  clc
  adc #$02
  sta MoveCount
  rts
