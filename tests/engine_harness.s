; Headless ca65 harness for the reusable chess engine.

ENGINE_FIXED_PST = 0

.segment "LOADADDR"
  .word $0801

.segment "CODE"
engine_test_start:
  rts

.include "../src/constants.s"

.segment "CODE"

; Minimal memory-fill service required by the transposition table clear path.
FillMemory:
  ldy #$00
  ldx fill_size + $01
  beq FillMemoryFragFill
FillMemoryPageFill:
  lda fill_value
  sta (fill_to), y
  iny
  bne FillMemoryPageFill
  inc fill_to + $01
  dex
  bne FillMemoryPageFill
FillMemoryFragFill:
  cpy fill_size
  beq FillMemoryDoneFill
  lda fill_value
  sta (fill_to), y
  iny
  bne FillMemoryFragFill
FillMemoryDoneFill:
  rts

.include "../src/engine/platform_test.s"
.include "../src/engine/engine.s"
