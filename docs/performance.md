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
| easy mate in one | 1,869,130 | 2,400,000 |
| medium mate in one | 1,869,164 | 2,400,000 |
| hard mate in one | 1,869,164 | 2,400,000 |
| depth-1 hanging queen search | 741,683 | 950,000 |
| hard hanging queen | 482,247 | 700,000 |
| depth-5 middlegame search | 3,985,535 | 5,000,000 |
| hard white promotion | 447,608 | 650,000 |
| hard black promotion | 451,231 | 650,000 |
| hard rook activation | 514,136 | 750,000 |

`make size` reports ld65 segment sizes from `build/engine_harness.dbg`. `FILE`
is the emitted PRG payload; `RUNTIME` includes `BSS` RAM reserved by the linker.
Current standalone ca65 size:

| Segment | Range | Bytes |
| --- | --- | ---: |
| `LOADADDR` | `$0000-$0001` | 2 |
| `CODE` | `$0801-$526c` | 19,052 |
| `BSS` | `$526d-$6472` | 4,614 |
| PRG payload | | 19,054 |
| runtime footprint | | 23,668 |

Treat benchmark changes as suspicious until they have both a cycle explanation
and a strength/correctness test result. The goal is to make every optimization
visible as either fewer cycles, fewer bytes, or a deliberately accepted tradeoff.
