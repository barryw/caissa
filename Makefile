SIM6502_IMAGE ?= ghcr.io/barryw/sim6502:latest
SIM6502_PULL ?= always
CA65 ?= /Users/barry/Git/cc65/bin/ca65
LD65 ?= /Users/barry/Git/cc65/bin/ld65
PYTHON ?= python3

BUILD_DIR := build
ENGINE_SOURCES := $(shell find src tests -name '*.s' -print)
SIM6502_RUNNER = docker run --pull=$(SIM6502_PULL) --rm -v $(PWD):/code $(SIM6502_IMAGE) /app/Sim6502TestRunner

.PHONY: all clean engine-build engine-test test benchmark benchmark-json size

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

# Boundary tests pin the public Chess* API labels against the headless engine.
test: engine-build
	$(SIM6502_RUNNER) -s /code/tests/engine_core.6502
	$(SIM6502_RUNNER) -s /code/tests/engine_boundary.6502
	$(SIM6502_RUNNER) -s /code/tests/engine_loop.6502

clean:
	rm -rf $(BUILD_DIR)
