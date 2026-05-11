SIM6502_IMAGE ?= ghcr.io/barryw/sim6502:latest
SIM6502_PULL ?= always
CA65 ?= /Users/barry/Git/cc65/bin/ca65
LD65 ?= /Users/barry/Git/cc65/bin/ld65
PYTHON ?= python3
STOCKFISH_BACKEND ?= sim6502
STRENGTH_JOBS ?= 1
STOCKFISH_JOBS ?= 1
STOCKFISH_DEPTH ?= 8
STOCKFISH_MULTIPV ?= 3
STOCKFISH_GAME_DEPTH ?= 3
STOCKFISH_LADDER_DEPTH ?= 6
STOCKFISH_ANALYSIS_DEPTH ?= 6
STOCKFISH_ANALYSIS_MULTIPV ?= 3
STOCKFISH_GAMES_PER_SIDE ?= 1
STOCKFISH_ELOS ?= 1320,1520,1720
STOCKFISH_MAX_PLIES ?= 160
STOCKFISH_TIMEOUT_CYCLES ?= 750000000
COLOSSUS_MAX_PLIES ?= 20
COLOSSUS_TIMEOUT_SECONDS ?= 1800
COLOSSUS_BACKEND ?= vice
COLOSSUS_PROFILE ?= match
COLOSSUS_ENGINE_COLOR ?= white
COLOSSUS_RAW_CYCLES ?=
COLOSSUS_RAW_CYCLES_ARG = $(if $(COLOSSUS_RAW_CYCLES),--colossus-raw-cycles $(COLOSSUS_RAW_CYCLES),)
COLOSSUS_RAW_INPUT ?= queued
COLOSSUS_RAW_INPUT_GAP_CYCLES ?= 250000
COLOSSUS_RAW_INPUT_ARG = --colossus-raw-input $(COLOSSUS_RAW_INPUT) --colossus-raw-input-gap-cycles $(COLOSSUS_RAW_INPUT_GAP_CYCLES)
COLOSSUS_PARALLEL_WORKERS ?= 8
COLOSSUS_PARALLEL_OUTPUT ?= build/colossus_parallel
COLOSSUS_PARALLEL_OPENINGS ?=
COLOSSUS_PARALLEL_OPENINGS_ARG = $(if $(COLOSSUS_PARALLEL_OPENINGS),--openings $(COLOSSUS_PARALLEL_OPENINGS),)
COLOSSUS_VALID_BLUNDERS_ONLY ?= 1
COLOSSUS_VALID_BLUNDERS_ONLY_ARG = $(if $(filter 1 true yes,$(COLOSSUS_VALID_BLUNDERS_ONLY)),--valid-blunders-only,)
COLOSSUS_ANALYZE_TIMEOUT_PARTIALS ?= 1
COLOSSUS_ANALYZE_TIMEOUT_PARTIALS_ARG = $(if $(filter 0 false no,$(COLOSSUS_ANALYZE_TIMEOUT_PARTIALS)),--skip-timeout-partials,--analyze-timeout-partials)
COLOSSUS_RETRY_PARTIAL_TIMEOUTS ?= 0
COLOSSUS_RETRY_PARTIAL_TIMEOUTS_ARG = $(if $(filter 1 true yes,$(COLOSSUS_RETRY_PARTIAL_TIMEOUTS)),--retry-partial-timeouts,)
COLOSSUS_RETRY_RAW_CYCLES ?=
COLOSSUS_RETRY_RAW_CYCLES_ARG = $(if $(COLOSSUS_RETRY_RAW_CYCLES),--retry-colossus-raw-cycles $(COLOSSUS_RETRY_RAW_CYCLES),)
COLOSSUS_RETRY_MIN_PLIES ?=
COLOSSUS_RETRY_MIN_PLIES_ARG = $(if $(COLOSSUS_RETRY_MIN_PLIES),--retry-min-plies $(COLOSSUS_RETRY_MIN_PLIES),)
COLOSSUS_RETRY_WORKERS ?=
COLOSSUS_RETRY_WORKERS_ARG = $(if $(COLOSSUS_RETRY_WORKERS),--retry-workers $(COLOSSUS_RETRY_WORKERS),)
COLOSSUS_BLUNDER_THRESHOLD ?= 90
COLOSSUS_STOCKFISH_DEPTH ?= 8
COLOSSUS_MULTIPV ?= 3

BUILD_DIR := build
ENGINE_SOURCES := $(shell find src tests -name '*.s' -print)
SIM6502_RUNNER = docker run --pull=$(SIM6502_PULL) --rm -v $(PWD):/code $(SIM6502_IMAGE) /app/Sim6502TestRunner

.PHONY: all clean engine-build engine-test test benchmark benchmark-json size stockfish-tools-test stockfish-bridge-self-test stockfish-strength stockfish-blunder-check stockfish-games stockfish-elo stockfish-ladder-blunders colossus-probe colossus-match colossus-parallel colossus-blunders colossus-blunder-check

all: engine-build

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(BUILD_DIR)/engine_harness.o: tests/engine_harness.s $(ENGINE_SOURCES) | $(BUILD_DIR)
	$(CA65) --cpu 6502 -g -I src -I src/engine -I src/ai -o $@ $<

$(BUILD_DIR)/engine_harness.prg: $(BUILD_DIR)/engine_harness.o cfg/c64-prg.cfg tools/ld65_dbg_to_sim6502_sym.py
	$(LD65) -C cfg/c64-prg.cfg --dbgfile $(BUILD_DIR)/engine_harness.dbg -o $@ $<
	$(PYTHON) tools/ld65_dbg_to_sim6502_sym.py $(BUILD_DIR)/engine_harness.dbg $(BUILD_DIR)/engine_harness.sym

engine-build: $(BUILD_DIR)/engine_harness.prg

engine-test: engine-build
	$(SIM6502_RUNNER) -s /code/tests/engine_core.6502

benchmark: engine-build
	$(PYTHON) tools/run_engine_benchmarks.py --measure-cycles

benchmark-json: engine-build
	$(PYTHON) tools/run_engine_benchmarks.py --measure-cycles --json build/engine_benchmark.json

size: engine-build
	$(PYTHON) tools/report_size.py build/engine_harness.dbg

stockfish-tools-test:
	$(PYTHON) tools/run_stockfish_strength.py --self-test
	$(PYTHON) tools/run_stockfish_games.py --self-test
	$(PYTHON) tools/run_elo_ladder.py --self-test
	$(PYTHON) tools/extract_ladder_blunders.py --self-test
	$(PYTHON) tools/extract_colossus_blunders.py --self-test
	$(PYTHON) tools/merge_elo_ladders.py --self-test

stockfish-bridge-self-test: engine-build
	$(PYTHON) tools/sim6502_headless_runner.py --self-test

stockfish-strength: engine-build
	$(PYTHON) tools/run_stockfish_strength.py --runner-target headless --c64-backend $(STOCKFISH_BACKEND) --corpus tools/stockfish_strength_corpus.json --difficulty hard --stockfish-depth $(STOCKFISH_DEPTH) --multipv $(STOCKFISH_MULTIPV) --jobs $(STRENGTH_JOBS) --timeout-cycles $(STOCKFISH_TIMEOUT_CYCLES) --json build/stockfish_strength.json

stockfish-blunder-check: engine-build
	$(PYTHON) tools/run_stockfish_strength.py --runner-target headless --c64-backend $(STOCKFISH_BACKEND) --corpus tools/stockfish_game_blunders.json --corpus tools/stockfish_ladder_blunders.json --difficulty hard --stockfish-depth 2 --multipv 2 --jobs $(STRENGTH_JOBS) --timeout-cycles $(STOCKFISH_TIMEOUT_CYCLES) --json build/stockfish_blunder_check.json

stockfish-games: engine-build
	$(PYTHON) tools/run_stockfish_games.py --runner-target headless --c64-backend $(STOCKFISH_BACKEND) --difficulty hard --c64-side both --games-per-side $(STOCKFISH_GAMES_PER_SIDE) --stockfish-depth $(STOCKFISH_GAME_DEPTH) --analysis-depth $(STOCKFISH_ANALYSIS_DEPTH) --analysis-multipv $(STOCKFISH_ANALYSIS_MULTIPV) --max-plies $(STOCKFISH_MAX_PLIES) --book off --adjudicate-max-plies --json build/stockfish_games.json --pgn build/stockfish_games.pgn --blunder-corpus build/stockfish_game_blunders.json

stockfish-elo: engine-build
	$(PYTHON) tools/run_elo_ladder.py --runner-target headless --c64-backend $(STOCKFISH_BACKEND) --difficulty hard --c64-side both --games-per-side $(STOCKFISH_GAMES_PER_SIDE) --jobs $(STOCKFISH_JOBS) --stockfish-elos $(STOCKFISH_ELOS) --stockfish-depth $(STOCKFISH_LADDER_DEPTH) --analysis-depth $(STOCKFISH_ANALYSIS_DEPTH) --analysis-multipv $(STOCKFISH_ANALYSIS_MULTIPV) --start-fen-file tools/stockfish_opening_fens.txt --max-plies $(STOCKFISH_MAX_PLIES) --adjudicate-max-plies --json build/stockfish_elo_ladder.json --pgn build/stockfish_elo_ladder.pgn

stockfish-ladder-blunders:
	$(PYTHON) tools/extract_ladder_blunders.py build/stockfish_elo_ladder.json --json build/stockfish_ladder_blunders.json

colossus-probe:
	$(PYTHON) tools/probe_colossus_vice.py --json build/colossus_probe.json

colossus-match: engine-build
	$(PYTHON) tools/run_colossus_match.py --runner-target headless --c64-backend $(STOCKFISH_BACKEND) --difficulty hard --engine-color $(COLOSSUS_ENGINE_COLOR) --colossus-backend $(COLOSSUS_BACKEND) --colossus-profile $(COLOSSUS_PROFILE) $(COLOSSUS_RAW_CYCLES_ARG) $(COLOSSUS_RAW_INPUT_ARG) --max-plies $(COLOSSUS_MAX_PLIES) --colossus-timeout-seconds $(COLOSSUS_TIMEOUT_SECONDS) --json build/colossus_match.json --pgn build/colossus_match.pgn

colossus-parallel: engine-build
	$(PYTHON) tools/run_colossus_parallel.py --engine-color $(COLOSSUS_ENGINE_COLOR) --profile $(COLOSSUS_PROFILE) $(COLOSSUS_RAW_CYCLES_ARG) $(COLOSSUS_RAW_INPUT_ARG) --max-plies $(COLOSSUS_MAX_PLIES) --workers $(COLOSSUS_PARALLEL_WORKERS) --output-dir $(COLOSSUS_PARALLEL_OUTPUT) --analyze-blunders $(COLOSSUS_VALID_BLUNDERS_ONLY_ARG) $(COLOSSUS_ANALYZE_TIMEOUT_PARTIALS_ARG) $(COLOSSUS_RETRY_PARTIAL_TIMEOUTS_ARG) $(COLOSSUS_RETRY_RAW_CYCLES_ARG) $(COLOSSUS_RETRY_MIN_PLIES_ARG) $(COLOSSUS_RETRY_WORKERS_ARG) --stockfish-depth $(COLOSSUS_STOCKFISH_DEPTH) --multipv $(COLOSSUS_MULTIPV) --threshold $(COLOSSUS_BLUNDER_THRESHOLD) $(COLOSSUS_PARALLEL_OPENINGS_ARG)

colossus-blunders:
	$(PYTHON) tools/extract_colossus_blunders.py build/colossus_match.json --stockfish-depth $(COLOSSUS_STOCKFISH_DEPTH) --multipv $(COLOSSUS_MULTIPV) --threshold $(COLOSSUS_BLUNDER_THRESHOLD) --json build/colossus_blunders.json --analysis-json build/colossus_blunder_analysis.json

colossus-blunder-check: engine-build
	$(PYTHON) tools/run_stockfish_strength.py --runner-target headless --c64-backend $(STOCKFISH_BACKEND) --corpus tools/colossus_blunders.json --difficulty hard --stockfish-depth $(COLOSSUS_STOCKFISH_DEPTH) --multipv $(COLOSSUS_MULTIPV) --jobs $(STRENGTH_JOBS) --timeout-cycles $(STOCKFISH_TIMEOUT_CYCLES) --json build/colossus_blunder_check.json

# Boundary tests pin the public Chess* API labels against the headless engine.
test: engine-build
	$(SIM6502_RUNNER) -s /code/tests/engine_core.6502
	$(SIM6502_RUNNER) -s /code/tests/engine_boundary.6502
	$(SIM6502_RUNNER) -s /code/tests/engine_loop.6502
	$(SIM6502_RUNNER) -s /code/tests/engine_repetition.6502
	$(SIM6502_RUNNER) -s /code/tests/engine_state.6502

clean:
	rm -rf $(BUILD_DIR)
