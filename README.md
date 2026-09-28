# T-FLEX

**Thermal-Aware Fault-Tolerant UCIe-Inspired Die-to-Die Interconnect for 2.5D/3D AI Chiplet Architectures**

> This project is a UCIe-inspired architectural/RTL research model and is not a certified implementation of the UCIe specification.

**Status:** Phase 1 (specification) complete and awaiting review. No RTL beyond the shared type package exists yet, and no results have been produced. Every number in the docs is an assumed parameter or an analytical estimate and is labeled as such.

## Motivation

Chiplet-based AI accelerators move enormous amounts of data across die-to-die links, and stacking dies in 3D shortens those links while making heat harder to remove. T-FLEX asks how link reliability mechanisms (CRC, retry, lane repair), thermal management (frequency, width and injection throttling) and thermal-aware routing trade off against each other, using synthesizable SystemVerilog for the interconnect and Python models for power, temperature and faults, connected in a closed loop.

## Architecture at a glance

- AI accelerator chiplet ↔ SRAM chiplet over link **S**; AI ↔ HBM-like chiplet over parallel links **A** and **B** (for routing). Each link is full duplex.
- **Adapter:** packetization, 256-bit flits, CRC-16, go-back-N retry, credit flow control, sideband ACK/NAK.
- **PHY (logical):** 32 data + 4 spare lanes, gearbox for 32/24/16/8-lane widths, compaction-based lane repair, PRBS lane testing, deskew, link-training state machine.
- **Fault injector:** bit flips, bursts, stuck-at, dead lanes, packet/CRC corruption, temporary link loss, random BER.
- **Python side:** workload generator (matmul, conv, attention, weight load, activation movement), power model, tile-level compact thermal RC model for 2.5D and 3D stacks, thermal controller, routing policies, hypothetical temperature-dependent fault model.
- **Co-simulation:** Verilator C++ harness ↔ Python orchestrator, one JSON-lines exchange per epoch.

Details: [docs/architecture.md](docs/architecture.md).

## Repository layout

```
rtl/        common/ adapter/ phy/ link/ routing/ thermal/ fault/ top/   SystemVerilog
tb/         directed/ random/ cocotb/ assertions/                      testbenches, SVA
python/     tflex/{workload,power,thermal,routing,cosim,analysis,visualization}, tests/
sim/        harness/  (Verilator C++ harness)
syn/        synthesis scripts (Yosys via sv2v)
configs/    default.yaml, 2p5d.yaml, 3d.yaml, experiments.yaml
scripts/    setup_env.sh, check_env.sh, fetch_liberty.sh, build/simulate/synthesize.sh, run_experiments.py
results/    raw/ plots/ reports/
docs/       architecture, protocol, thermal_model, cosim_interface, verification, experiments, limitations, plan
```

Deviation from the brief's layout: Python lives in an importable package (`python/tflex/…`) and `cosim/`, `sim/harness/` and `syn/` were added.

## Setup

```bash
./scripts/setup_env.sh   # apt: verilator yosys iverilog; sv2v -> .tools/; Python venv -> .venv/
make check-env
make lint                # Verilator lint + sv2v/Yosys parse
make test                # Phase 1: package layout checks
```

Reference environment: Ubuntu 24.04, Verilator 5.020, Yosys 0.33, sv2v 0.0.13, Python 3.11, cocotb 1.9.2 (pinned in `requirements.txt`).

`make simulate`, `make experiment`, `make plots` and `make synth` are placeholders until their milestones land ([docs/plan.md](docs/plan.md)).

## Documentation

| Document | Contents |
|---|---|
| [architecture.md](docs/architecture.md) | block diagram, clock domains, every RTL module and interface, lane mapping, 2.5D/3D mapping, methodology |
| [protocol.md](docs/protocol.md) | flit and packet formats, CRC, retry, credits, gearbox, repair, sideband, link training |
| [thermal_model.md](docs/thermal_model.md) | power model, RC thermal network, integration, validation, controller, routing, fault model |
| [cosim_interface.md](docs/cosim_interface.md) | RTL ↔ Python protocol, epoch/control records, CSR map, trace formats |
| [verification.md](docs/verification.md) | test layers, test matrix, assertions, tool limitations |
| [experiments.md](docs/experiments.md) | research questions, experiments E0–E6, metrics, plots, pre-registered expectations |
| [limitations.md](docs/limitations.md) | what is and is not modeled |
| [plan.md](docs/plan.md) | milestones, risks, setup, open decisions |

## Research questions

RQ1 3D vs 2.5D thermals · RQ2 throughput cost of throttling · RQ3 thermal-aware routing · RQ4 bandwidth after lane failures · RQ5 redundancy needed · RQ6 thermal/reliability/performance tradeoff · RQ7 workload dependence. Mapping to experiments: [docs/experiments.md](docs/experiments.md).

## Research integrity

Results are labeled `simulated`, `modeled`, `estimated` or `assumed parameter`. Nothing is reported that was not produced by running code in this repository.
