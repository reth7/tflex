# T-FLEX Power, Thermal, Fault and Control Models

**Status:** Phase 1 draft. All numbers in this document are **assumed parameters** or **back-of-envelope estimates** derived from them; none are simulation or measurement results. The power model is an *architectural* model, not signoff-level power analysis; the thermal model is a *compact RC* model, not a finite-element solution.

---

## 1. Why the modeling choices below matter (back-of-envelope)

Using the default placeholders in `configs/`:

| Quantity | Estimate | How |
|---|---|---|
| One link direction at full rate, 2.5D | ≈ 0.33 W | 32 lanes × 16 Gb/s × 0.5 pJ/b + 36 × 2 mW static |
| One link direction at full rate, 3D | ≈ 0.15 W | same with 0.15 pJ/b |
| All six link directions, 2.5D | ≈ 2 W | |
| AI die at full compute | ≈ 68 W | 8 W static + 60 W compute |
| Hottest AI tile (compute share) | ≈ 6.6 W | 60 W × 1.8 / 17.6 + 8 W / 16 |
| Die tile thermal time constant | ≈ 6 ms | TIM tile R (2.0 K/W) × Si tile C (3.1 mJ/K) |
| Heatsink time constant | ≈ 30 s | 0.2 K/W × 150 J/K |

Three design consequences follow, and the architecture is built around them:

1. **Link power is a few percent of the AI die's power.** Throttling the link can only cool the die meaningfully if it also slows compute. Hence the roofline coupling in architecture.md §7: less bandwidth → compute stalls → less compute power. Without it, throttling results would be artifacts.
2. **A lumped per-die model cannot show any routing effect.** If each die is one node, moving traffic from link A to link B moves power within the same node. Hence a per-die tile grid (default 4 × 4) with each PHY placed on a tile. Even then, a PHY tile carries ≈ 0.3 W against ≈ 6.6 W of compute in the hottest tile, so **the expected peak-temperature benefit of thermal-aware routing is small** (order 1 °C or less, to be measured). Reporting that honestly, including the latency/energy price paid for it, is a legitimate RQ3 answer.
3. **RTL cannot simulate thermal time scales.** 1 s of physical time is 2 × 10⁹ link cycles. Hence epoch time scaling (§6) and a warm start at steady state.

## 2. Thermal network

The package is discretized into nodes `i = 1 … N`, each with heat capacity `Cᵢ` and power input `Pᵢ(t)`. Nodes are connected by thermal conductances `gᵢⱼ = 1/Rᵢⱼ`; some nodes also connect to ambient with `gᵢ,amb`. Energy balance for node `i`:

```
Cᵢ dTᵢ/dt = Pᵢ − Σⱼ gᵢⱼ (Tᵢ − Tⱼ) − gᵢ,amb (Tᵢ − T_amb)
```

In matrix form, with `C = diag(Cᵢ)`, conductance Laplacian `L` (`Lᵢᵢ = Σⱼ gᵢⱼ`, `Lᵢⱼ = −gᵢⱼ`) and `G = L + diag(gᵢ,amb)`:

```
C dT/dt = −G T + P + g_amb T_amb
```

For a single node this reduces to the brief's `C dT/dt = P − (T − T_amb)/R`. Steady state: `G T_ss = P + g_amb T_amb`.

### 2.1 Nodes

| Resolution | Nodes | Use |
|---|---|---|
| Lumped (`tiles_per_die: [1, 1]`) | `T_AI, T_SRAM, T_HBM, T_BASE` (3D) + `T_INTERPOSER` (2.5D) + `T_LID, T_HEATSINK` + board/package node | exactly the brief's node set; used for validation and as the coarse baseline |
| Tiled (default `[4, 4]`) | every die, interposer and lid split into rectangular tiles; lateral conductances between neighbours in a layer, vertical conductances between overlapping tiles of adjacent layers | per-PHY temperatures, hotspots, gradients, routing studies |

### 2.2 Deriving R and C from geometry

Each tile is a slab with area `A`, thickness `t`, conductivity `k`, volumetric heat capacity `c_v`:

- capacity `C = c_v · A · t`
- vertical resistance between the centres of two stacked tiles = `t₁/(2k₁A_o) + t_iface/(k_iface A_o) + t₂/(2k₂A_o)` using the overlap area `A_o` and any interface layer (TIM, microbumps/underfill, hybrid bond) in series
- lateral resistance between side-by-side tiles in one layer (pitch `d`, shared edge length `w`) = `d / (k · w · t)`
- heatsink: one node, `R_hs` to ambient, `C_hs`; lid tiles connect to it through their area share
- secondary path: bottom of the stack (base die / interposer C4 layer) → one lumped `secondary_path_r_k_w` to ambient

Material properties (bulk, temperature-independent, approximate textbook values; **assumed**): Si k = 130 W/m·K, c_v = 1.63 MJ/m³·K; Cu 400 W/m·K; TIM 4 W/m·K; microbump/underfill and hybrid-bond interfaces use *effective* conductivities (1.5 W/m·K default) because their real value depends on pad density, which is unknown here. The hybrid-bond conductivity is one of the parameters swept in E0 because RQ1 conclusions are expected to be sensitive to it.

### 2.3 Stacks

**2.5D** (`configs/2p5d.yaml`): heatsink ← lid (tiled, spans all dies) ← TIM1 ← {AI, SRAM, HBM-like} dies side by side ← microbumps ← Si interposer (tiled) ← C4 ← secondary path. Each die has its own TIM path to the shared lid; lateral heat flow in the lid and interposer couples the dies.

**3D** (`configs/3d.yaml`): heatsink ← lid ← TIM1 ← AI die ← hybrid bond ← memory die (SRAM + HBM-like regions) ← hybrid bond ← base die ← C4 ← secondary path. All stack power leaves through one 10 × 10 mm footprint; memory and base-die heat must pass through the AI die or take the weak secondary path. `stack_order` can put memory on top of the AI die as an ablation.

## 3. Time integration

Power is piecewise-constant over an epoch (zero-order hold), so the exact discrete-time solution is used:

```
T[n+1] = Φ T[n] + Γ (P[n] + g_amb T_amb),   Φ = exp(−C⁻¹G Δt),   Γ = G⁻¹ (I − Φ)
```

`Φ` and `Γ` are computed once per `Δt` with `scipy.linalg.expm` (N ≈ 150 nodes at 4 × 4 tiles, so dense matrices are cheap) and cached per frequency of recomputation. This is exact for any `Δt` and unconditionally stable, which matters because the system is stiff (tile τ ≈ ms, heatsink τ ≈ 30 s). Backward Euler, `(C/Δt + G) T[n+1] = C/Δt T[n] + P + g_amb T_amb` with a sparse LU factorization, is kept as a cross-check and for larger grids.

## 4. Validation plan (Milestone 9, pytest, all automated)

1. Single node: step response equals `T_amb + PR(1 − e^{−t/RC})` to 1e-9 relative.
2. Two nodes: compare with the closed-form two-exponential solution.
3. Steady state of the transient solver equals `G⁻¹(P + g_amb T_amb)`.
4. Energy balance per step: `ΔE_stored + E_to_ambient = E_in` within numerical tolerance.
5. Symmetry: a symmetric floorplan with symmetric power gives symmetric temperatures.
6. Grid convergence: peak temperature for 1×1, 2×2, 4×4, 8×8 tiles; the default grid is justified by the change from 4×4 to 8×8.
7. ZOH vs backward Euler agree as `Δt → 0`.
8. Optional external cross-check against HotSpot (not a dependency; documented if done).

## 5. Power model (Milestone 8)

Computed per epoch from the RTL counters (cosim_interface.md §3) and the workload engine's compute utilization. Each component's power is deposited on the tiles it occupies.

| Component | Model | Placement |
|---|---|---|
| AI compute | `P_static + P_compute_peak · u_compute`, `u_compute` from the roofline coupling; optional leakage–temperature term `P_static · (1 + α (T − T_ref))` (off by default) | AI tiles, weighted by `ai_power_map` |
| D2D PHY (per direction) | `N_powered_lanes · P_lane_static · (f/f_max) + E_bit · bits_on_wire / t_epoch`; the energy is split 50/50 between the TX and RX ends (assumed) | PHY tile of each end |
| Adapter (per endpoint) | `P_static + E_flit · (flits_new + flits_replayed) / t_epoch` | PHY tile |
| SRAM | `P_static + E_byte · bytes / t_epoch` | SRAM die / region |
| HBM-like | `P_static + E_bit · bits / t_epoch` | HBM die / region |
| Base die (3D) | `P_static` | base die |

`bits_on_wire` counts everything the PHY transmits in ACTIVE (including replays, IDLE pads and headers) plus PRBS during training, so retries and retraining cost energy. With `freq_voltage_scaling: true`, dynamic terms scale with `(V/V₀)²` using a linear V(f) table (assumed). A second mode, `activity_calibrated`, may later scale adapter/PHY energy using Verilator toggle counts × Yosys cell counts; it is optional and would still be labeled "modeled".

Every energy/power default is a placeholder (`source: placeholder` in the YAML). Before results are written up, each will either be replaced by a value from a cited publication (recorded in the YAML `source` field) or remain explicitly labeled as an assumed parameter.

Derived efficiency metrics: energy/bit = link+adapter energy / payload bits delivered (and a system-level variant including memories and compute); energy/packet; payload throughput per watt.

## 6. Epoch time scaling

One epoch = `epoch_ns` of RTL time (10 µs). The thermal model advances `Δt = K · epoch_ns` of physical time per epoch (`K = time_scale_k`, default 100 → 1 ms). Assumption: the traffic mix and rates measured in the RTL epoch are representative of the whole scaled interval. Implications and checks:

- Δt = 1 ms is well below the ≈ 6 ms die-tile time constant, so on-die transients are resolved.
- The controller acts once per epoch = every 1 ms of physical time, a plausible order for dynamic thermal management loops (assumption).
- Retrain penalties are measured in RTL time; a retrain that costs 1 µs of a 10 µs epoch therefore stands for 10 % of the scaled millisecond. This **overstates** the relative cost of each retrain by the factor K. This is conservative for throttling (it penalizes actuation) and is stated with every throttling result; X2 quantifies it by sweeping K.
- Initial condition: `T_ss` for the workload's mean power (from a short open-loop calibration run), so the 30-s heatsink transient is not simulated.

## 7. Temperature sensors

Each link has a sensor = temperature of its PHY tile on the AI die (configurable: `tile_max` over the PHY and neighbouring tiles). Optional Gaussian noise σ and a one-epoch delay can be enabled for robustness tests. The same value is written to the RTL sensor register for the hardware trip.

## 8. Thermal controller (Milestone 10)

Per link, evaluated once per epoch:

| Sensor temperature | Action (default order `[frequency, width, injection]`) |
|---|---|
| `T < T1 − H` | step back toward full performance (one level per dwell period) |
| `T1 ≤ T < T2` | reduce link frequency one level (2000 → 1500 → 1000 → 500 MHz) |
| `T2 ≤ T < T3` | reduce width one mode (32 → 24 → 16 → 8) |
| `T ≥ T3` | emergency: injection gated to the lowest level |
| `T ≥ hw_trip` | RTL comparator gates injection within the epoch, independent of the policy |

Hysteresis `H = 3 °C` and `min_dwell_epochs = 5` prevent chattering. T1/T2/T3 = 70/85/95 °C are experiment parameters, not hardware limits. The action order is an ablation in E3. A compute-DVFS policy (scaling the AI compute clock instead of the link) is available as an extra baseline because in real systems it is usually the dominant thermal knob; including it keeps the link-throttling results in perspective.

## 9. Routing policies (Milestone 11)

For HBM-bound traffic with paths A and B:

- **static:** always `static_path`.
- **threshold:** use A unless `T_A ≥ threshold_c`, then B (with the controller's hysteresis).
- **cost:** per epoch, for each path `p`:
  `cost_p = α · lat_p/lat_norm + β · util_p + γ · T_p/T_norm + δ · fault_p`
  where `lat_p` is the measured mean packet latency on `p` over the last epoch (the configured latency if unused), `util_p` the fraction of link capacity used, `T_p` the path's PHY temperature, and `fault_p` the probability of a lane fault on `p` during the next epoch from the fault model (or the observed NAK rate when the thermal fault model is off). `winner_take_all` programs the lowest-cost path; `weighted` programs `weight_A = σ((cost_B − cost_A)/τ)`.

Normalization constants are configuration values, so α … δ are comparable. Comparisons against static routing report peak and mean temperature, throughput, latency (mean, p99) and energy/bit.

## 10. Thermal–fault model (hypothetical, for "what if" studies only)

Per physical lane and epoch, a permanent-failure event is drawn with probability `1 − exp(−λ(T) Δt)`, using an Arrhenius-shaped hazard

```
λ(T) = λ_ref · exp( (E_a / k_B) · (1/T_ref − 1/T) )     (T in kelvin)
```

and transient bit errors use `BER(T) = BER_ref · 10^{(T − T_ref)/ΔT_dec}`. `λ_ref` is deliberately inflated (1e-3 per second per lane at 60 °C by default) so that faults occur within a simulated second; `E_a`, `BER_ref` and `ΔT_dec` are placeholders. **This function does not represent measured semiconductor or interconnect reliability** and all results using it are labeled as "under the hypothetical thermal fault model". Each lane draws from the same pre-generated uniform random stream (seeded from the run seed) under every policy being compared — common random numbers — so differences in fault counts between policies come from their temperature differences, not from RNG luck, and comparisons can be paired.
