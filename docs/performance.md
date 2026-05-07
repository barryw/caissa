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

Current baseline from the first standalone benchmark run:

| Benchmark | Cycles | Gate |
| --- | ---: | ---: |
| easy mate in one | 1,799,660 | 2,400,000 |
| medium mate in one | 1,799,694 | 2,400,000 |
| hard mate in one | 1,799,694 | 2,400,000 |
| depth-1 hanging queen search | 739,901 | 950,000 |
| hard hanging queen | 446,191 | 700,000 |
| hard white promotion | 428,150 | 650,000 |
| hard black promotion | 431,709 | 650,000 |
| hard rook activation | 478,844 | 750,000 |

`make size` reports ld65 segment sizes from `build/engine_harness.dbg`. The first
standalone ca65 baseline is:

| Segment | Range | Bytes |
| --- | --- | ---: |
| `LOADADDR` | `$0000-$0001` | 2 |
| `CODE` | `$0801-$5e7d` | 22,141 |
| total PRG payload | | 22,143 |

Treat benchmark changes as suspicious until they have both a cycle explanation
and a strength/correctness test result. The goal is to make every optimization
visible as either fewer cycles, fewer bytes, or a deliberately accepted tradeoff.
