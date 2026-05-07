; Generated ca65 port from Chess/engine/engine.asm.
; Keep source changes in this repository in ca65 syntax.

; import-once was handled by the ca65 include topology

; 
; Reusable chess engine component.
; 
; Host applications should import the shared constants/macros first, then this
; file, and provide platform hooks equivalent to engine/platform_c64.asm when
; they are not targeting the C64 app.
; 
; See engine/README.md for the full hook contract.
; 
; Required platform hook labels:
; EngineStartSearchTimer
; EngineCheckTime
; EngineOnSearchIteration
; EngineLookupOpeningMove
; EngineBookMoveAvoidsPawnAttack
; 

.include "state.s"
.include "pieces.s"
.include "attack.s"
.include "../ai/ai.s"
.include "api.s"
