# T-FLEX Verification Strategy

**Status:** Phase 1 draft. Only `tb/directed/tb_pkg_sizes.sv` exists and passes today.

---

## 1. Principles

- **Every module gets a test before the next milestone starts.** A milestone is done when its regression passes from a clean checkout with `make test`, and the report lists the commands and results actually run.
- **One golden model, used twice.** Python reference models (CRC, packetizer, gearbox, lane mapping, retry protocol at transaction level, thermal RC solutions) are the scoreboards for cocotb tests *and* the building blocks of the analysis code, so hardware and model cannot silently disagree.
- **Assertions live next to the design** (`tb/assertions/*_sva.sv`, attached with `bind`) so they run in every test that instantiates the module, including system and closed-loop runs.
- **Faults are first-class stimulus.** The fault injector is part of the RTL, so every fault scenario is also usable in system tests and experiments.

## 2. Test layers

| Layer | Location | Tool | Checks |
|---|---|---|---|
| L0 Python models | `python/tests/` | pytest | golden models against hand-computed vectors and analytic results |
| L1 directed module tests | `tb/directed/` | Verilator `--binary --timing --assert` | reset behaviour, corner cases, protocol sequences written by hand |
| L2 random module tests | `tb/cocotb/`, `tb/random/` | cocotb 1.9 + Verilator; SV constrained-random where simpler | seeded random stimulus, back-pressure, scoreboard vs golden model |
| L3 system tests | `tb/cocotb/system/`, `sim/harness` | Verilator + C++ harness | end-to-end traffic on all links, faults, retrains, clock ratios |
| L4 closed loop | `python/tests/test_cosim_*.py` | harness + orchestrator | protocol, determinism (replay open-loop = closed-loop), controller behaviour |
| Formal (optional) | `tb/formal/` | SymbiYosys if installed | async FIFO, lane-map uniqueness, retry window invariants |

## 3. Test matrix

| Area | Tests (all seeded; random tests run ≥ 20 seeds in regression) | Milestone |
|---|---|---|
| Packet / flit | header pack/unpack round trip; lengths 0, 1, 27, 28, 29, 4096, 65535; flit counts match protocol.md §3; TAIL placement; payload signature | M1 |
| Async FIFO | full/empty at all fill levels; simultaneous push/pop; clock ratios 1:1, 1:2.5, 3:1 and randomized periods with jitter; reset in either domain; overflow/underflow attempts blocked | M1 (primitive), M4 (system CDC) |
| CRC | reference vectors; 10⁵ random flits vs Python; all single-bit errors detected; random bursts ≤ 16 detected | M2 |
| Retry | single corrupted flit; corrupted replay; NAK of first/last flit in window; seq wrap-around beyond 256; window full; MAX_RETRY escalation; replay timer never fires fault-free; no loss, no duplicate, in-order delivery (scoreboard) | M2 |
| Flow control | credits never negative; RX FIFO never overflows with slow consumer; throughput recovers after back-pressure | M2 |
| Gearbox | every width, every flit count 1–8, pause/resume patterns; IDLE pad count at W = 24; bandwidth ratio W/32 at saturation | M3 |
| Lane mapping / repair | exhaustive bad masks with ≤ 4 failures (for 36 lanes: Σ C(36,k), k ≤ 4 ≈ 67 k masks, run in the Python model and sampled in RTL); map uniqueness and monotonicity; spares count; degraded widths with 5–28 failures; `MAX_SHIFT = S` rejects what it cannot map | M3 |
| Link training | clean training; dead lane found in LANE_CHECK; stuck-at-0/1; skew 0…MAX_SKEW per lane; skew beyond MAX_SKEW → ERROR; partner retrain request; LINK_DOWN and periodic recovery; ACTIVE never entered early | M4 |
| Fault injection | each `fault_mode_e`, start/duration timing exact, multiple simultaneous commands | M4 |
| Topologies | 2.5D and 3D parameter sets; all three links concurrently; responses return on the request path | M5, M6 |
| Workload | generator determinism per seed; byte totals per phase; dependency ordering respected | M7 |
| Power / thermal | thermal_model.md §4 validation list; power from counters by hand for a synthetic epoch | M8, M9 |
| Thermal feedback | controller steps down at thresholds and back with hysteresis; dwell respected; HW trip acts within the epoch; no oscillation under a constant load; retrain on frequency change | M10 |
| Routing | static; threshold switches at packet boundaries only; weighted split converges to the programmed ratio; responses on request path | M11 |
| Stress | maximum injection on all links; simultaneous lane faults on A and B; burst traffic with repeated throttling; 10⁷-cycle soak with random BER; zero `sig_errors` unless CRC escapes are being provoked | M12 |

## 4. Assertions (planned SVA, bound per module)

| Module | Property |
|---|---|
| all streams | `valid && !ready |=> valid && $stable(data)` (no drop, no change while stalled) |
| `tflex_async_fifo` | no write when full, no read when empty; Gray pointers change by exactly one bit per update; after reset both pointers zero |
| `tflex_retry_tx` | `next_seq − oldest_unacked ≤ RETRY_DEPTH`; ACK never acknowledges an unsent seq; replay starts at the NAKed seq; credits never below zero or above the initial value |
| `tflex_retry_rx` | delivered sequence strictly increments by one; never delivers a bad-CRC flit; RX FIFO has space whenever a sequenced flit is accepted |
| `tflex_lane_map_*` | active map strictly increasing (so no duplicate physical lane); no mapped lane is in the bad mask; count of active lanes equals width; map stable while ACTIVE |
| `tflex_ltsm` | ACTIVE only from DESKEW with deskew done and map committed; no TX FIFO pop outside ACTIVE; RETRAIN leaves only after drain; state encoding always legal |
| `tflex_gearbox_*` | bytes out = bytes in (conservation) across any window ending at a flit boundary; IDLE pads only at W = 24 |
| `tflex_depacketizer` | DATA/TAIL never without a preceding HEAD; length consistent with flit count |
| `tflex_accel_model` | outstanding reads ≤ `MAX_OUTSTANDING`; every tag completes at most once |
| end to end | per (src, dst, path) packet order preserved; zero `sig_errors` when no CRC-escape stimulus is injected |

Cover properties record that interesting states happened (each retrain reason, each width mode, replay with wrap-around, repair using the last spare, LINK_DOWN recovery).

## 5. Tool limitations and mitigations (found or known in Phase 1)

| Limitation | Mitigation |
|---|---|
| Verilator is 2-state: no X propagation, uninitialized flops read 0 or random | Every flop has an explicit reset; run the regression with `--x-initial unique` and `+verilator+rand+reset+2` over several seeds; key primitives also compiled with Icarus as a smoke check where its SV support allows |
| Verilator 5.020 supports simple concurrent SVA (`|->`, `|=>`, `$past`, `$stable`, `disable iff`), not the full sequence language | Write properties in that subset; complex temporal checks as small SV checker modules |
| No covergroups in Verilator 5.020 | `cover property` plus explicit coverage counters; functional coverage summarized by the Python side |
| No metastability in simulation | `SIM_METASTABILITY` random extra-cycle delay in `tflex_sync_2ff`; randomized clock periods and phases; structural rule: every crossing goes through the approved primitives (reviewed, and grepped in lint) |
| **Observed in the Phase 1 smoke test:** in an SV testbench, writing one member of a struct variable procedurally (`f.seq = …`) did not propagate to a DUT input port connected to that variable, while a continuous-assign-driven struct did | Testbench rule: drive DUT inputs from whole-variable assignments or continuous assigns, never partial struct member writes; cocotb tests assign whole ports |
| Yosys 0.33's native SV parser rejects some constructs used here (package functions with initialized locals) | Synthesis goes through sv2v 0.0.13 first (verified working on the Phase 1 package) |

## 6. Regression and reporting

- `make test` runs L0–L2 plus a short L3 smoke test (minutes). `make test-long` adds multi-seed random and soak tests.
- Each run writes JUnit XML (cocotb, pytest) and a text summary into `results/reports/`; milestone reports quote those files.
- Seeds are printed on failure, and every failure is reproducible with `SEED=<n> make test-<name>`.
