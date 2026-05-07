# Relocation Notes

The ca65 port is relocatable at the code/data segment level. Host targets should
place these segments with their own linker config instead of editing engine code:

- `CODE`: engine code and ordinary resident data
- `PST`: optional piece-square-table segment when `ENGINE_FIXED_PST` is nonzero
- `LOADADDR`: only used by the test PRG harness

Runtime RAM not emitted into the binary:

- `ENGINE_TT_BASE`: base address for the 2KB transposition table (`TT_SIZE * TT_ENTRY_SIZE`)

Zero page is the non-relocatable ABI surface in the current engine. The code uses
these ranges directly for speed and indirect addressing:

- `$02-$2d`: shared pointers, math temps, attack temps, alpha/beta temps
- `$30-$37`: legacy timer scratch labels that remain in shared constants
- `$e0-$fe`: search, move generation, eval, zobrist, and TT scratch

C64 and Nova should each reserve those ranges or we should do a dedicated
zero-page remap refactor that replaces direct `$e0`/`$f0` scratch use with named
symbols. That refactor is mechanical but broad, so it should be tested separately
from the assembler port.
