; Reusable chess rules component.
;
; This build exposes board/rules APIs without local AI search, evaluation,
; transposition tables, or ponder support.

CHESS_RULES_ONLY = 1

.include "state.s"
.include "pieces.s"
.include "attack.s"
.include "../ai/zobrist.s"
.include "../ai/movegen.s"
.include "../ai/movegen_cold.s"
.include "../ai/search.s"
.include "../ai/rules.s"
.include "api.s"
