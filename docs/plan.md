# T-FLEX Plan: Milestones, Risks, Setup, Open Decisions

**Status:** Phase 1 — specification delivered, awaiting approval before Milestone 1.

---

## 1. Milestone plan

The brief's 12 milestones are kept in order. Four small adjustments (marked ◆) move a prerequisite earlier where a later milestone's tests would otherwise be impossible; each is explained. A milestone is complete only when its listed tests pass from a clean checkout and the report quotes the actual runs.

| M | Scope | New RTL / code | Exit tests |
|---|---|---|---|
| 1 | Basic transmission: descriptor-driven accelerator → packetizer → TX → channel → RX → SRAM model, one link, full width, no CRC/retry. ◆ **Async FIFO and reset synchronizers included** so core / link / mem run at different clocks from day one (retrofitting domains later would change every interface). | `reset_sync, sync_2ff, sync_fifo, async_fifo, packetizer, depacketizer, accel_model (directed descriptors), mem_sram_model, simple phy passthrough, d2d_channel`; Python golden packetizer; Dockerfile | packet round trips at lengths 0…65535; async FIFO random clock ratios; payload signatures match; SVA stream rules |
| 2 | CRC, retry, flow control. ◆ **Minimal fault injector (bit flip, burst, CRC corrupt)** — retry cannot be tested without errors; the full injector stays in M4. | `crc, retry_tx, retry_rx, credit_return, sb_mux, sideband_channel, fault_injector (subset)` | CRC vectors + 10⁵ random; retry matrix (verification.md §3); no loss / duplication / reordering; credit invariants; retry count, retry latency, throughput degradation measured |
| 3 | 32 + 4 lanes, gearbox, lane mapper, lane failure, repair controller. ◆ **Repair is exercised statically here** (bad mask set at link bring-up, dead lanes injected, traffic must flow around them); dynamic detection needs training, which is M4. | `gearbox_tx/rx, lane_map_tx/rx, lane_repair_ctrl` (+ `MAX_SHIFT` variants) | exhaustive ≤ 4-failure masks in Python, sampled in RTL; degraded widths; bandwidth ratio per width |
| 4 | Link training, deskew, full error injection, CDC stress. Dynamic repair: failure → NAKs → retrain → LANE_CHECK → remap → resume. ◆ **First synthesis run** of adapter + PHY so synthesizability problems surface early, not at the end. | `ltsm, prbs_gen/chk, deskew, fault_injector (all modes), cdc_handshake`; `syn/` scripts | LTSM matrix; each fault mode; repair latency measured; CDC randomized; Yosys reports |
| 5 | 2.5D topology: links S, A, B, HBM-like model, route select (static), path merge, CSR block, C++ harness with epochs and open-loop JSONL | `mem_hbm_model, route_select, path_merge, csr, system_top`; `sim/harness` | all links concurrently; frontdoor vs backdoor reads agree; open-loop replay deterministic |
| 6 | 3D topology parameters, config loader with inheritance/overrides | Python config package | both topologies pass the M5 suite; resolved configs recorded |
| 7 | Python workload generator + workload engine (phases, dependencies, roofline compute progress), closed-loop protocol without thermal | `python/tflex/workload`, `python/tflex/cosim` | generator determinism; byte totals; closed-loop = open-loop replay |
| 8 | Power model | `python/tflex/power` | hand-computed epochs; energy accounting sums |
| 9 | Thermal model | `python/tflex/thermal` | validation list (thermal_model.md §4); E0 |
| 10 | Thermal feedback: controller, frequency change via retrain, width, injection, HW trip | `rtl/thermal/*`, `python/tflex/...controller` | controller behaviour tests; E3 smoke |
| 11 | Thermal-aware routing: threshold and cost policies, weighted split | `python/tflex/routing`, RTL weighted mode | routing tests; E4 smoke |
| 12 | Combined experiments, plots, synthesis reports, final report | `scripts/run_experiments.py`, `python/tflex/analysis`, `visualization` | `make experiment && make plots` reproduces all tables and figures |

Optional parallel track (needs your approval): M8 and M9 are pure Python and independent of the RTL; building them alongside M2–M4 would de-risk the thermal assumptions (E0) early. By default they wait for their turn.

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
| Yosys | 0.33 | apt | native SV frontend **rejected** a package function with initialized locals; via sv2v it synthesized (713 cells for a CRC test module) |
| sv2v | 0.0.13 | GitHub release binary → `.tools/` | converted the package + test module |
| Icarus Verilog | apt | apt | installed; secondary smoke simulator only |
| cocotb | 1.9.2 | pip | one cocotb test on Verilator 5.020 passed |
| numpy / scipy / pandas / matplotlib / networkx / PyYAML / pytest | 2.4.4 / 1.17.1 / 3.0.2 / 3.10.9 / 3.6.1 / 6.0.3 / 9.1.1 | pip, pinned in `requirements.txt` | imported |
| Liberty files | Nangate45 typical, sky130hd tt | `scripts/fetch_liberty.sh` (OpenROAD-flow-scripts repo) | URL reachable; not downloaded yet |
| OpenSTA / OpenROAD | — | not in apt; optional source build later | not installed; synthesis numbers will be labeled pre-layout |

Commands: `./scripts/setup_env.sh` (apt, sv2v, venv — ran successfully in 42 s here), then `make check-env`, `make lint`, `make test`. A pinned `Dockerfile` (ubuntu:24.04) is planned in M1 for machines other than this one; macOS via Homebrew would bring a newer Verilator and is untested.

## 5. Decisions requested before Milestone 1

1. **Time scaling:** K = 100 (1 ms of physical time per 10 µs RTL epoch) with steady-state warm start — or would you prefer an additional calibrated fast Python link model for long sweeps?
2. **Compute coupling:** accept the roofline coupling of compute power to delivered bandwidth (architecture.md §7)?
3. **Thermal granularity:** 4 × 4 tiles per die by default, with the brief's 5-node lumped model kept as a mode?
4. **Milestone adjustments ◆:** async FIFO in M1, minimal injector in M2, static repair in M3 / dynamic in M4, first synthesis in M4?
5. **24-lane mode:** keep it via the gearbox with IDLE padding, or use UCIe-like halving only (32/16/8)?
6. **Lane mapper default:** `MAX_SHIFT = 28` (degraded widths supported) with `MAX_SHIFT = 4` synthesized for comparison?
7. **Parallel Python track** for M8/M9?
