# Performance Loop

Use the headless ca65 harness for fast, repeatable performance checks:

```sh
make benchmark
make benchmark-json
make size
```

`make benchmark` runs `tests/engine_benchmark.6502` through the latest Sim6502
Docker image and then reruns a temporary copy with cycle assertions forced to
fail, which exposes exact cycle counts without weakening the checked-in gates.

Current standalone benchmark baseline:

| Benchmark | Cycles | Gate |
| --- | ---: | ---: |
| easy mate in one | 587,819 | 2,400,000 |
| medium mate in one | 587,819 | 2,400,000 |
| hard mate in one | 587,819 | 2,400,000 |
| depth-1 hanging queen search | 837,697 | 1,000,000 |
| hard hanging queen | 660,612 | 700,000 |
| depth-5 middlegame search | 4,535,000 | 5,000,000 |
| hard white promotion | 499,361 | 650,000 |
| hard black promotion | 499,539 | 650,000 |
| hard rook activation | 677,471 | 750,000 |

`make size` reports ld65 segment sizes from `build/engine_harness.dbg`. `FILE`
is the emitted PRG payload; `RUNTIME` includes `BSS` RAM reserved by the linker.
Current standalone ca65 size:

| Segment | Range | Bytes |
| --- | --- | ---: |
| `LOADADDR` | `$0000-$0001` | 2 |
| `CODE` | `$0801-$6c0f` | 25,615 |
| `BSS` | `$6c10-$7e97` | 4,744 |
| PRG payload | | 25,617 |
| runtime footprint | | 30,361 |

The resident engine budget target is 35K runtime footprint. The current
standalone harness leaves 5,479 bytes for additional resident engine logic
before hitting that ceiling. The current label span ends at `$7e92`, leaving
365 bytes before `$8000` in this memory map.

Treat benchmark changes as suspicious until they have both a cycle explanation
and a strength/correctness test result. The goal is to make every optimization
visible as either fewer cycles, fewer bytes, or a deliberately accepted tradeoff.
