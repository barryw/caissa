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
ENGINE  := $(SRC)/board.c $(SRC)/movegen.c $(SRC)/eval.c $(SRC)/search_fullwidth.c $(SRC)/egtb.c
HDRS    := $(wildcard $(SRC)/*.h)
INC     := -I$(SRC)

.PHONY: all cli verify test cref_mos c64 gate clean

all: cli
cli: $(BUILD)/cref

$(BUILD)/cref: $(ENGINE) apps/cli/cref.c $(HDRS) | $(BUILD)
	$(CC) $(CFLAGS) $(INC) $(ENGINE) apps/cli/cref.c -o $@ -lm

# matched-config oracle (TT8 / MAX_PLY=7 / no history) for 6502 move-fidelity
cref_mos: $(BUILD)/cref_mos
$(BUILD)/cref_mos: $(ENGINE) apps/cli/cref.c $(HDRS) | $(BUILD)
	$(CC) -O3 -w -D__mos__ $(INC) $(ENGINE) apps/cli/cref.c -o $@ -lm

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
	$(CC) $(CFLAGS) $(INC) $(ENGINE) $(SRC)/caissa.c test/test_api.c -o $@ -lm

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
