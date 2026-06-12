; Generated ca65 port from Chess/engine/attack.asm.
; Keep source changes in this repository in ca65 syntax.

; import-once was handled by the ca65 include topology

.segment "CODE"

;
; Attack detection is engine logic, not UI logic. The application and AI both
; call these labels.
;
; Contract: inputs attack_sq / attack_color; output carry set if attacked.
; A/X/Y and the scratch zp (move_delta/ray_dir/ray_sq) are clobbered.
;
; Optimization note (cycles-only, behavior identical):
; White pieces carry BIT8 ($80); attack_color is 1=white, 0=black. A piece is
; an enemy attacker of type T exactly when piece == T | (attack_color<<7).
; At entry we compute that color bit once and patch it into the immediate
; operands below (self-modifying code, lives in the CODE segment in RAM).
; This removes the per-probe pha/jsr CheckEnemyColor/pla sequences entirely.
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

IsSquareAttacked:

;
; 0. Patch the attacker color bit into the compare/eor immediates (SMC).
;
  lda attack_color
  lsr a
  ror a; A = $80 if white attacking, $00 if black
  sta __engine_attack_diag_eor_0+1
  sta __engine_attack_ortho_eor_0+1
  ora #KNIGHT_SPR
  sta __engine_attack_knight_cmp_0+1
  eor #(KNIGHT_SPR ^ KING_SPR)
  sta __engine_attack_king_cmp_0+1

;
; 1. Check for knight attacks
;
; Empty squares ($30) can never equal the patched target ($32/$B2), so no
; separate EMPTY_SPR test is needed.
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
__engine_attack_knight_cmp_0:
  cmp #$00; patched: KNIGHT_SPR | colorbit
  beq __engine_attack_attacked_0
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
__engine_attack_king_cmp_0:
  cmp #$00; patched: KING_SPR | colorbit
  beq __engine_attack_attacked_0
__engine_attack_king_next_0:
  inx
  cpx #AllDirectionOffsetsEnd - AllDirectionOffsets
  bne __engine_attack_king_loop_0
  jmp __engine_attack_check_diag_0

__engine_attack_attacked_0:
  sec
  rts

;
; 3. Check diagonal rays (bishop, queen, pawn on first step)
;
; After eor with the patched color bit an enemy attacker reads as its bare
; type constant; friendly pieces keep BIT8 set and fail every compare, which
; blocks the ray exactly as before.
;
__engine_attack_check_diag_0:
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
  bne __engine_attack_diag_hit_0
  iny
  bne __engine_attack_diag_ray_0; Y <= 7, always taken

__engine_attack_diag_hit_0:
__engine_attack_diag_eor_0:
  eor #$00; patched: attacker color bit
  cmp #BISHOP_SPR
  beq __engine_attack_attacked_0
  cmp #QUEEN_SPR
  beq __engine_attack_attacked_0

  cpy #$00
  bne __engine_attack_diag_next_dir_0
  cmp #PAWN_SPR
  bne __engine_attack_diag_next_dir_0

  lda attack_color
  beq __engine_attack_check_black_pawn_0
  lda ray_dir
  cmp #$02
  bcc __engine_attack_diag_next_dir_0
  bcs __engine_attack_attacked_0; always taken
__engine_attack_check_black_pawn_0:
  lda ray_dir
  cmp #$02
  bcc __engine_attack_attacked_0

__engine_attack_diag_next_dir_0:
  ldx ray_dir
  inx
  cpx #DiagonalOffsetsEnd - DiagonalOffsets
  bne __engine_attack_diag_loop_0

;
; 4. Check orthogonal rays (rook, queen)
;
; Direction index lives in Y here (no step counter needed), saving the
; ray_dir spill/reload of the diagonal pass.
;
  ldy #$00
__engine_attack_ortho_loop_0:
  lda OrthogonalOffsets, y
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

__engine_attack_ortho_eor_0:
  eor #$00; patched: attacker color bit
  cmp #ROOK_SPR
  beq __engine_attack_attacked_1
  cmp #QUEEN_SPR
  beq __engine_attack_attacked_1

__engine_attack_ortho_next_dir_0:
  iny
  cpy #OrthogonalOffsetsEnd - OrthogonalOffsets
  bne __engine_attack_ortho_loop_0

  clc
  rts

__engine_attack_attacked_1:
  sec
  rts

; Retained for any external users; the hot paths above no longer call it.
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
