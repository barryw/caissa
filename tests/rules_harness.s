; Headless ca65 harness for the reusable chess rules engine.

.segment "LOADADDR"
  .word $0801

.segment "CODE"
rules_test_start:
  rts

.include "../src/constants.s"
.include "../src/engine/rules_engine.s"
