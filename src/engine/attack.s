; Generated ca65 port from Chess/engine/attack.asm.
; Keep source changes in this repository in ca65 syntax.

; import-once was handled by the ca65 include topology

.segment "CODE"

; 
; Attack detection is engine logic, not UI logic. The application and AI both
; call these labels.
; 

CheckKingInCheck:
  lda currentplayer
  beq __engine_attack_checkblack_0
  lda whitekingsq
  jmp __engine_attack_docheck_0
__engine_attack_checkblack_0:
  lda blackkingsq
__engine_attack_docheck_0:
  sta attack_sq
  lda currentplayer
  eor #$01
  sta attack_color
  jsr IsSquareAttacked
  rts

IsSquareAttacked:

;
; 1. Check for knight attacks
;
  ldx #$00
__engine_attack_knight_loop_0:
  lda attack_sq
  clc
  adc KnightOffsets, x
  tay
  and #OFFBOARD_MASK
  bne __engine_attack_knight_next_0
  lda Board88, y
  cmp #EMPTY_SPR
  beq __engine_attack_knight_next_0
  pha
  and #LOWER7
  cmp #KNIGHT_SPR
  bne __engine_attack_knight_notmatch_0
  pla
  jsr CheckEnemyColor
  bcc __engine_attack_knight_next_0
  jmp __engine_attack_attacked_0
__engine_attack_knight_notmatch_0:
  pla
__engine_attack_knight_next_0:
  inx
  cpx #KnightOffsetsEnd - KnightOffsets
  bne __engine_attack_knight_loop_0

;
; 2. Check for king attacks
;
  ldx #$00
__engine_attack_king_loop_0:
  lda attack_sq
  clc
  adc AllDirectionOffsets, x
  tay
  and #OFFBOARD_MASK
  bne __engine_attack_king_next_0
  lda Board88, y
  cmp #EMPTY_SPR
  beq __engine_attack_king_next_0
  pha
  and #LOWER7
  cmp #KING_SPR
  bne __engine_attack_king_notmatch_0
  pla
  jsr CheckEnemyColor
  bcc __engine_attack_king_next_0
  jmp __engine_attack_attacked_0
__engine_attack_king_notmatch_0:
  pla
__engine_attack_king_next_0:
  inx
  cpx #AllDirectionOffsetsEnd - AllDirectionOffsets
  bne __engine_attack_king_loop_0

;
; 3. Check diagonal rays (bishop, queen, pawn on first step)
;
  ldx #$00
__engine_attack_diag_loop_0:
  stx ray_dir
  lda DiagonalOffsets, x
  sta move_delta
  lda attack_sq
  sta ray_sq
  ldy #$00

__engine_attack_diag_ray_0:
  lda ray_sq
  clc
  adc move_delta
  sta ray_sq
  and #OFFBOARD_MASK
  bne __engine_attack_diag_next_dir_0

  ldx ray_sq
  lda Board88, x
  cmp #EMPTY_SPR
  beq __engine_attack_diag_continue_0

  pha
  and #LOWER7
  cmp #BISHOP_SPR
  beq __engine_attack_diag_check_enemy_0
  cmp #QUEEN_SPR
  beq __engine_attack_diag_check_enemy_0

  cpy #$00
  bne __engine_attack_diag_blocked_0
  cmp #PAWN_SPR
  bne __engine_attack_diag_blocked_0

  pla
  pha
  jsr CheckEnemyColor
  bcc __engine_attack_diag_blocked_0
  lda attack_color
  beq __engine_attack_check_black_pawn_0
  lda ray_dir
  cmp #$02
  bcc __engine_attack_diag_blocked_0
  pla
  jmp __engine_attack_attacked_0
__engine_attack_check_black_pawn_0:
  lda ray_dir
  cmp #$02
  bcs __engine_attack_diag_blocked_0
  pla
  jmp __engine_attack_attacked_0

__engine_attack_diag_check_enemy_0:
  pla
  jsr CheckEnemyColor
  bcc __engine_attack_diag_next_dir_0
  jmp __engine_attack_attacked_0

__engine_attack_diag_blocked_0:
  pla
__engine_attack_diag_next_dir_0:
  ldx ray_dir
  inx
  cpx #DiagonalOffsetsEnd - DiagonalOffsets
  bne __engine_attack_diag_loop_0
  jmp __engine_attack_check_ortho_0

__engine_attack_diag_continue_0:
  iny
  jmp __engine_attack_diag_ray_0

;
; 4. Check orthogonal rays (rook, queen)
;
__engine_attack_check_ortho_0:
  ldx #$00
__engine_attack_ortho_loop_0:
  stx ray_dir
  lda OrthogonalOffsets, x
  sta move_delta
  lda attack_sq
  sta ray_sq

__engine_attack_ortho_ray_0:
  lda ray_sq
  clc
  adc move_delta
  sta ray_sq
  and #OFFBOARD_MASK
  bne __engine_attack_ortho_next_dir_0

  ldx ray_sq
  lda Board88, x
  cmp #EMPTY_SPR
  beq __engine_attack_ortho_ray_0

  pha
  and #LOWER7
  cmp #ROOK_SPR
  beq __engine_attack_ortho_check_enemy_0
  cmp #QUEEN_SPR
  beq __engine_attack_ortho_check_enemy_0
  pla
  jmp __engine_attack_ortho_next_dir_0

__engine_attack_ortho_check_enemy_0:
  pla
  jsr CheckEnemyColor
  bcc __engine_attack_ortho_next_dir_0
  jmp __engine_attack_attacked_0

__engine_attack_ortho_next_dir_0:
  ldx ray_dir
  inx
  cpx #OrthogonalOffsetsEnd - OrthogonalOffsets
  bne __engine_attack_ortho_loop_0

  clc
  rts

__engine_attack_attacked_0:
  sec
  rts

CheckEnemyColor:
  and #BIT8
  beq __engine_attack_piece_is_black_0
  lda attack_color
  cmp #WHITES_TURN
  beq __engine_attack_is_enemy_0
  clc
  rts
__engine_attack_piece_is_black_0:
  lda attack_color
  cmp #BLACKS_TURN
  beq __engine_attack_is_enemy_0
  clc
  rts
__engine_attack_is_enemy_0:
  sec
  rts
