# Caïssa — single C engine (src/), front-ends (apps/), tests (test/).
#
#   make            -> build/cref            (host engine CLI: bestmove, selfplay)
#   make verify     -> perft vs python-chess + eval bit-exact vs texel_eval
#   make cref_mos   -> matched-config (__mos__) host oracle for 6502 fidelity
#   make c64        -> the playable C64 game (chess.prg) via tools/build_c64.sh
#   make gate       -> tools/llvmmos_bench/speed_gate.sh (6502 fidelity + speed)
#   make clean      -> remove built binaries (NEVER rm -rf build/: it holds
#                      irreplaceable assets like build/colossus_extract)
#
# The 6502 / measurement tooling lives under tools/ (build scripts + sim + the
# Colossus harness); see README.md and docs/ARCHITECTURE.md.

CC      ?= cc
CFLAGS  ?= -O3 -Wall -Wno-unused-result
PYTHON  ?= python3

SRC     := src
BUILD   := build
# Search plugin: fullwidth (default) or selective (Colossus-style, stock C64). One TU
# is linked; both #include src/search_core.inc. `make SEARCH=selective ...`.
SEARCH  ?= fullwidth
# A selective build must define CREF_SEARCH_SELECTIVE for EVERY TU that links the
# search engine (search_core.inc) so the shared SearchConfig struct (src/search.h)
# is ABI-consistent across TUs. It comes from -D (not a #define inside one .c) for
# that reason. Full-width builds leave it undefined -> SearchConfig unchanged ->
# byte-identical reference preserved.
SELDEF  :=
ifeq ($(SEARCH),selective)
SELDEF  := -DCREF_SEARCH_SELECTIVE=1
endif
ENGINE  := $(SRC)/board.c $(SRC)/movegen.c $(SRC)/eval.c $(SRC)/search_$(SEARCH).c $(SRC)/egtb.c
HDRS    := $(wildcard $(SRC)/*.h)
INC     := -I$(SRC)

.PHONY: all cli verify test cref_mos c64 gate clean

all: cli
cli: $(BUILD)/cref

$(BUILD)/cref: $(ENGINE) apps/cli/cref.c $(HDRS) | $(BUILD)
	$(CC) $(CFLAGS) $(SELDEF) $(INC) $(ENGINE) apps/cli/cref.c -o $@ -lm

# matched-config oracle (TT8 / MAX_PLY=7 / no history) for 6502 move-fidelity
cref_mos: $(BUILD)/cref_mos
$(BUILD)/cref_mos: $(ENGINE) apps/cli/cref.c $(HDRS) | $(BUILD)
	$(CC) -O3 -w -D__mos__ $(SELDEF) $(INC) $(ENGINE) apps/cli/cref.c -o $@ -lm

$(BUILD)/test_perft: $(SRC)/board.c $(SRC)/movegen.c $(SRC)/eval.c test/test_perft.c $(HDRS) | $(BUILD)
	$(CC) $(CFLAGS) $(INC) $(SRC)/board.c $(SRC)/movegen.c $(SRC)/eval.c test/test_perft.c -o $@
$(BUILD)/test_eval: $(SRC)/board.c $(SRC)/eval.c test/test_eval.c $(HDRS) | $(BUILD)
	$(CC) $(CFLAGS) $(INC) $(SRC)/board.c $(SRC)/eval.c test/test_eval.c -o $@
$(BUILD)/test_king_danger: $(SRC)/board.c $(SRC)/eval.c test/test_king_danger.c $(HDRS) | $(BUILD)
	$(CC) $(CFLAGS) $(INC) $(SRC)/board.c $(SRC)/eval.c test/test_king_danger.c -o $@
$(BUILD)/test_see: $(SRC)/board.c $(SRC)/movegen.c $(SRC)/eval.c test/test_see.c $(HDRS) | $(BUILD)
	$(CC) $(CFLAGS) $(INC) $(SRC)/board.c $(SRC)/movegen.c $(SRC)/eval.c test/test_see.c -o $@

# public engine<->UI API (src/caissa.c) + its test
$(BUILD)/test_api: $(ENGINE) $(SRC)/caissa.c test/test_api.c $(HDRS) | $(BUILD)
	$(CC) $(CFLAGS) $(SELDEF) $(INC) $(ENGINE) $(SRC)/caissa.c test/test_api.c -o $@ -lm

verify test: $(BUILD)/test_perft $(BUILD)/test_eval $(BUILD)/test_api $(BUILD)/test_king_danger $(BUILD)/test_see
	$(PYTHON) test/native_perft_check.py
	$(PYTHON) test/native_eval_check.py
	./$(BUILD)/test_api
	./$(BUILD)/test_king_danger
	./$(BUILD)/test_see

c64:
	./tools/build_c64.sh

gate:
	bash tools/llvmmos_bench/speed_gate.sh

$(BUILD):
	mkdir -p $(BUILD)

clean:
	rm -f $(BUILD)/cref $(BUILD)/cref_mos $(BUILD)/test_eval $(BUILD)/test_perft
