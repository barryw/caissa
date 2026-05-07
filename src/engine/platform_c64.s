; Generated ca65 port from Chess/engine/platform_c64.asm.
; Keep source changes in this repository in ca65 syntax.

; import-once was handled by the ca65 include topology

.segment "CODE"

; 
; C64-specific hooks used by the reusable search core.
; Nova can provide replacements with the same labels.
; 

EngineStartSearchTimer:
; Configure CIA Timer B to count Timer A underflows.
  lda $DC0F
  and #%11000000
  ora #%01000000
  sta $DC0F

  lda #$FF
  sta $DC06
  sta $DC07

  lda $DC0F
  and #%11000000
  ora #%01000001
  sta $DC0F
  rts

CheckTime:
EngineCheckTime:
  sec
  lda #$FF
  sbc $DC06
  sta $f0
  lda #$FF
  sbc $DC07
  sta $f1

  lda $f1
  cmp TimeBudgetHi
  bcc __engine_platform_c64_time_ok_0
  bne __engine_platform_c64_time_up_0

  lda $f0
  cmp TimeBudgetLo
  bcc __engine_platform_c64_time_ok_0

__engine_platform_c64_time_up_0:
  lda #$01
  sta TimeUp
  sec
  rts

__engine_platform_c64_time_ok_0:
  clc
  rts

EngineOnSearchIteration:
  jmp UpdateThinkingDisplay

EngineLookupOpeningMove:
  jmp LookupOpeningMove

EngineBookMoveAvoidsPawnAttack:
  jmp BookMoveAvoidsPawnAttack
