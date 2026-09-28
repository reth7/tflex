# RTL ↔ Python Co-simulation Interface

**Status:** Phase 1 draft.

---

## 1. Structure

```
 Python orchestrator (python/tflex/cosim)          C++ harness (sim/harness) + Verilated tflex_system_top
 ────────────────────────────────────────          ───────────────────────────────────────────────────────
 workload engine ─┐                                 clock generator: clk_core, clk_mem, clk_link_{S,A,B}
 power model      ├─ one exchange per epoch  ◄────►   (event-driven, per-clock period changeable at epoch edges)
 thermal model    │  JSON lines on the harness's      CSR bus master (frontdoor control writes)
 controller       │  stdin / stdout                   descriptor port driver, completion port monitor
 fault model     ─┘                                   epoch snapshot + backdoor read of shadow counters
```

Why this design:

- **Lockstep over a pipe, not in-process co-simulation.** The harness runs one epoch, prints one status line, blocks on one control line. No shared memory, no threads, and the same protocol replays from files (open-loop mode) for CI and debugging. This is the "clean file/IPC interface" the brief asks for.
- **C++ harness rather than cocotb for long runs.** Five clocks with runtime-changeable periods and millions of cycles per experiment are much faster when driven from C++. cocotb is still used for module-level tests (verification.md).
- **Frontdoor control, backdoor observation.** Control writes go over the real APB-lite CSR bus (so that path is exercised and tested). At an epoch boundary the harness triggers the snapshot through the CSR bus and then reads the shadow registers through Verilator public signals, which costs no simulated time. The frontdoor read path is tested separately to show it returns the same values.

## 2. Session protocol (JSON Lines, schema version 1)

Every message is one JSON object on one line with a `type` field.

1. harness → `{"type":"hello","schema":1,"top":"tflex_system_top","links":["S","A","B"],"phys_lanes":36,"build":{"git":"<sha>","verilator":"5.020"}}`
2. Python → `{"type":"config","seed":1,"epoch_ns":10000,"clocks_mhz":{"core":1000,"mem":800,"S":2000,"A":2000,"B":2000},"rtl_seeds":{...},"skew":{...}}`
3. Repeat for `n = 0, 1, …`:
   - harness runs `[n·epoch_ns, (n+1)·epoch_ns)`, snapshots, sends `{"type":"epoch","n":n,...}` (§3)
   - Python computes power → temperature → decisions, sends `{"type":"control","n":n+1,...}` (§4) or `{"type":"stop"}`
4. harness → `{"type":"bye","epochs":N,"sim_time_ps":...,"wall_s":...}` and exits 0.

Errors: an RTL assertion failure, `$fatal`, or malformed input makes the harness emit `{"type":"error","epoch":n,"msg":"..."}` and exit non-zero; the orchestrator marks the run failed and keeps the partial records. The orchestrator uses a wall-clock watchdog per epoch.

Open-loop mode: `Vtflex --control-file controls.jsonl --record epochs.jsonl` reads control messages from a file instead of stdin. A closed-loop run's `controls.jsonl` can be replayed open-loop to reproduce it bit-exactly (the RTL is deterministic given seeds and controls); this is a regression test.

## 3. Epoch record (RTL → Python)

```json
{"type":"epoch","n":42,"t_start_ps":420000000,"t_end_ps":430000000,
 "links":{"A":{"clk_mhz":2000,"ltsm":{"state":"ACTIVE","width":32,"bad_mask":"0x000002000","perm_bad_mask":"0x0",
                "spares_left":3,"retrains":{"CRC_BURST":1},"cycles_not_active":1840,"last_repair_cycles":1712},
               "dir":{"ai2mem":{"flits_new":18011,"flits_replayed":12,"flits_idle_pad":0,"payload_bytes":438900,
                                "beats_valid":18023,"stall_no_credit":0,"stall_window_full":0,"replay_events":1,
                                "crc_errors":1,"seq_gaps":0,"duplicates":0,"naks":1,"acks":2252},
                      "mem2ai":{"...":"same fields"}},
               "sensor_c":71.8,"hw_trip_events":0}},
 "accel":{"desc_issued":120,"desc_completed":118,"rd_bytes":245760,"wr_bytes":196608,"outstanding":9,
          "latency_ns":{"sum":..., "max":..., "hist_log2":[...]},"sig_errors":0,"route_count":{"S":40,"A":60,"B":20}},
 "mem":{"sram":{"reads":20,"writes":20,"sig_errors":0},"hbm":{"reads":40,"writes":40,"sig_errors":0,"bank_stalls":13}},
 "events":[{"t_ps":423100000,"link":"A","kind":"retrain","reason":"CRC_BURST"}]}
```

(The values above only illustrate the shape; they are not results.) The fields cover everything the brief lists: timestamp, active lanes (width, masks), TX/RX flits, packets, retries, CRC errors, lane failures, link frequency, lane width and routing decisions.

## 4. Control record (Python → RTL)

```json
{"type":"control","n":43,
 "links":{"A":{"freq_mhz":1500,"width":24,"inj_level":1,"emergency":false,"sensor_c":72.4,
               "faults":[{"dir":"ai2mem","mode":"LANE_DEAD","lanes":[13],"at_ns":2500,"duration_ns":0}]}},
 "route":{"mode":"weighted","weight_A":0.30},
 "descriptors":[{"t_rel_ns":0,"src":"AI","dst":"HBM","op":"RD","len":4096,"tclass":"WEIGHT","prio":1,
                 "addr":"0x1000000","tag":7001}]}
```

Harness actions on receipt, in order: apply frequency changes (issue `RETRAIN` with `RR_FREQ_CHG` over CSR; the clock period changes when that link's LTSM reports it is in `RETRAIN` with the channel drained), write width / injection / emergency / sensor / route registers, schedule fault commands at their `at_ns` offsets, queue descriptors and push them into the accelerator's descriptor port at `t_rel_ns` (or later if the port back-pressures; the delay is recorded).

## 5. CSR register map (APB-lite, 32-bit, `clk_core`)

| Address | Register | Fields |
|---|---|---|
| `0x000` | `ID` | `0x54464C58` ("TFLX") |
| `0x004` | `VERSION` | schema / RTL version |
| `0x008` | `GCTRL` | `[0]` soft reset, `[1]` snapshot request (self-clearing) |
| `0x00C` | `GSTATUS` | `[0]` snapshot valid (all link domains acknowledged) |
| `0x100 / 0x200 / 0x300` | link S / A / B block | offsets below |
| `+0x00` | `LINK_CTRL` | `[1:0]` width request, `[3:2]` injection level, `[4]` emergency, `[5]` retrain request, `[9:6]` retrain reason, `[11:10]` frequency level (informational) |
| `+0x04` | `SENSOR_T` | `[15:0]` temperature, 8.8 fixed point °C |
| `+0x08` | `HW_TRIP_T` | `[15:0]` 8.8 fixed point °C |
| `+0x0C` | `RATE` | token-bucket rate / burst for the current injection level |
| `+0x10 … +0x20` | `FAULT_CMD[0..4]` | staging words for one `fault_cmd_t` (131 b) |
| `+0x24` | `FAULT_FIRE` | `[0]` direction, `[3:1]` injector slot, `[31]` go |
| `+0x40 …` | stats, ai→mem direction | snapshot shadow registers (protocol.md §8) |
| `+0x80 …` | stats, mem→ai direction | |
| `+0xC0 …` | LTSM status | state, width, masks, spares, retrain counters, repair cycles |
| `0x400` | `ROUTE_CTRL` | `[1:0]` mode (static / weighted), `[3:2]` static path, `[15:8]` `weight_A` (1/256 units) |
| `0x500 …` | accelerator stats | completions, bytes, latency histogram, signature errors |

Descriptors do **not** go through CSR: the accelerator has a dedicated descriptor stream port (a command queue), and a completion stream port the harness monitors.

## 6. Workload trace format (Milestone 7)

The generator writes `workload.csv` (one row per data movement) and `phases.csv`:

| Column | Meaning |
|---|---|
| `id` | movement id (becomes the tag) |
| `phase` | phase id |
| `release_ns` | earliest issue time relative to phase start |
| `src`, `dst` | `AI`, `SRAM`, `HBM` |
| `op` | `RD` or `WR` from the accelerator's point of view |
| `bytes`, `addr` | transfer size and address |
| `tclass`, `prio` | `WEIGHT, ACTIVATION, KV_CACHE, PARTIAL`; 0–3 |

`phases.csv`: `phase, deps (;-separated), compute_ops, kind` — the workload engine releases a phase's movements when its dependencies are complete and turns delivered bytes into compute progress (architecture.md §7). Generators: `matmul` (tiled GEMM, sustained weight + activation streaming), `conv` (sliding-window reuse, smaller bursts), `attention` (Q·Kᵀ / softmax / ·V phases with KV-cache bursts to SRAM), `weight_load` (large sequential reads), `activation_move` (layer-to-layer writes/reads). Intensity is a scale factor on bytes per phase and on arithmetic intensity.

## 7. Reproducibility of a run

Each run directory contains `config_resolved.yaml` (after inheritance and overrides, plus git SHA and tool versions), `workload.csv`, `phases.csv`, `epochs.jsonl`, `controls.jsonl`, `completions.csv`, and the Python-side `power.csv`, `thermal.csv` (every node, every epoch), `events.csv` and `summary.json`. Seeds: the master seed derives per-component seeds by hashing `(seed, component name)`: workload, fault model, RTL LFSRs (passed in `config`), lane skews.
