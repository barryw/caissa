; Generated ca65 port from Chess/ai/ai.asm.
; Keep source changes in this repository in ca65 syntax.

; import-once was handled by the ca65 include topology

; Chess AI Module
; Includes all AI-related code

.include "zobrist.s"
.include "pst.s"
.include "movegen.s"
.include "eval.s"
.include "tt.s"
.include "search.s"
.include "rules.s"
.include "movegen_cold.s"
