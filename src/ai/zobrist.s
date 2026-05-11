; Generated ca65 port from Chess/ai/zobrist.asm.
; Keep source changes in this repository in ca65 syntax.

; import-once was handled by the ca65 include topology

; Zobrist Hashing for Position Identification
; Uses xorshift32 PRNG seeded at startup

.segment "CODE"

;
; 16-bit Galois LFSR PRNG with improved mixing
; State stored in $fb-$fc (zero page for speed)
; Returns 8-bit result in A, advances state
;
; Uses polynomial x^16 + x^14 + x^13 + x^11 + 1
; Period: 65535 (2^16 - 1)
; Taps: bits 16, 14, 13, 11 -> feedback mask $B400
;
; Runs 8 LFSR cycles per byte for better randomness
;
ZobristPRNG:
  txa
  pha; Preserve X register for callers
  ldx #$08; 8 iterations per output byte

__ai_zobrist_prng_loop_0:
; Galois LFSR step: shift right, XOR if LSB was 1
  lda $fb
  lsr; Shift LSB into carry
  ror $fc; Rotate high byte right through carry
  ror $fb; Rotate low byte right through carry

  bcc __ai_zobrist_no_xor_0; If carry clear (LSB was 0), skip XOR
; XOR with feedback polynomial $B400
  lda $fc
  eor #$B4
  sta $fc
__ai_zobrist_no_xor_0:

  dex
  bne __ai_zobrist_prng_loop_0

; Return low byte XOR high byte for better distribution
  lda $fb
  eor $fc

; Store last result for testing
  sta ZobristLastRandom

  pla
  tax; Restore X register

  lda ZobristLastRandom; Return random value in A
  rts

;
; Seed the PRNG with a fixed non-zero value
; Call once at startup
; IMPORTANT: LFSR must never be all zeros!
;
ZobristSeed:
  lda #$CE
  sta $fb
  lda #$A7
  sta $fc
  rts

; Storage for last random value (for testing)
.segment "BSS"

ZobristLastRandom:
  .res 1

.segment "CODE"

;
; Initialize all Zobrist tables with random values
; Call once at game startup
; Uses $f9/$fa as pointer (temp)
;
InitZobristTables:
; Seed PRNG
  jsr ZobristSeed

; Fill piece-square table (1536 bytes = 12 pieces x 64 squares x 2 bytes)
  lda #<ZobristPieces
  sta $f9
  lda #>ZobristPieces
  sta $fa

  ldx #$00; Page counter (6 pages = 1536 bytes)
  ldy #$00

__ai_zobrist_fillpieces_0:
  jsr ZobristPRNG
  sta ($f9), y
  iny
  bne __ai_zobrist_fillpieces_0

; Next page
  inc $fa
  inx
  cpx #$06; 6 pages for pieces (1536 bytes)
  bne __ai_zobrist_fillpieces_0

; Fill side to move (2 bytes)
  jsr ZobristPRNG
  sta ZobristSide
  jsr ZobristPRNG
  sta ZobristSide + 1

; Fill castling rights (8 bytes = 4 flags x 2 bytes)
  ldy #$00
__ai_zobrist_castloop_0:
  jsr ZobristPRNG
  sta ZobristCastling, y
  iny
  cpy #$08
  bne __ai_zobrist_castloop_0

; Fill en passant files (16 bytes = 8 files x 2 bytes)
  ldy #$00
__ai_zobrist_eploop_0:
  jsr ZobristPRNG
  sta ZobristEnPassant, y
  iny
  cpy #$10
  bne __ai_zobrist_eploop_0

  lda #$01
  sta ZobristTablesInitialized
  rts

;
; EnsureZobristTablesInitialized
; Public callers can use repetition, game-state, TT, or book hashing without
; separately remembering to seed the hash tables first.
;
EnsureZobristTablesInitialized:
  lda ZobristTablesInitialized
  bne __ai_zobrist_tables_ready_0
  jsr InitZobristTables
__ai_zobrist_tables_ready_0:
  rts

;
; Zobrist Random Number Tables (16-bit version)
; 12 piece types x 64 squares x 2 bytes = 1536 bytes
; Plus: side to move (2), castling (8), en passant (16) = 26 bytes
; Total: 1562 bytes
;
; Piece indices: 0-5 = white P,N,B,R,Q,K; 6-11 = black P,N,B,R,Q,K
;

.segment "BSS"

; Piece-square table: 12 pieces x 64 squares x 2 bytes = 1536 bytes
ZobristPieces:
  .res 1536

; Side to move (2 bytes)
ZobristSide:
  .res 2

; Castling rights: 4 flags x 2 bytes = 8 bytes
ZobristCastling:
  .res 8

; En passant file: 8 files x 2 bytes = 16 bytes
ZobristEnPassant:
  .res 16

; Current position hash (2 bytes for better collision resistance)
ZobristHash:
  .res 2
ZobristHashValid:
  .res 1

ZobristTablesInitialized:
  .res 1

.segment "CODE"

;
; Compute full Zobrist hash from current board position
; Result stored in ZobristHash (2 bytes)
; Clobbers: A, X, Y, $f7-$fb
;
ComputeZobristHash:
; Clear hash (2 bytes)
  lda #$00
  sta ZobristHash
  sta ZobristHash + 1

; Loop through the 64 valid 0x88 squares, skipping offboard gaps.
  ldx #$00; 0x88 index

__ai_zobrist_squareloop_0:
; Get piece at this square
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_zobrist_nextsquare_0

  jsr HashZobristPieceAtSquare

__ai_zobrist_nextsquare_0:
  inx
  txa
  and #$08; Past file h in 0x88 layout?
  beq __ai_zobrist_hash_check_done_0
  txa
  clc
  adc #$08; Skip offboard gap to next rank
  tax
__ai_zobrist_hash_check_done_0:
  cpx #$80; Done all board bytes?
  bne __ai_zobrist_squareloop_0

HashZobristState:
; XOR in side to move if white (2 bytes)
  lda currentplayer
  beq __ai_zobrist_skipside_0; Black to move (0), don't XOR
  cmp #WHITES_TURN
  bne __ai_zobrist_skipside_0

; White to move - XOR in ZobristSide (2 bytes)
  lda ZobristSide
  eor ZobristHash
  sta ZobristHash
  lda ZobristSide + 1
  eor ZobristHash + 1
  sta ZobristHash + 1

__ai_zobrist_skipside_0:
; XOR in castling rights (2 bytes each)
  lda castlerights
  and #CASTLE_WK
  beq __ai_zobrist_nowk_0
  lda ZobristCastling
  eor ZobristHash
  sta ZobristHash
  lda ZobristCastling + 1
  eor ZobristHash + 1
  sta ZobristHash + 1
__ai_zobrist_nowk_0:
  lda castlerights
  and #CASTLE_WQ
  beq __ai_zobrist_nowq_0
  lda ZobristCastling + 2
  eor ZobristHash
  sta ZobristHash
  lda ZobristCastling + 3
  eor ZobristHash + 1
  sta ZobristHash + 1
__ai_zobrist_nowq_0:
  lda castlerights
  and #CASTLE_BK
  beq __ai_zobrist_nobk_0
  lda ZobristCastling + 4
  eor ZobristHash
  sta ZobristHash
  lda ZobristCastling + 5
  eor ZobristHash + 1
  sta ZobristHash + 1
__ai_zobrist_nobk_0:
  lda castlerights
  and #CASTLE_BQ
  beq __ai_zobrist_nobq_0
  lda ZobristCastling + 6
  eor ZobristHash
  sta ZobristHash
  lda ZobristCastling + 7
  eor ZobristHash + 1
  sta ZobristHash + 1
__ai_zobrist_nobq_0:

; XOR in en passant file if set (2 bytes)
  lda enpassantsq
  cmp #$FF
  beq __ai_zobrist_done_0
; Extract file (0-7) from en passant square
  and #$07
  asl; * 2 for 2-byte entries
  tay
  lda ZobristEnPassant, y
  eor ZobristHash
  sta ZobristHash
  lda ZobristEnPassant + 1, y
  eor ZobristHash + 1
  sta ZobristHash + 1

__ai_zobrist_done_0:
  lda #$01
  sta ZobristHashValid
  rts

;
; ComputeZobristHashFromPieceLists
; Faster full hash for search positions where compact piece lists are already
; authoritative. Falls through to the shared side/castling/en-passant hashing.
; Result stored in ZobristHash (2 bytes)
; Clobbers: A, X, Y, $f5-$fb
;
ComputeZobristHashFromPieceLists:
  lda #$00
  sta ZobristHash
  sta ZobristHash + 1

  lda WhitePieceCount
  sta $f5; list count
  lda #$00
  sta $f6; list index

__ai_zobrist_white_list_loop_0:
  lda $f6
  cmp $f5
  bcs __ai_zobrist_black_list_start_0

__ai_zobrist_white_list_square_0:
  ldy $f6
  lda WhitePieceList, y
  cmp #$ff
  beq __ai_zobrist_white_list_next_0
  tax
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_zobrist_white_list_next_0
  jsr HashZobristPieceAtSquare

__ai_zobrist_white_list_next_0:
  inc $f6
  jmp __ai_zobrist_white_list_loop_0

__ai_zobrist_black_list_start_0:
  lda BlackPieceCount
  sta $f5
  lda #$00
  sta $f6

__ai_zobrist_black_list_loop_0:
  lda $f6
  cmp $f5
  bcc __ai_zobrist_black_list_square_0
  jmp HashZobristState

__ai_zobrist_black_list_square_0:
  ldy $f6
  lda BlackPieceList, y
  cmp #$ff
  beq __ai_zobrist_black_list_next_0
  tax
  lda Board88, x
  cmp #EMPTY_PIECE
  beq __ai_zobrist_black_list_next_0
  jsr HashZobristPieceAtSquare

__ai_zobrist_black_list_next_0:
  inc $f6
  jmp __ai_zobrist_black_list_loop_0

;
; HashZobristPieceAtSquare
; Input: A = piece value, X = 0x88 square
; XORs this piece-square key into ZobristHash.
; Clobbers: A, X, Y, $f7-$fb
;
HashZobristPieceAtSquare:
; Save square index
  stx $f7

; Convert piece to Zobrist index (0-11)
  sta $f8; Save full piece value
  and #WHITE_COLOR
  beq __ai_zobrist_black_zobrist_piece_0

  lda $f8
  and #$07
  sec
  sbc #$01; White $B1-$B6 -> 0-5
  jmp __ai_zobrist_piece_index_done_0

__ai_zobrist_black_zobrist_piece_0:
  lda $f8
  and #$07
  clc
  adc #$05; Black $31-$36 -> 6-11

__ai_zobrist_piece_index_done_0:
  sta $f8; Piece index (0-11)

; Convert 0x88 square to 0-63
; 0x88 index: row*16 + col -> row*8 + col
  lda $f7
  and #$07; Column (0-7)
  sta $f9
  lda $f7
  lsr
  lsr
  lsr
  lsr; Row (0-7)
  asl
  asl
  asl; Row * 8
  ora $f9; + column = 0-63 index
  sta $f9; Square 0-63

; Calculate table offset: piece_index * 64 * 2 + square * 2
; Each entry is now 2 bytes for 16-bit hash
  lda $f8
  lsr; piece_index >> 1 = high byte
  sta $fb
  lda #$00
  bcc __ai_zobrist_piece_offset_low_done_0
  lda #$80
__ai_zobrist_piece_offset_low_done_0:
  sta $fa; Low byte of piece_index * 128

; Add square * 2 to offset
  lda $f9
  asl; square * 2
  clc
  adc $fa
  sta $fa
  lda $fb
  adc #$00
  sta $fb

; Add ZobristPieces base address
  clc
  lda $fa
  adc #<ZobristPieces
  sta $fa
  lda $fb
  adc #>ZobristPieces
  sta $fb

; XOR 2-byte value from table into hash
  ldy #$00
  lda ($fa), y
  eor ZobristHash
  sta ZobristHash
  iny
  lda ($fa), y
  eor ZobristHash + 1
  sta ZobristHash + 1

; Restore square index
  ldx $f7
  rts
