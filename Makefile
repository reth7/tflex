# T-FLEX top-level Makefile
# Implemented: check-env, lint, test (pytest golden models, package checks,
# Milestone 1 and 2 regressions),
# wave (FST dump of a short link run), diagram (Yosys netlist SVGs).
# Other targets become real as milestones land (docs/plan.md).

SHELL     := /bin/bash
PY        ?= $(if $(wildcard .venv/bin/python),.venv/bin/python,python3)
SV2V      ?= $(if $(wildcard .tools/sv2v),.tools/sv2v,sv2v)
BUILD     := build
WAIVERS   := rtl/lint_waivers.vlt

# RTL source list (package first). [sim] modules are included: they are
# synthesizable, just not meant to be part of a die.
RTL_PKG   := rtl/common/tflex_pkg.sv
RTL_SRCS  := $(RTL_PKG) \
             rtl/common/tflex_reset_sync.sv rtl/common/tflex_sync_bits.sv \
             rtl/common/tflex_delay_line.sv rtl/common/tflex_async_fifo.sv \
             rtl/common/tflex_crc.sv \
             rtl/adapter/tflex_pkt_len_check.sv rtl/adapter/tflex_packetizer.sv \
             rtl/adapter/tflex_depacketizer.sv rtl/adapter/tflex_retry_tx.sv \
             rtl/adapter/tflex_retry_rx.sv rtl/adapter/tflex_credit_return.sv \
             rtl/adapter/tflex_sb_mux.sv rtl/fault/tflex_fault_injector.sv \
             rtl/phy/tflex_phy_tx.sv rtl/phy/tflex_phy_rx.sv \
             rtl/link/tflex_d2d_channel.sv rtl/link/tflex_sideband_channel.sv \
             rtl/link/tflex_d2d_link_simplex.sv \
             rtl/top/tflex_traffic_src.sv rtl/top/tflex_traffic_sink.sv
LINT_TOPS := tflex_d2d_link_simplex tflex_traffic_src tflex_traffic_sink \
             tflex_packetizer tflex_depacketizer tflex_reset_sync tflex_crc \
             tflex_retry_tx tflex_retry_rx tflex_credit_return tflex_sb_mux \
             tflex_fault_injector
SVA_SRCS  := tb/assertions/tflex_stream_sva.sv tb/assertions/tflex_async_fifo_sva.sv \
             tb/assertions/tflex_link_m1_sva.sv tb/assertions/tflex_retry_sva.sv \
             tb/assertions/tflex_fault_injector_sva.sv

# Testbench builds: RTL is linted with -Wall in `make lint`; testbench code
# waives style warnings that are normal for behavioural TB code.
TB_WAIVE  := -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SYNCASYNCNET -Wno-BLKSEQ \
             -Wno-UNUSEDSIGNAL -Wno-DECLFILENAME
VFLAGS    := $(WAIVERS) --timing --assert --timescale 1ps/1ps -Wall $(TB_WAIVE) -j 2

.PHONY: help check-env setup lint test test-py test-m1 test-m2 wave diagram simulate experiment plots synth clean

help:
	@echo "Targets:"
	@echo "  setup       install tools + Python venv (scripts/setup_env.sh)"
	@echo "  check-env   report tool versions"
	@echo "  lint        Verilator -Wall lint of every RTL top + sv2v/Yosys elaboration"
	@echo "  test        Python golden models + package checks + M1 and M2 regressions"
	@echo "  test-py     Python golden-model tests (pytest)"
	@echo "  test-m1     Milestone 1 regression only"
	@echo "  test-m2     Milestone 2 regression only"
	@echo "  wave        FST waveform of tb_link_m1 (nominal clocks, 256 B + 4096 B)"
	@echo "  diagram     Yosys netlist SVGs of the link, phy_tx and async FIFO"
	@echo "  simulate    [M5+]  system simulation"
	@echo "  experiment  [M12]  run configs/experiments.yaml"
	@echo "  plots       [M12]  regenerate results/plots/"
	@echo "  synth       [M4]   Yosys synthesis reports into results/reports/"

setup:
	./scripts/setup_env.sh

check-env:
	./scripts/check_env.sh

lint:
	@mkdir -p $(BUILD)
	@for t in $(LINT_TOPS); do \
	  echo "verilator lint: $$t"; \
	  verilator --lint-only -Wall $(WAIVERS) $(RTL_SRCS) --top-module $$t || exit 1; \
	done
	$(SV2V) $(RTL_SRCS) > $(BUILD)/tflex_rtl_conv.v
	@for t in $(LINT_TOPS); do \
	  yosys -q -p "read_verilog $(BUILD)/tflex_rtl_conv.v; hierarchy -check -top $$t; proc" || exit 1; \
	done
	@echo "lint: PASS"

# ------------------------------------------------------------------ builds
$(BUILD)/tb_pkg_sizes/Vtb_pkg_sizes: $(RTL_PKG) tb/directed/tb_pkg_sizes.sv
	@mkdir -p $(BUILD)
	verilator --binary $(VFLAGS) --Mdir $(BUILD)/tb_pkg_sizes --top-module tb_pkg_sizes $^ > $(BUILD)/tb_pkg_sizes.build.log

$(BUILD)/tb_async_fifo/Vtb_async_fifo: $(RTL_SRCS) $(SVA_SRCS) tb/directed/tb_async_fifo.sv
	@mkdir -p $(BUILD)
	verilator --binary $(VFLAGS) --Mdir $(BUILD)/tb_async_fifo --top-module tb_async_fifo \
	  $(RTL_PKG) rtl/common/tflex_reset_sync.sv rtl/common/tflex_sync_bits.sv rtl/common/tflex_async_fifo.sv \
	  tb/assertions/tflex_stream_sva.sv tb/assertions/tflex_async_fifo_sva.sv tb/directed/tb_async_fifo.sv \
	  > $(BUILD)/tb_async_fifo.build.log

$(BUILD)/tb_link_m1/Vtb_link_m1: $(RTL_SRCS) $(SVA_SRCS) tb/directed/tb_link_m1.sv
	@mkdir -p $(BUILD)
	verilator --binary $(VFLAGS) --Mdir $(BUILD)/tb_link_m1 --top-module tb_link_m1 \
	  $(RTL_SRCS) $(SVA_SRCS) tb/directed/tb_link_m1.sv > $(BUILD)/tb_link_m1.build.log

CRC_NVEC  := 100000
$(BUILD)/crc_vectors.txt: scripts/gen_crc_vectors.py python/tflex/protocol/crc.py
	@mkdir -p $(BUILD)
	$(PY) scripts/gen_crc_vectors.py $(CRC_NVEC) 1 $@

$(BUILD)/tb_crc/Vtb_crc: $(RTL_PKG) rtl/common/tflex_crc.sv tb/directed/tb_crc.sv
	@mkdir -p $(BUILD)
	verilator --binary $(VFLAGS) --Mdir $(BUILD)/tb_crc --top-module tb_crc $^ > $(BUILD)/tb_crc.build.log

# Same testbench with an 8-entry replay buffer (window-full tests)
$(BUILD)/tb_link_m1_rd8/Vtb_link_m1: $(RTL_SRCS) $(SVA_SRCS) tb/directed/tb_link_m1.sv
	@mkdir -p $(BUILD)
	verilator --binary $(VFLAGS) -GRETRY_D=8 --Mdir $(BUILD)/tb_link_m1_rd8 --top-module tb_link_m1 \
	  $(RTL_SRCS) $(SVA_SRCS) tb/directed/tb_link_m1.sv > $(BUILD)/tb_link_m1_rd8.build.log

# Same testbench with a replay timeout shorter than the ACK round trip (duplicate test)
$(BUILD)/tb_link_m1_rto/Vtb_link_m1: $(RTL_SRCS) $(SVA_SRCS) tb/directed/tb_link_m1.sv
	@mkdir -p $(BUILD)
	verilator --binary $(VFLAGS) -GREPLAY_TO=20 --Mdir $(BUILD)/tb_link_m1_rto --top-module tb_link_m1 \
	  $(RTL_SRCS) $(SVA_SRCS) tb/directed/tb_link_m1.sv > $(BUILD)/tb_link_m1_rto.build.log

$(BUILD)/tb_fault_injector/Vtb_fault_injector: $(RTL_PKG) rtl/common/tflex_reset_sync.sv rtl/fault/tflex_fault_injector.sv \
    tb/assertions/tflex_fault_injector_sva.sv tb/directed/tb_fault_injector.sv
	@mkdir -p $(BUILD)
	verilator --binary $(VFLAGS) --Mdir $(BUILD)/tb_fault_injector --top-module tb_fault_injector $^ > $(BUILD)/tb_fault_injector.build.log

$(BUILD)/tb_sb_mux/Vtb_sb_mux: $(RTL_PKG) rtl/common/tflex_reset_sync.sv rtl/adapter/tflex_sb_mux.sv \
    tb/assertions/tflex_stream_sva.sv tb/assertions/tflex_retry_sva.sv tb/directed/tb_sb_mux.sv
	@mkdir -p $(BUILD)
	verilator --binary $(VFLAGS) --Mdir $(BUILD)/tb_sb_mux --top-module tb_sb_mux $^ > $(BUILD)/tb_sb_mux.build.log

# ------------------------------------------------------------------ tests
test: test-py $(BUILD)/tb_pkg_sizes/Vtb_pkg_sizes test-m1 test-m2
	./$(BUILD)/tb_pkg_sizes/Vtb_pkg_sizes

test-py:
	$(PY) -m pytest -q

test-m1: $(BUILD)/tb_async_fifo/Vtb_async_fifo $(BUILD)/tb_link_m1/Vtb_link_m1
	./scripts/run_m1_tests.sh

test-m2: $(BUILD)/tb_crc/Vtb_crc $(BUILD)/crc_vectors.txt $(BUILD)/tb_fault_injector/Vtb_fault_injector \
         $(BUILD)/tb_sb_mux/Vtb_sb_mux $(BUILD)/tb_link_m1/Vtb_link_m1 $(BUILD)/tb_link_m1_rd8/Vtb_link_m1 \
         $(BUILD)/tb_link_m1_rto/Vtb_link_m1
	CRC_NVEC=$(CRC_NVEC) ./scripts/run_m2_tests.sh

# ------------------------------------------------------------------ debug views
# Separate traced build of tb_link_m1; the regression binary has no dump code.
WAVE_FST  := $(BUILD)/wave/link_m1_single.fst
$(BUILD)/tb_link_m1_wave/Vtb_link_m1: $(RTL_SRCS) $(SVA_SRCS) tb/directed/tb_link_m1.sv
	@mkdir -p $(BUILD)
	verilator --binary $(VFLAGS) --trace-fst --trace-structs -DTFLEX_WAVE \
	  --Mdir $(BUILD)/tb_link_m1_wave --top-module tb_link_m1 \
	  $(RTL_SRCS) $(SVA_SRCS) tb/directed/tb_link_m1.sv > $(BUILD)/tb_link_m1_wave.build.log

wave: $(BUILD)/tb_link_m1_wave/Vtb_link_m1
	@mkdir -p $(BUILD)/wave
	./$< +TEST=wave +CFG=nominal +CORE_PS=1000 +LINK_PS=500 +MEM_PS=1250 +SINK_PCT=100 +trace +verilator+seed+1
	@ls -l $(WAVE_FST)
	@echo "wave: $(WAVE_FST)"

# Netlist views (sv2v -> Yosys hierarchy/proc, no flatten -> graphviz SVG).
DIAG_TOPS := tflex_d2d_link_simplex tflex_phy_tx tflex_async_fifo
diagram:
	@mkdir -p $(BUILD)/diagram
	$(SV2V) $(RTL_PKG) $(filter-out $(RTL_PKG),$(wildcard rtl/*/*.sv)) > $(BUILD)/flat.v
	@for t in $(DIAG_TOPS); do \
	  yosys -q -p "read_verilog $(BUILD)/flat.v; hierarchy -check -top $$t; proc; show -format svg -prefix $(BUILD)/diagram/$$t $$t" || exit 1; \
	  echo "diagram: $(BUILD)/diagram/$$t.svg"; \
	done

simulate experiment plots synth:
	@echo "make $@: not implemented yet - see docs/plan.md for the milestone that adds it"; exit 2

clean:
	rm -rf $(BUILD) obj_dir sim_build results.xml
