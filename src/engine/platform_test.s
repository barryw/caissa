; Generated ca65 port from Chess/engine/platform_test.asm.
; Keep source changes in this repository in ca65 syntax.

; import-once was handled by the ca65 include topology

.segment "CODE"

; 
; Headless platform hooks for engine-only tests. These deliberately avoid C64 UI,
; CIA timers, and opening-book data so the reusable engine can be assembled and
; tested without the full application.
; 

EngineStartSearchTimer:
  rts

EngineCheckTime:
; Headless tests do not have CIA timers. Cap iterative deepening before
; hard-mode depth 4 so ordinary positions return a measured move instead of
; running full depth with no wall-clock deadline. LEVEL_BEAST opts out of the
; cap for engine-vs-engine match play; its only bound is MaxDepthTable, so
; callers must budget multi-billion-cycle moves.
  lda difficulty
  cmp #LEVEL_BEAST
  bcs __engine_platform_test_time_ok_0
  lda IterDepth
  cmp #$04
  bcc __engine_platform_test_time_ok_0
  lda #$01
  sta TimeUp
  sec
  rts
__engine_platform_test_time_ok_0:
  clc
  rts

EngineOnSearchIteration:
  rts

EngineLookupOpeningMove:
  clc
  rts

EngineBookMoveAvoidsPawnAttack:
  sec
  rts
