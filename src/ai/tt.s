; Generated ca65 port from Chess/ai/tt.asm.
; Keep source changes in this repository in ca65 syntax.

; import-once was handled by the ca65 include topology

; Transposition Table Module
; 2KB = 256 entries x 8 bytes each
; Runtime table base is host-configurable. Default keeps the C64-era location.

.segment "CODE"

; TT_SIZE is host-overridable (power of two, multiple of 256). Default 256 (2KB)
; fits C64-era hosts; a host with more RAM can enlarge it (reserve TT_SIZE *
; TT_ENTRY_SIZE bytes at ENGINE_TT_BASE). NOTE: with the current 16-bit Zobrist
; hash a larger table is a wash in practice (false-hit exposure grows with
; occupancy); a wider hash is the prerequisite for a big TT to pay off.
.ifndef TT_SIZE
TT_SIZE = 256; Number of entries
.endif
TT_ENTRY_SIZE = 8; Bytes per entry
.ifndef ENGINE_TT_BASE
ENGINE_TT_BASE = $C800
.endif
TT_BASE = ENGINE_TT_BASE; Base address of 2KB host-provided RAM

; Entry format (8 bytes):
; +0:   Hash verification low byte
; +1:   Hash verification high byte XOR generation
; +2:   Depth searched
; +3:   Flag (0=EXACT, 1=ALPHA, 2=BETA)
; +4-5: Score (signed 16-bit)
; +6:   Best move from square
; +7:   Best move to square

TT_FLAG_EXACT = 0
TT_FLAG_ALPHA = 1
TT_FLAG_BETA = 2

; TT probe results
.segment "BSS"

TTHit:        .res 1; $00 = miss, $01 = hit
TTMoveAvailable:
  .res 1; Hash matched; TTBestFrom/To can order moves
TTFlag:       .res 1; Flag from entry
TTDepth:      .res 1; Depth from entry
TTScoreLo:    .res 1; Score low byte
TTScoreHi:    .res 1; Score high byte
TTBestFrom:   .res 1; Best move from
TTBestTo:     .res 1; Best move to
TTStoreFrom:
  .res 1; Optional local move override for TTStore
TTStoreTo:
  .res 1
TTStoreUseMove:
  .res 1; Store TTStoreFrom/To even when from is $ff

.segment "CODE"

TTCurrentGeneration:
  .byte $01; Current valid generation tag

; Zero-page pointer for TT entry access (indirect indexed addressing)
; 6502 (addr),Y requires zero-page pointer
tt_ptr = $f0; 2 bytes: $f0-$f1

;
; TTClear
; Clear entire transposition table (2KB at ENGINE_TT_BASE)
; Uses FillMemory routine to zero the region
; Call at start of new game or when generation wraps
; Clobbers: A, X, Y, fill_to, fill_size, fill_value
;
TTClear:
  lda #$00
  sta fill_value
  lda #<TT_BASE
  sta fill_to
  lda #>TT_BASE
  sta fill_to + 1
  lda #<(TT_SIZE * TT_ENTRY_SIZE)
  sta fill_size
  lda #>(TT_SIZE * TT_ENTRY_SIZE)
  sta fill_size + 1
  jsr FillMemory
  lda #$01
  sta TTCurrentGeneration
  lda #$00
  sta TTHit
  sta TTMoveAvailable
  sta TTStoreUseMove
  lda #$ff
  sta TTStoreFrom
  sta TTStoreTo
  rts

;
; TTBeginSearch
; Cheaply invalidates old TT entries by advancing the generation tag.
; Falls back to a physical clear only on 8-bit generation wrap.
; Clobbers: A, X, Y, fill_to, fill_size, fill_value
;
TTBeginSearch:
  inc TTCurrentGeneration
  beq TTClear; Generation 0 is reserved for cleared/unused entries.

__ai_tt_generation_ok_0:
  lda #$00
  sta TTHit
  sta TTMoveAvailable
  sta TTStoreUseMove
  rts

;
; TTProbe
; Look up position in transposition table
; Input: ZobristHash contains current position hash (call ComputeZobristHash first!)
;        A = minimum depth required
; Output: TTHit = $01 if found and usable, $00 if miss
;         TTMoveAvailable = $01 on hash match even when stored depth is shallow
;         If hit: TTFlag, TTScoreLo, TTScoreHi, TTBestFrom, TTBestTo set
; Clobbers: A, X, Y, $f0-$f3
;
TTProbe:
  sta $f3; $f3 = required depth
  lda #$00
  sta TTHit
  sta TTMoveAvailable

; Calculate entry index: ZobristHash mod TT_SIZE (index splits at the hash byte
; boundary since TT_SIZE is a multiple of 256). For the 256 default this is just
; the low hash byte, byte-identical to the original.
  lda ZobristHash
  sta tt_ptr; index low 8 bits
.if TT_SIZE > 256
  lda ZobristHash + 1
  and #((TT_SIZE >> 8) - 1); index high bits
.else
  lda #$00
.endif
  sta tt_ptr + 1

; Calculate entry address: TT_BASE + (index * 8)
; index * 8 = shift left 3 times
  asl tt_ptr
  rol tt_ptr + 1
  asl tt_ptr
  rol tt_ptr + 1
  asl tt_ptr
  rol tt_ptr + 1

; Add TT_BASE - result stays in tt_ptr (zero page) for indirect access
  clc
  lda tt_ptr
  adc #<TT_BASE
  sta tt_ptr
  lda tt_ptr + 1
  adc #>TT_BASE
  sta tt_ptr + 1

; Check hash verification (first 2 bytes of entry)
  ldy #$00
  lda (tt_ptr), y
  cmp ZobristHash
  bne __ai_tt_tt_miss_0
  iny
  lda ZobristHash + 1
  eor TTCurrentGeneration
  cmp (tt_ptr), y
  bne __ai_tt_tt_miss_0

; Hash matches - extract all data. A shallow hit cannot return a score, but
; the stored move is still useful for move ordering.
  iny; Y = 2
  lda (tt_ptr), y
  sta TTDepth

  iny; Y = 3
  lda (tt_ptr), y
  sta TTFlag

  iny; Y = 4
  lda (tt_ptr), y
  sta TTScoreLo

  iny; Y = 5
  lda (tt_ptr), y
  sta TTScoreHi

  iny; Y = 6
  lda (tt_ptr), y
  sta TTBestFrom

  iny; Y = 7
  lda (tt_ptr), y
  sta TTBestTo

  lda #$01
  sta TTMoveAvailable

  lda TTDepth
  cmp $f3; Compare with required depth
  bcc __ai_tt_tt_shallow_0; Entry depth < required, score miss

  lda #$01
  sta TTHit
  rts

__ai_tt_tt_shallow_0:
  lda #$00
  sta TTHit
  rts

__ai_tt_tt_miss_0:
  lda #$00
  sta TTHit
  sta TTMoveAvailable
  rts

;
; TTStore
; Store position in transposition table
; Input: ZobristHash = position hash (already computed)
;        A = depth
;        X = flag (EXACT/ALPHA/BETA)
;        TTScoreLo/TTScoreHi = score to store
;        TTStoreUseMove = 1 stores TTStoreFrom/TTStoreTo even when no move
;        exists ($ff). Otherwise BestMoveFrom/BestMoveTo are used.
; Clobbers: A, X, Y, $f0-$f3
;
TTStore:
  sta $f2; $f2 = depth
  stx $f3; $f3 = flag

; Calculate entry address (same index as probe)
  lda ZobristHash
  sta tt_ptr
.if TT_SIZE > 256
  lda ZobristHash + 1
  and #((TT_SIZE >> 8) - 1)
.else
  lda #$00
.endif
  sta tt_ptr + 1

  asl tt_ptr
  rol tt_ptr + 1
  asl tt_ptr
  rol tt_ptr + 1
  asl tt_ptr
  rol tt_ptr + 1

  clc
  lda tt_ptr
  adc #<TT_BASE
  sta tt_ptr
  lda tt_ptr + 1
  adc #>TT_BASE
  sta tt_ptr + 1

; Depth-preferred replacement. Keep deeper current-generation entries; at the
; same depth, avoid replacing exact scores with alpha/beta bounds.
  ldy #$01
  lda ZobristHash + 1
  eor TTCurrentGeneration
  cmp (tt_ptr), y
  bne __ai_tt_store_entry_0
  iny; Y = 2, stored depth
  lda $f2
  cmp (tt_ptr), y
  beq __ai_tt_store_same_depth_0
  bcs __ai_tt_store_entry_0
  jmp __ai_tt_store_reset_0

__ai_tt_store_same_depth_0:
  iny; Y = 3, stored flag
  lda (tt_ptr), y
  cmp #TT_FLAG_EXACT
  bne __ai_tt_store_entry_0
  lda $f3
  cmp #TT_FLAG_EXACT
  bne __ai_tt_store_reset_0

__ai_tt_store_entry_0:
; Store entry
  ldy #$00
  lda ZobristHash
  sta (tt_ptr), y; +0: hash low

  iny
  lda ZobristHash + 1
  eor TTCurrentGeneration
  sta (tt_ptr), y; +1: hash high keyed by generation

  iny
  lda $f2
  sta (tt_ptr), y; +2: depth

  iny
  lda $f3
  sta (tt_ptr), y; +3: flag

  iny
  lda TTScoreLo
  sta (tt_ptr), y; +4: score low

  iny
  lda TTScoreHi
  sta (tt_ptr), y; +5: score high

  iny
  lda TTStoreUseMove
  bne __ai_tt_store_from_override_0
  lda BestMoveFrom
  jmp __ai_tt_store_from_0
__ai_tt_store_from_override_0:
  lda TTStoreFrom
__ai_tt_store_from_0:
  sta (tt_ptr), y; +6: best from

  iny
  lda TTStoreUseMove
  bne __ai_tt_store_to_override_0
  lda BestMoveTo
  jmp __ai_tt_store_to_0
__ai_tt_store_to_override_0:
  lda TTStoreTo
__ai_tt_store_to_0:
  sta (tt_ptr), y; +7: best to

__ai_tt_store_reset_0:
  lda #$00
  sta TTStoreUseMove
  lda #$ff
  sta TTStoreFrom
  sta TTStoreTo
  rts
