# T-FLEX top-level Makefile
# Phase 1: only `check-env`, `lint` and `test` (package checks) are implemented.
# Other targets become real as milestones land (docs/plan.md).

SHELL     := /bin/bash
ROOT      := $(abspath .)
PY        ?= $(if $(wildcard .venv/bin/python),.venv/bin/python,python3)
SV2V      ?= $(if $(wildcard .tools/sv2v),.tools/sv2v,sv2v)
BUILD     := build
RTL_PKG   := rtl/common/tflex_pkg.sv
VFLAGS    := rtl/lint_waivers.vlt --timing --assert -Wall -Wno-DECLFILENAME -Irtl/common

.PHONY: help check-env setup lint test simulate experiment plots synth docs clean

help:
	@echo "Targets:"
	@echo "  setup       install tools + Python venv (scripts/setup_env.sh)"
	@echo "  check-env   report tool versions"
	@echo "  lint        Verilator lint + sv2v/Yosys parse of all RTL"
	@echo "  test        RTL unit tests (Phase 1: package size checks)"
	@echo "  simulate    [M1+]  directed system simulation"
	@echo "  experiment  [M12]  run configs/experiments.yaml"
	@echo "  plots       [M12]  regenerate results/plots/"
	@echo "  synth       [M4+]  Yosys synthesis reports into results/reports/"

setup:
	./scripts/setup_env.sh

check-env:
	./scripts/check_env.sh

lint:
	verilator --lint-only -Wall rtl/lint_waivers.vlt $(RTL_PKG)
	@mkdir -p $(BUILD)
	$(SV2V) $(RTL_PKG) > $(BUILD)/tflex_pkg_conv.v
	yosys -q -p "read_verilog $(BUILD)/tflex_pkg_conv.v"
	@echo "lint: PASS"

$(BUILD)/tb_pkg_sizes/Vtb_pkg_sizes: $(RTL_PKG) tb/directed/tb_pkg_sizes.sv
	@mkdir -p $(BUILD)
	verilator --binary $(VFLAGS) --Mdir $(BUILD)/tb_pkg_sizes --top-module tb_pkg_sizes $^ > $(BUILD)/tb_pkg_sizes.build.log

test: $(BUILD)/tb_pkg_sizes/Vtb_pkg_sizes
	./$<

simulate experiment plots synth:
	@echo "make $@: not implemented yet - see docs/plan.md for the milestone that adds it"; exit 2

clean:
	rm -rf $(BUILD) obj_dir sim_build results.xml
