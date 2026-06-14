; Generated ca65 port from Chess/ai/pst.asm.
; Keep source changes in this repository in ca65 syntax.

; ai/pst.asm
; import-once was handled by the ca65 include topology

; Piece-Square Tables for Position Evaluation
; Part B centipawn rescale: values scaled to pawn = 100 (literal centipawns).
; Each PST is a 16-bit SIGNED table split into a _Lo (low byte) and _Hi
; (high byte / sign-extension) pair of 64 entries. PstLoop fetches the 16-bit
; signed value and adds/subtracts it from EvalScore.
; Tables are from White's perspective; Black mirrors by XOR $38
; Full C64 builds place these after the opening book. Headless engine builds
; keep them relocatable so the test PRG does not inherit the app memory map.

.if ENGINE_FIXED_PST
  .segment "PST"
.else
  .segment "CODE"
.endif

; --- Pawn PST (x10) ---
; Rewards center control and advancement
PST_Pawn_Lo:
  .byte <0,   <0,   <0,   <0,   <0,   <0,   <0,   <0
  .byte <200, <200, <200, <200, <200, <200, <200, <200
  .byte <100, <100, <200, <300, <300, <200, <100, <100
  .byte <50,  <50,  <100, <250, <250, <100, <50,  <50
  .byte <0,   <0,   <0,   <200, <200, <0,   <0,   <0
  .byte <50,  <(-50),<(-100),<0,  <0,   <(-100),<(-50),<50
  .byte <50,  <100, <100, <(-200),<(-200),<100,<100, <50
  .byte <0,   <0,   <0,   <0,   <0,   <0,   <0,   <0
PST_Pawn_Hi:
  .byte >0,   >0,   >0,   >0,   >0,   >0,   >0,   >0
  .byte >200, >200, >200, >200, >200, >200, >200, >200
  .byte >100, >100, >200, >300, >300, >200, >100, >100
  .byte >50,  >50,  >100, >250, >250, >100, >50,  >50
  .byte >0,   >0,   >0,   >200, >200, >0,   >0,   >0
  .byte >50,  >(-50),>(-100),>0,  >0,   >(-100),>(-50),>50
  .byte >50,  >100, >100, >(-200),>(-200),>100,>100, >50
  .byte >0,   >0,   >0,   >0,   >0,   >0,   >0,   >0

; --- Knight PST (x10) ---
; Knights love center, hate rim
PST_Knight_Lo:
  .byte <(-500),<(-400),<(-300),<(-300),<(-300),<(-300),<(-400),<(-500)
  .byte <(-400),<(-200),<0,   <50,  <50,  <0,   <(-200),<(-400)
  .byte <(-300),<50,  <100, <150, <150, <100, <50,  <(-300)
  .byte <(-300),<0,   <150, <200, <200, <150, <0,   <(-300)
  .byte <(-300),<50,  <150, <200, <200, <150, <50,  <(-300)
  .byte <(-300),<0,   <100, <150, <150, <100, <0,   <(-300)
  .byte <(-400),<(-200),<0,   <0,   <(-30),<0,  <(-200),<(-400)
  .byte <(-500),<(-400),<(-300),<(-300),<(-300),<(-300),<(-400),<(-500)
PST_Knight_Hi:
  .byte >(-500),>(-400),>(-300),>(-300),>(-300),>(-300),>(-400),>(-500)
  .byte >(-400),>(-200),>0,   >50,  >50,  >0,   >(-200),>(-400)
  .byte >(-300),>50,  >100, >150, >150, >100, >50,  >(-300)
  .byte >(-300),>0,   >150, >200, >200, >150, >0,   >(-300)
  .byte >(-300),>50,  >150, >200, >200, >150, >50,  >(-300)
  .byte >(-300),>0,   >100, >150, >150, >100, >0,   >(-300)
  .byte >(-400),>(-200),>0,   >0,   >(-30),>0,  >(-200),>(-400)
  .byte >(-500),>(-400),>(-300),>(-300),>(-300),>(-300),>(-400),>(-500)

; --- Bishop PST (x10) ---
; Long diagonals good, avoid corners
PST_Bishop_Lo:
  .byte <(-200),<(-100),<(-100),<(-100),<(-100),<(-100),<(-100),<(-200)
  .byte <(-100),<50,  <0,   <0,   <0,   <0,   <50,  <(-100)
  .byte <(-100),<100, <100, <100, <100, <100, <100, <(-100)
  .byte <(-100),<0,   <100, <100, <100, <100, <0,   <(-100)
  .byte <(-100),<50,  <50,  <100, <100, <50,  <50,  <(-100)
  .byte <(-100),<0,   <50,  <100, <100, <50,  <0,   <(-100)
  .byte <(-100),<0,   <0,   <0,   <0,   <0,   <0,   <(-100)
  .byte <(-200),<(-100),<(-100),<(-100),<(-100),<(-100),<(-100),<(-200)
PST_Bishop_Hi:
  .byte >(-200),>(-100),>(-100),>(-100),>(-100),>(-100),>(-100),>(-200)
  .byte >(-100),>50,  >0,   >0,   >0,   >0,   >50,  >(-100)
  .byte >(-100),>100, >100, >100, >100, >100, >100, >(-100)
  .byte >(-100),>0,   >100, >100, >100, >100, >0,   >(-100)
  .byte >(-100),>50,  >50,  >100, >100, >50,  >50,  >(-100)
  .byte >(-100),>0,   >50,  >100, >100, >50,  >0,   >(-100)
  .byte >(-100),>0,   >0,   >0,   >0,   >0,   >0,   >(-100)
  .byte >(-200),>(-100),>(-100),>(-100),>(-100),>(-100),>(-100),>(-200)

; --- Rook PST (x10) ---
; 7th rank bonus, central files
PST_Rook_Lo:
  .byte <0,   <0,   <0,   <50,  <50,  <0,   <0,   <0
  .byte <50,  <100, <100, <100, <100, <100, <100, <50
  .byte <(-50),<0,   <0,   <0,   <0,   <0,   <0,   <(-50)
  .byte <(-50),<0,   <0,   <0,   <0,   <0,   <0,   <(-50)
  .byte <(-50),<0,   <0,   <0,   <0,   <0,   <0,   <(-50)
  .byte <(-50),<0,   <0,   <0,   <0,   <0,   <0,   <(-50)
  .byte <(-50),<0,   <0,   <0,   <0,   <0,   <0,   <(-50)
  .byte <0,   <0,   <0,   <50,  <50,  <0,   <0,   <0
PST_Rook_Hi:
  .byte >0,   >0,   >0,   >50,  >50,  >0,   >0,   >0
  .byte >50,  >100, >100, >100, >100, >100, >100, >50
  .byte >(-50),>0,   >0,   >0,   >0,   >0,   >0,   >(-50)
  .byte >(-50),>0,   >0,   >0,   >0,   >0,   >0,   >(-50)
  .byte >(-50),>0,   >0,   >0,   >0,   >0,   >0,   >(-50)
  .byte >(-50),>0,   >0,   >0,   >0,   >0,   >0,   >(-50)
  .byte >(-50),>0,   >0,   >0,   >0,   >0,   >0,   >(-50)
  .byte >0,   >0,   >0,   >50,  >50,  >0,   >0,   >0

; --- Queen PST (x10) ---
; Slight center preference, mobility
PST_Queen_Lo:
  .byte <(-200),<(-100),<(-100),<(-50),<(-50),<(-100),<(-100),<(-200)
  .byte <(-100),<0,   <50,  <0,   <0,   <0,   <0,   <(-100)
  .byte <(-100),<50,  <50,  <50,  <50,  <50,  <0,   <(-100)
  .byte <0,   <0,   <50,  <50,  <50,  <50,  <0,   <(-50)
  .byte <(-50),<0,   <50,  <50,  <50,  <50,  <0,   <(-50)
  .byte <(-100),<0,   <50,  <50,  <50,  <50,  <0,   <(-100)
  .byte <(-100),<0,   <0,   <0,   <0,   <0,   <0,   <(-100)
  .byte <(-200),<(-100),<(-100),<(-50),<(-50),<(-100),<(-100),<(-200)
PST_Queen_Hi:
  .byte >(-200),>(-100),>(-100),>(-50),>(-50),>(-100),>(-100),>(-200)
  .byte >(-100),>0,   >50,  >0,   >0,   >0,   >0,   >(-100)
  .byte >(-100),>50,  >50,  >50,  >50,  >50,  >0,   >(-100)
  .byte >0,   >0,   >50,  >50,  >50,  >50,  >0,   >(-50)
  .byte >(-50),>0,   >50,  >50,  >50,  >50,  >0,   >(-50)
  .byte >(-100),>0,   >50,  >50,  >50,  >50,  >0,   >(-100)
  .byte >(-100),>0,   >0,   >0,   >0,   >0,   >0,   >(-100)
  .byte >(-200),>(-100),>(-100),>(-50),>(-50),>(-100),>(-100),>(-200)

; --- King PST - Middlegame (x10) ---
; Castled corners good, center bad
PST_KingMid_Lo:
  .byte <200, <300, <100, <0,   <0,   <100, <300, <200
  .byte <200, <200, <0,   <0,   <0,   <0,   <200, <200
  .byte <(-100),<(-200),<(-200),<(-200),<(-200),<(-200),<(-200),<(-100)
  .byte <(-200),<(-300),<(-300),<(-400),<(-400),<(-300),<(-300),<(-200)
  .byte <(-300),<(-400),<(-400),<(-500),<(-500),<(-400),<(-400),<(-300)
  .byte <(-300),<(-400),<(-400),<(-500),<(-500),<(-400),<(-400),<(-300)
  .byte <(-300),<(-400),<(-400),<(-500),<(-500),<(-400),<(-400),<(-300)
  .byte <(-300),<(-400),<(-400),<(-500),<(-500),<(-400),<(-400),<(-300)
PST_KingMid_Hi:
  .byte >200, >300, >100, >0,   >0,   >100, >300, >200
  .byte >200, >200, >0,   >0,   >0,   >0,   >200, >200
  .byte >(-100),>(-200),>(-200),>(-200),>(-200),>(-200),>(-200),>(-100)
  .byte >(-200),>(-300),>(-300),>(-400),>(-400),>(-300),>(-300),>(-200)
  .byte >(-300),>(-400),>(-400),>(-500),>(-500),>(-400),>(-400),>(-300)
  .byte >(-300),>(-400),>(-400),>(-500),>(-500),>(-400),>(-400),>(-300)
  .byte >(-300),>(-400),>(-400),>(-500),>(-500),>(-400),>(-400),>(-300)
  .byte >(-300),>(-400),>(-400),>(-500),>(-500),>(-400),>(-400),>(-300)

; PST pointer tables (indexed by piece type 1-6). PstLoop loads a pair of
; pointers: PST_Table_Lo/Hi -> low-byte PST table; PST_TableHi_Lo/Hi -> high-
; byte PST table. Each piece's lo/hi tables are fetched in parallel by index.
PST_Table_Lo:
  .byte 0; 0: unused
  .byte <PST_Pawn_Lo; 1: Pawn
  .byte <PST_Knight_Lo; 2: Knight
  .byte <PST_Bishop_Lo; 3: Bishop
  .byte <PST_Rook_Lo; 4: Rook
  .byte <PST_Queen_Lo; 5: Queen
  .byte <PST_KingMid_Lo; 6: King (middlegame default)

PST_Table_Hi:
  .byte 0
  .byte >PST_Pawn_Lo
  .byte >PST_Knight_Lo
  .byte >PST_Bishop_Lo
  .byte >PST_Rook_Lo
  .byte >PST_Queen_Lo
  .byte >PST_KingMid_Lo

; Pointers to the high-byte (sign) PST tables.
PST_TableHi_Lo:
  .byte 0
  .byte <PST_Pawn_Hi
  .byte <PST_Knight_Hi
  .byte <PST_Bishop_Hi
  .byte <PST_Rook_Hi
  .byte <PST_Queen_Hi
  .byte <PST_KingMid_Hi

PST_TableHi_Hi:
  .byte 0
  .byte >PST_Pawn_Hi
  .byte >PST_Knight_Hi
  .byte >PST_Bishop_Hi
  .byte >PST_Rook_Hi
  .byte >PST_Queen_Hi
  .byte >PST_KingMid_Hi
