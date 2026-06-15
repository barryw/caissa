# Native reference engine (Tier 3) -- lightning eval A/B.
#   make            -> cref (the engine + self-play CLI)
#   make verify     -> perft vs python-chess + eval bit-exact vs texel_eval
CC      ?= cc
CFLAGS  ?= -O3 -Wall -Wno-unused-result
LDLIBS  ?= -lm

CORE    = board.c movegen.c eval.c
HDRS    = board.h movegen.h eval.h search.h

all: cref

cref: $(CORE) search.c cref.c $(HDRS)
	$(CC) $(CFLAGS) $(CORE) search.c cref.c -o cref $(LDLIBS)

test_perft: board.c movegen.c test_perft.c $(HDRS)
	$(CC) $(CFLAGS) board.c movegen.c test_perft.c -o test_perft

test_eval: board.c eval.c test_eval.c $(HDRS)
	$(CC) $(CFLAGS) board.c eval.c test_eval.c -o test_eval

verify: test_perft test_eval
	cd .. && python3 tools/native_perft_check.py
	cd .. && python3 tools/native_eval_check.py

clean:
	rm -f cref test_perft test_eval

.PHONY: all verify clean
