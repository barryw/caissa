; Generated ca65 port from Chess/constants.asm.
; Keep source changes in this repository in ca65 syntax.

; Constants and Hardware Definitions
; Memory layout, piece definitions, game constants, zero page allocations

.segment "CODE"

;
; Memory Layout
;

; The bank the VIC-II chip will be in
BANK = $00

; The start of physical RAM the VIC-II will see
VIC_START = (BANK * $4000)

; The starting sprite pointer
START_SPRITE_PTR = $30

; The location in memory for our sprites
SPRITE_MEMORY = VIC_START + (START_SPRITE_PTR * $40)

; The location in memory for our characters
CHARACTER_MEMORY = $3000

; The location of screen memory in whatever bank we're in
SCREEN_MEMORY = VIC_START + $0400

; The location of sprite pointer memory
SPRPTR = SCREEN_MEMORY + $03f8

; The location of color RAM is constant
COLOR_MEMORY = $d800

; The offset between color memory and screen memory (in bank 0)
COLOR_MEMORY_OFFSET = COLOR_MEMORY - SCREEN_MEMORY

;
; Memory Configuration ($01 Processor Port)
; Controls ROM/RAM banking for maximum memory utilization
;
; Bit 0 (LORAM):  Affects BASIC visibility (only when HIRAM=1)
; Bit 1 (HIRAM):  0 = RAM at $E000-$FFFF AND $A000-$BFFF, 1 = KERNAL ROM
; Bit 2 (CHAREN): 0 = CHAR ROM at $D000, 1 = I/O
; NOTE: When HIRAM=0, BOTH BASIC and KERNAL are banked out regardless of LORAM
;
MEMORY_CONFIG_DEFAULT = $37; BASIC + KERNAL + I/O (stock C64)
MEMORY_CONFIG_NORMAL = $34; RAM + RAM + I/O (16KB extra!)
MEMORY_CONFIG_TURBO = $30; ALL RAM (20KB extra, NO I/O!)

;
; Extended Memory Regions (available with MEMORY_CONFIG_NORMAL)
;
BOOK_HASH_TABLE = $5600; Opening book hash table start
BOOK_HASH_SIZE = $4A00; ~18.5KB for hash table ($5600-$9FFF)
SWAP_BUFFER = $A000; 8KB swap buffer for disk loading
SWAP_BUFFER_SIZE = $2000; 8KB
; $C000-$CFFF reserved for Transposition Table (see ai/tt.asm)
BOOK_ENTRIES = $E000; 8KB for book entry data
BOOK_ENTRIES_SIZE = $2000; 8KB
TURBO_WORKSPACE = $D000; 4KB extra during turbo mode
TURBO_WORKSPACE_SIZE = $1000; 4KB (only when I/O disabled!)

;
; Timing Constants
;

; The speed of the title's color scroll. Higher is slower
TITLE_COLOR_SCROLL_SPEED = $08

; The speed that the spinner rotates. Higher is slower
THINKING_SPINNER_SPEED = $1e

; The cursor flash speed
CURSOR_FLASH_SPEED = $10

; The speed to flash the selected piece at
PIECE_FLASH_SPEED = $10

;
; IRQ Vectors
;

NMI_VECTOR = $fffa
RESET_VECTOR = $fffc
IRQ_VECTOR = $fffe

;
; Piece Definitions
;

; Set the high bit on our pieces to make them white
BLACK_COLOR = %00000000
WHITE_COLOR = %10000000

; 
; Sprite pointers for the 6 pieces + empty. The pointers must be < 128
; so that we can store color information in the high bit.
; 
EMPTY_SPR = START_SPRITE_PTR
PAWN_SPR = START_SPRITE_PTR + 1
KNIGHT_SPR = START_SPRITE_PTR + 2
BISHOP_SPR = START_SPRITE_PTR + 3
ROOK_SPR = START_SPRITE_PTR + 4
QUEEN_SPR = START_SPRITE_PTR + 5
KING_SPR = START_SPRITE_PTR + 6

; 
; Add color information using the high bit of the sprite pointer. These are the
; values stored in Board88
; 
EMPTY_PIECE = EMPTY_SPR   + BLACK_COLOR
WHITE_PAWN = PAWN_SPR    + WHITE_COLOR
BLACK_PAWN = PAWN_SPR    + BLACK_COLOR
WHITE_KNIGHT = KNIGHT_SPR  + WHITE_COLOR
BLACK_KNIGHT = KNIGHT_SPR  + BLACK_COLOR
WHITE_BISHOP = BISHOP_SPR  + WHITE_COLOR
BLACK_BISHOP = BISHOP_SPR  + BLACK_COLOR
WHITE_ROOK = ROOK_SPR    + WHITE_COLOR
BLACK_ROOK = ROOK_SPR    + BLACK_COLOR
WHITE_KING = KING_SPR    + WHITE_COLOR
BLACK_KING = KING_SPR    + BLACK_COLOR
WHITE_QUEEN = QUEEN_SPR   + WHITE_COLOR
BLACK_QUEEN = QUEEN_SPR   + BLACK_COLOR

; Piece type constants (lower 7 bits, used for type checks)
; These equal piece_value & $7F - EMPTY_SPR
PAWN_TYPE = $01
KNIGHT_TYPE = $02
BISHOP_TYPE = $03
ROOK_TYPE = $04
QUEEN_TYPE = $05
KING_TYPE = $06

;
; Player and Game Constants
;

ZERO_PLAYERS = $00
ONE_PLAYER = $01
TWO_PLAYERS = $02

KEY_0 = $30

; Constants for the coordinate selections
INPUT_MOVE_FROM = $00
INPUT_MOVE_TO = $80

; index positions into the structure containing play
; clock information
WHITE_CLOCK_POS = $00
BLACK_CLOCK_POS = $03

; These indicate the current player
WHITES_TURN = $01
BLACKS_TURN = $00

;
; Raster Constants
;

RASTER_START = $27
PIECE_HEIGHT = $18
PIECE_WIDTH = PIECE_HEIGHT
NUM_ROWS = $08
NUM_COLS = NUM_ROWS

;
; Difficulty Levels
;

LEVEL_EASY = $00
LEVEL_MEDIUM = $01
LEVEL_HARD = $02

; Time budgets in jiffies (1/60 second)
TIME_EASY = 180; 3 seconds
TIME_MEDIUM = 600; 10 seconds
TIME_HARD = 1500; 25 seconds

;
; AI Search Constants
;

MATE_SCORE = 120; Score for checkmate (+120 = we win, -120 = we lose)
DRAW_SCORE = 0; Score for stalemate/draw
NEG_INFINITY = $80; -128 as signed byte (worst possible)
MAX_DEPTH = 8; Maximum search depth
MAX_KILLER_DEPTH = 16; Maximum killer move storage depth

;
; Game State Constants (returned by CheckGameState)
;
GAME_NORMAL = $00; Not in check, has moves
GAME_CHECK = $01; In check, has moves
GAME_CHECKMATE = $02; In check, no moves
GAME_STALEMATE = $03; Not in check, no moves
GAME_DRAW_50_MOVE = $04; Claimable 50-move rule draw
GAME_DRAW_REPETITION = $05; Claimable threefold repetition draw
GAME_DRAW_INSUFFICIENT = $06; Insufficient material draw
GAME_DRAW_75_MOVE = $07; Automatic 75-move no-progress draw
GAME_DRAW_REPETITION_AUTO = $08; Automatic fivefold repetition draw

;
; Menu Constants
;

MENU_GAME = $00
MENU_MAIN = $01
MENU_QUIT = $02
MENU_PLAYER_SELECT = $03
MENU_COLOR_SELECT = $04
MENU_LEVEL_SELECT = $05
MENU_ABOUT_SHOWING = $06
MENU_FORFEIT = $07
MENU_PROMOTION = $08
MENU_GAME_OVER = $09

;
; Enable/Disable and Bit Constants
;

; We enable by setting bit 8
ENABLE = $80
DISABLE = $00

; Bit 8
BIT8 = ENABLE

; Bit 7
BIT7 = $40

; Lower 7 bits
LOWER7 = $7f

;
; 0x88 Board Constants
;

; Board size in bytes (16 columns x 8 rows)
BOARD_SIZE = $80

; Off-board detection mask: (index & $88) != 0 means off-board
OFFBOARD_MASK = $88

; Row stride in 0x88 format
ROW_STRIDE = $10

; No en passant available
NO_EN_PASSANT = $ff

;
; Castling Rights Bitmap
;

CASTLE_WK = %00000001; White kingside
CASTLE_WQ = %00000010; White queenside
CASTLE_BK = %00000100; Black kingside
CASTLE_BQ = %00001000; Black queenside
CASTLE_ALL = %00001111; All rights intact

;
; Zero Page Allocations ($02-$25, 36 bytes)
; Note: $00-$01 = CPU port, $50-$5f = keyboard routine
;

; Memory copy/fill operations
copy_from = $02; 2 bytes: source pointer
copy_to = $04; 2 bytes: destination pointer
copy_size = $06; 2 bytes: byte count
fill_to = $08; 2 bytes: destination pointer
fill_size = $0a; 2 bytes: byte count
fill_value = $0c; 1 byte: fill value

; Math operations
num1 = $0d; 2 bytes: operand 1
num2 = $0f; 2 bytes: operand 2
result = $11; 2 bytes: result

; Display pointers
printvector = $13; 2 bytes: print output location
capturedvector = $15; 2 bytes: captured pieces storage
inputlocationvector = $17; 2 bytes: user input screen location
printclockvector = $19; 2 bytes: clock display location

; General purpose temp storage
temp1 = $1b; 2 bytes
temp2 = $1d; 2 bytes

; String printing (PrintString/PrintAt)
str_ptr = $1f; 2 bytes: pointer to null-terminated string
scr_ptr = $21; 2 bytes: pointer to screen memory
col_ptr = $23; 2 bytes: pointer to color memory
print_color = $25; 1 byte: text color

; Move validation (IsSquareAttacked, piece validation)
attack_sq = $26; 1 byte: square being checked for attack
attack_color = $27; 1 byte: color attacking (0=black, 1=white)
move_delta = $28; 1 byte: calculated move delta (signed)
ray_dir = $29; 1 byte: current ray direction offset
ray_sq = $2a; 1 byte: current square in ray traversal
piece_type = $2b; 1 byte: piece type being validated

; AI Search temps (used by Negamax alpha-beta)
; Note: $e8-$ef are used by AI search functions (see below)
search_alpha = $2c; 1 byte: alpha bound for current call
search_beta = $2d; 1 byte: beta bound for current call

; Timer library registers ($30-$37)
; Used by CreateTimer, UpdateTimers, EnDisTimer
r0 = $30
r0L = $30
r0H = $31
r1 = $32
r1L = $32
r1H = $33
r2 = $34
r2L = $34
r2H = $35
r3 = $36
r3L = $36
r3H = $37

;
; Timer Library Constants
;
MAX_TIMERS = 8
TIMER_STRUCT_SIZE = 8
TIMER_STRUCT_BYTES = MAX_TIMERS * TIMER_STRUCT_SIZE; 64 bytes
TIMER_SINGLE_SHOT = 0
TIMER_CONTINUOUS = 1

; Timer IDs (for easy reference)
TIMER_FLASH_PIECE = 0
TIMER_FLASH_CURSOR = 1
TIMER_SPINNER = 2
TIMER_COLOR_CYCLE = 3

;
; Extended Zero Page Allocations ($e6-$fe)
; Used by AI search and move generation
;
; AI Search (Negamax and related):
; $e8 = negamax alpha parameter (passed to recursive calls)
; $e9 = negamax beta parameter (passed to recursive calls)
; $eb = current move score (negated child result)
;
; MakeMove/UnmakeMove:
; $f0-$f5 = temp storage for move processing
;
; Move Generation:
; $f7-$fa = temp storage for piece movement

;
; Pawn Direction Constants (for move validation)
;

PAWN_PUSH_WHITE = $f0; -16 (north)
PAWN_PUSH_BLACK = $10; +16 (south)
PAWN_START_RANK_WHITE = 6; Row 6 in 0x88 (rank 2)
PAWN_START_RANK_BLACK = 1; Row 1 in 0x88 (rank 7)
PAWN_PROMO_RANK_WHITE = 0; Row 0 in 0x88 (rank 8)
PAWN_PROMO_RANK_BLACK = 7; Row 7 in 0x88 (rank 1)

;
; Keyboard Constants
;

KEY_A = $01
KEY_B = $02
KEY_C = $03
KEY_D = $04
KEY_E = $05
KEY_F = $06
KEY_G = $07
KEY_H = $08
KEY_I = $09
KEY_J = $0a
KEY_K = $0b
KEY_L = $0c
KEY_M = $0d
KEY_N = $0e
KEY_O = $0f
KEY_P = $10
KEY_Q = $11
KEY_R = $12
KEY_S = $13
KEY_T = $14
KEY_U = $15
KEY_V = $16
KEY_W = $17
KEY_X = $18
KEY_Y = $19
KEY_Z = $1a

KEY_1 = $31
KEY_2 = $32
KEY_3 = $33
KEY_4 = $34
KEY_5 = $35
KEY_6 = $36
KEY_7 = $37
KEY_8 = $38
