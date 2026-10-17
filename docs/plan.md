# T-FLEX Plan: Milestones, Risks, Setup, Open Decisions

__Status:__ Milestone 1 complete (2026-09-28), awaiting approval before Milestone 2. Report: [results/reports/m1_report.md](../results/reports/m1_report.md).

| Milestone | Status | Evidence |
|---|---|---|
| Phase 1 — specification | done | this document set |
| M1 — CDC + basic link datapath | __done__ | `make test`: 60/60 regression runs pass; m1_report.md; re-verified 2026-10-17 on WSL2, results byte-identical (m1_report.md §6) |
| M2 — CRC / retry + minimal fault injection | not started | — |

## 0. Decision log (approved by the project owner, 2026-09-28)

1. **Time scaling:** 10 µs RTL epoch = 1 ms thermal time (100×), starting from a precomputed steady state. X2 must compare at least 50× vs 100× (peak temperature, temperature evolution, throttle events, routing decisions, completion time); if conclusions change, the limitation is documented, not tuned away.
2. **Compute power** is *not* proportional to D2D bandwidth: bandwidth → data arrival → compute progress → work completed → compute activity → compute power (phase, utilization, op rate, precision, active resources, memory activity). Primary application metric: **workload completion time**, also reporting bandwidth, latency, compute stall time, retry overhead and throttling time. D2D power is never inflated to make routing look important.
3. **Thermal granularity:** 4 × 4 tiles per die by default; the 5-node lumped model stays as a baseline/reference.
4. **Milestone adjustments accepted:** async FIFO in M1, minimal injector in M2 (CRC corruption, single-bit corruption, selected lane failure), fixed-mask repair in M3, live detection/retraining + first synthesis (sv2v → Yosys) in M4.
5. **24-lane mode rejected.** Widths are 32 / 16 / 8 (UCIe-style halving); no padding flits. Documented as a rejected alternative in protocol.md §5.1.
6. __Mappers:__ the extended mapper (`MAX_SHIFT = P − W_min`) is the primary research mapper; the compact mapper (5:1 muxes, ≤ 4 failures) is also implemented. X7 compares area, timing, mux/resources, supported fault count, flexibility (and power if the flow gives it) from measured synthesis; no winner is chosen in advance.
7. **Python power/thermal models may be developed in parallel** with the RTL milestones, runnable on synthetic activity traces, and are not coupled to the RTL until the activity schema is stable.
8. **Progressive workloads:** Stage 0 — Synthetic communication traffic
    deterministic / random / bursty

Stage 1 — Synthetic compute
    weight load
    activation load
    GEMM-like compute
    output store

Stage 2 — Thermal stress workloads
    compute-heavy
    bandwidth-heavy
    bursty
    memory-bound
    compute-bound

Stage 3 — Final architectural experiments
    2.5D vs 3D
    thermal control
    thermal-aware routing
    lane faults
    frequency/width scaling

9. **Expected ~1 °C routing benefit is a hypothesis, not a target.** Whatever the simulation shows is reported.

---

## 1. Milestone plan

The brief's 12 milestones are kept in order. Four small adjustments (marked ◆) move a prerequisite earlier where a later milestone's tests would otherwise be impossible; each is explained. A milestone is complete only when its listed tests pass from a clean checkout and the report quotes the actual runs.

| M | Scope | New RTL / code | Exit tests |
|---|---|---|---|
| 1 ✔ | Basic transmission: descriptor-driven accelerator → packetizer → TX → channel → RX → SRAM model, one link, full width, no CRC/retry. ◆ __Async FIFO and reset synchronizers included__ so core / link / mem run at different clocks from day one (retrofitting domains later would change every interface). | `reset_sync, sync_2ff, sync_fifo, async_fifo, packetizer, depacketizer, accel_model (directed descriptors), mem_sram_model, simple phy passthrough, d2d_channel`; Python golden packetizer; Dockerfile | packet round trips at lengths 0…65535; async FIFO random clock ratios; payload signatures match; SVA stream rules |
| 2 | CRC, retry, flow control. ◆ __Minimal fault injector (bit flip, burst, CRC corrupt)__ — retry cannot be tested without errors; the full injector stays in M4. | `crc, retry_tx, retry_rx, credit_return, sb_mux, sideband_channel, fault_injector (subset)` | CRC vectors + 10⁵ random; retry matrix (verification.md §3); no loss / duplication / reordering; credit invariants; retry count, retry latency, throughput degradation measured |
| 3 | 32 + 4 lanes, gearbox (32/16/8), lane mapper (extended + compact), lane failure, repair controller. ◆ __Repair is exercised statically here__ (bad mask set at link bring-up, dead lanes injected, traffic must flow around them); dynamic detection needs training, which is M4. | `gearbox_tx/rx, lane_map_tx/rx, lane_repair_ctrl` (+ `MAX_SHIFT` variants) | exhaustive ≤ 4-failure masks in Python, sampled in RTL; degraded widths; bandwidth ratio per width |
| 4 | Link training, deskew, full error injection, CDC stress. Dynamic repair: failure → NAKs → retrain → LANE_CHECK → remap → resume. ◆ __First synthesis run__ of adapter + PHY so synthesizability problems surface early, not at the end. | `ltsm, prbs_gen/chk, deskew, fault_injector (all modes), cdc_handshake`; `syn/` scripts | LTSM matrix; each fault mode; repair latency measured; CDC randomized; Yosys reports |
| 5 | 2.5D topology: links S, A, B, HBM-like model, route select (static), path merge, CSR block, C++ harness with epochs and open-loop JSONL | `mem_hbm_model, route_select, path_merge, csr, system_top`; `sim/harness` | all links concurrently; frontdoor vs backdoor reads agree; open-loop replay deterministic |
| 6 | 3D topology parameters, config loader with inheritance/overrides | Python config package | both topologies pass the M5 suite; resolved configs recorded |
| 7 | Python workload generator + workload engine (phases, dependencies, roofline compute progress), closed-loop protocol without thermal | `python/tflex/workload`, `python/tflex/cosim` | generator determinism; byte totals; closed-loop = open-loop replay |
| 8 | Power model | `python/tflex/power` | hand-computed epochs; energy accounting sums |
| 9 | Thermal model | `python/tflex/thermal` | validation list (thermal_model.md §4); E0 |
| 10 | Thermal feedback: controller, frequency change via retrain, width, injection, HW trip | `rtl/thermal/*`, `python/tflex/...controller` | controller behaviour tests; E3 smoke |
| 11 | Thermal-aware routing: threshold and cost policies, weighted split | `python/tflex/routing`, RTL weighted mode | routing tests; E4 smoke |
| 12 | Combined experiments, plots, synthesis reports, final report | `scripts/run_experiments.py`, `python/tflex/analysis`, `visualization` | `make experiment && make plots` reproduces all tables and figures |

Parallel track (approved, decision 7): M8 and M9 are pure Python and may be built alongside M2–M4 against synthetic activity traces.

__M1 as delivered vs. the row above:__ traffic source/sink modules (`tflex_traffic_src/sink`) stand in for the accelerator and SRAM models, which arrive with the topologies in M5; a minimal credit loop was added so backpressure could be tested (see m1_report.md §1); the Python golden packetizer and the Dockerfile were not needed for the M1 tests and move to M2 (golden CRC/packet model) and M5 (Dockerfile) respectively.

## 2. Technical risks

| # | Risk | Likelihood / impact | Mitigation |
|---|---|---|---|
| R1 | RTL cannot reach thermal time scales (1 s = 2 × 10⁹ link cycles) | certain / high | epoch time scaling K + steady-state warm start; X2 checks sensitivity to K; retrain overstatement disclosed |
| R2 | Link power is small vs compute, so link throttling looks thermally useless | high / high | roofline compute coupling; completion time as the throughput metric; compute-DVFS reference baseline |
| R3 | Thermal-aware routing effect may be tiny | high / medium | tile-grid thermal model; report the effect size honestly with its latency/energy cost; γ sweep |
| R4 | Absolute temperatures hinge on assumed parameters | certain / medium | geometry-derived RC, E0 sensitivity sweeps, relative comparisons, cite sources where values are adopted |
| R5 | Verilator speed with 6 channels × 256-bit datapaths on a 2-core machine | medium / medium | measure cycles/s in M5; knobs: shorter epochs, fewer seeds, `-O3`, `--x-assign fast`; batch runs overnight |
| R6 | Verilator limits: 2-state, SVA subset, no covergroups, no metastability | certain / medium | verification.md §5 mitigations |
| R7 | Tool-version coupling (cocotb 2.x needs a newer Verilator; Yosys SV frontend gaps) | known / low | cocotb pinned to 1.9.2; sv2v front end; versions recorded per run |
| R8 | Milestone dependency: repair needs training | known / medium | static repair in M3, dynamic in M4 (◆) |
| R9 | Retry buffer smaller than the ACK round trip throttles throughput for long links | medium / low | sizing rule in architecture.md §8; X1 |
| R10 | Multi-path routing reorders packets | known / low | route changes only at packet boundaries; responses on the request path; per-path ordering asserted; transactions matched by tag |
| R11 | Scope: 12 milestones is a lot | medium / high | a minimum publishable cut is M1–M6 + M9 + E1/E2/E5; everything else extends it |
| R12 | Synthesis fmax far below 2 GHz in open PDKs | certain / low | architectural clock stated as such; report estimated fmax honestly; compare modules relative to each other |

## 3. Simplifications (deliberate)

Digital lane abstraction (8 bits per lane per cycle, no serializer); shared link clock per link; reliable sideband; dedicated fault-free valid lane; payloads regenerated instead of stored; HBM-like model without HBM protocol; compute modeled in Python; compact RC thermal model; event-energy power model; hypothetical thermal-fault function. Full list and consequences: limitations.md.

## 4. Dependency / setup plan

Verified in this Phase 1 environment (Ubuntu 24.04, 2 CPU cores, 7 GB RAM, Python 3.11.15):

| Component | Version | How | Phase 1 check |
|---|---|---|---|
| Verilator | 5.020 (Ubuntu package) | apt | SV package + concurrent assertion + `--binary --timing` testbench compiled and ran |
| Yosys | 0.33 | apt | native SV frontend __rejected__ a package function with initialized locals; via sv2v it synthesized (713 cells for a CRC test module) |
| sv2v | 0.0.13 | GitHub release binary → `.tools/` | converted the package + test module |
| Icarus Verilog | apt | apt | installed; secondary smoke simulator only |
| cocotb | 1.9.2 | pip | one cocotb test on Verilator 5.020 passed |
| numpy / scipy / pandas / matplotlib / networkx / PyYAML / pytest | 2.4.4 / 1.17.1 / 3.0.2 / 3.10.9 / 3.6.1 / 6.0.3 / 9.1.1 | pip, pinned in `requirements.txt` | imported |
| Liberty files | Nangate45 typical, sky130hd tt | `scripts/fetch_liberty.sh` (OpenROAD-flow-scripts repo) | URL reachable; not downloaded yet |
| OpenSTA / OpenROAD | — | not in apt; optional source build later | not installed; synthesis numbers will be labeled pre-layout |

Also verified on 2026-10-17 on Ubuntu 24.04.2 under WSL2 (16 threads, 7 GiB RAM, Python 3.12.3): same Verilator / Yosys / sv2v versions (Yosys and sv2v in `/usr/local/bin`), all pinned Python packages install on 3.12; Python 3.12 needs the `python3.12-venv` apt package for the venv. Results: m1_report.md §6.

Commands: `./scripts/setup_env.sh` (apt, sv2v, venv — ran successfully in 42 s here), then `make check-env`, `make lint`, `make test`. A pinned `Dockerfile` (ubuntu:24.04) is planned in M1 for machines other than this one; macOS via Homebrew would bring a newer Verilator and is untested.

## 5. Decisions requested before Milestone 1

All seven were answered on 2026-09-28; see §0, decision log.
