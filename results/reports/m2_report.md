# Milestone 2 Report — CRC, Retry, Flow Control, Minimal Fault Injection

**Date:** 2026-10-19 · **Status:** complete, awaiting approval for Milestone 3.
All numbers below are **SIMULATED** (Verilator 5.020 RTL simulation of this repository) unless labeled **ANALYTICAL** or **ESTIMATED**. They describe this RTL at the stated clock periods; they are not silicon or timing claims.
*T-FLEX is a UCIe-inspired research architecture, not a UCIe implementation.*

Reproduce: `make check-env && make lint && make test`. From a clean tree on the WSL2 machine of m1_report.md §6: `make lint` PASS in 42.77 s, `make test` 129.69 s including all builds (pytest 21 passed, M1 60/60, M2 101/101, `tb_pkg_sizes` PASS). Raw results: `results/reports/m2_test_summary.txt`, `results/raw/m2/m2_results.csv`.

## 1. What was implemented

```
clk_link: TX FIFO -> retry_tx (seq, CRC, replay buffer, credits) -> phy_tx -> channel [fault injector -> 8-cycle delay] -> phy_rx -> retry_rx (CRC check, seq check)
            ^ ACK / NAK / CREDIT                                                                                  |  ACK, NAK requests
            sideband (8 cycles) <- sb_mux (NAK > ACK > CREDIT) <- credit_return <- RX FIFO read pointer <---------+
```

| File | Purpose |
|---|---|
| `python/tflex/protocol/{crc,packet}.py` | golden CRC-16 and flit/header/packet/payload model (moved here from M1, plan.md) |
| `rtl/common/tflex_crc.sv` | combinational CRC, any width/polynomial; AND/XOR form so Yosys elaborates it quickly |
| `rtl/adapter/tflex_retry_tx.sv` | replaces `tflex_adapter_tx`: sequence numbers, CRC, 64-entry replay buffer, window rule, credits on first transmission only, cumulative ACK, go-back-N on NAK, MAX_RETRY escalation, replay timer |
| `rtl/adapter/tflex_retry_rx.sv` | replaces `tflex_adapter_rx`: CRC and sequence check, in-order delivery, duplicate/gap drop, coalesced ACKs, NAK with re-send timer, NAK-density escalation |
| `rtl/adapter/tflex_sb_mux.sv` | fixed-priority sideband arbiter (NAK > ACK > CREDIT; LTSM training gets port 0 in M4) |
| `rtl/adapter/tflex_credit_return.sv` | now emits held `SB_CREDIT(n)` messages (valid/ready, n ≤ 255) |
| `rtl/fault/tflex_fault_injector.sv` | decision-4 subset: `FM_BIT_FLIP`, `FM_CRC_CORRUPT`, `FM_LANE_DEAD`; 4 command slots; hosted in `tflex_d2d_channel` |
| `rtl/common/tflex_pkg.sv` | `retry_tx_stats_t`, `retry_rx_stats_t`, `sat_inc`, `sb_make` |
| `configs/default.yaml` | ACK coalescing (8 flits / 16 idle cycles), NAK re-send 64 cycles, replay timeout 256 cycles (assumed parameters) |
| `tb/assertions/tflex_retry_sva.sv`, `tflex_fault_injector_sva.sv` | bound checks (§2) |
| `tb/directed/tb_crc.sv`, `tb_fault_injector.sv`, `tb_sb_mux.sv` | unit tests |
| `tb/directed/tb_link_m1.sv` | M2 link tests added next to the M1 tests (same scoreboard) |

Design choices left open by protocol.md and now recorded there (§4.4): NAK(e) also acknowledges e − 1; an ACK during a replay skips already-acknowledged flits; MAX_RETRY fires once per stuck sequence; NAK density uses tumbling windows; `retry_tx` adds 1 link cycle, `retry_rx` 0. The fault injector's one-shot modes act on the first valid beat at or after `start_cycle`, and `FM_CRC_CORRUPT` assumes the M2 full-width identity lane map (generalized with the gearbox in M3/M4).

Retrain requests (`tx_retrain_req` from MAX_RETRY, `rx_retrain_req` from NAK density) are link outputs only; the LTSM that acts on them arrives in M4. Until then the transmitter simply keeps retrying.

## 2. Tests

| Suite | What | Runs | Result |
|---|---|---|---|
| pytest (L0) | CRC reference vectors 0x2A45 / 0xB7C3, CCITT-FALSE check value, linearity, all 1- and 2-bit errors, every burst ≤ 16 at every position, wire-efficiency table, flit counts, field positions | 21 tests | PASS |
| `tb_crc` | reference vectors; 10⁵ random vectors vs Python; all 256 single-bit errors on 16 flits (4096); 20 000 random bursts ≤ 16 bits | 3 seeds | PASS |
| `tb_fault_injector` | independent per-cycle model: exact start/end cycles, lane masks, one-shot fires once on the first valid (non-IDLE for CRC) beat, permanent and timed dead lanes, concurrent commands, corrupted-beat counter, 20 882 cycles per run | 3 seeds | PASS |
| `tb_sb_mux` | priority, exactly-once in-order delivery per port, stream rules, offered load > 1 message/cycle | 3 seeds | PASS |
| `tb_link_m1` M2 tests | 11 tests × 5 clock configurations (+ seeds 2, 3 at nominal for the random-target tests), an 8-entry-buffer build and a 20-cycle-timeout build | 68 | PASS |
| error-rate sweep (`ber`) | random single-bit errors on any transmitted flit, p ∈ {0, 0.1 %, 1 %, 5 %} per flit, nominal and equal clocks | 24 | PASS |
| M1 regression | unchanged tests on the M2 link | 60 | PASS |

M2 link tests (verification.md §3 retry and flow-control rows): `crc1` single corrupted CRC; `bitflip` ten single-bit errors on random data lanes/bits; `replay_corrupt` flit and its first replay corrupted; `nak_first` corrupt the oldest flit of the window; `nak_last` corrupt the flit that fills an 8-entry window; `window` window-limited traffic; `wrap` errors at seq 250 (replay crosses 255 → 0) and seq 0 after three laps; `maxretry` one data lane failed for 1000 cycles; `spare_dead` a failed spare lane; `nak_density` 20 independent errors among 30 single-flit packets; `bp_recover` 20 % sink between two full-rate phases; `dup` replay timer forced to fire (20-cycle timeout).

Every run checks: each packet delivered exactly once, in order, header and every payload byte correct (scoreboard); no replay-timer expiry (except `dup`); every corrupted flit counted as a CRC error (all faults used are single-lane or 16-bit bursts, which the CRC always detects); NAKs name the corrupted sequence; retrain pulses on the outputs equal the counters; with no injected fault, zero CRC errors, NAKs and replays — including in all 60 M1 runs.

Assertions bound in every run (new in M2): credits never below zero or above 64; no new flit without a credit; outstanding ≤ RETRY_DEPTH; ACK and NAK never refer to unsent flits; replay starts at the NAKed sequence; replays stay inside the window; new flits only when no replay is pending; reset state; retry_tx output stream rules; RX never delivers a bad-CRC flit; delivered sequence increments by exactly one (independent shadow counter); RX FIFO has space for every delivery; ACK/NAK/credit request stream rules; well-formed credit messages; sideband-mux grant is the highest-priority request; injector: only M2 modes, valid lane untouched, one-shots fire once on valid beats. No assertion fired in the passing regression.

### Mutation check (does the verification catch bugs?)

One bug at a time in a scratch copy of the RTL; relevant test re-run (nominal clocks unless noted).

| Mutation | Detected by |
|---|---|
| RX delivers flits with a bad CRC | `a_deliver_crc` assertion (`crc1`) |
| TX replays from e + 1 instead of e | `a_replay_start` assertion (`crc1`) |
| TX charges a credit for every replay | `a_credit_max` assertion (`bitflip`) |
| RX never re-sends a pending NAK | `nak_resends` check (`replay_corrupt`) |
| ACK frees one flit too many | `a_window` assertion (`crc1`) |
| RX delivers duplicates | `a_deliver_order` assertion (`dup`) |
| `retrain_req` never driven (MAX_RETRY) | retrain-pulse check (`maxretry`) |
| TX ignores the window rule | `a_window` assertion (`window`, 8-entry build) |
| Credit return reports 1 slot per message | throughput 12.301 GB/s < 99 % of the 13.838 GB/s bound (`bp_recover`, slowlink clocks) |
| RX accepts a sequence gap as in order | `a_deliver_order` assertion (`crc1`) |

10 of 10 detected. In the first round, three were **not** detected, and the tests were strengthened rather than the mutations dropped: duplicates never occurred in any test (added `dup`); the MAX_RETRY test checked the statistics counter, not the `retrain_req` output (now both, and the RTL derives both from one signal); `bp_recover` compared before/after but not against the analytical bound (now ≥ 99 % of the bound in both phases).

## 3. Measured results (SIMULATED)

**Retry latency** (first NAK of a sequence → delivery of that flit), constant per configuration:

| Config | link clock | single error | corrupted replay | 1000-cycle lane failure |
|---|---|---|---|---|
| nominal | 2.0 GHz | 10.5 ns | 42.5 ns | 522.5 ns |
| equal | 1.0 GHz | 21.0 ns | 85.0 ns | 1045.0 ns |
| slowlink | 0.5 GHz | 42.0 ns | 170.0 ns | 2090.0 ns |
| fastmem | 2.0 GHz | 10.5 ns | 42.5 ns | 522.5 ns |
| odd | 1.736 GHz | 12.1 ns | 49.0 ns | 601.9 ns |

In link cycles this is 21 for a single error in every configuration (NAK register, 8-cycle sideband, TX rewind, TX and PHY registers, 8-cycle channel), 85 for a corrupted replay (the 64-cycle NAK re-send plus 21), and 1045 for the lane failure. Flits replayed per single error equal the flits in flight in that loop: 9 (nominal), 21 (equal, slowlink), 11 (fastmem), 8 (odd).

**Throughput under random errors** (100 × 4 KiB writes, single-bit errors on any transmitted flit with probability p, 3 seeds; mean [min–max]):

| p per flit | equal clocks (link-limited) | replayed / new | nominal clocks (memory-limited) | replayed / new |
|---|---|---|---|---|
| 0 | 27.645 GB/s | 0 | 22.127 GB/s | 0 |
| 0.1 % | 26.996 [26.772–27.145] | 0.024 | 22.127 [22.127–22.127] | 0.009 |
| 1 % | 22.622 [22.456–22.744] | 0.222 | 22.127 [22.127–22.127] | 0.103 |
| 5 % | 12.375 [12.257–12.511] | 1.235 | 21.650 [21.591–21.724] | 0.934 |

Go-back-N costs one loop's worth of flits per error, so where the link is the bottleneck (equal clocks) throughput falls by 2.3 % at 0.1 %, 18 % at 1 % and 55 % at 5 % per-flit error rate. At nominal clocks the 2 GHz link has 2.5× headroom over the 0.8 GHz memory side, which hides retries up to 1 % and almost hides 5 %. Mean packet latency rises from 164.3 ns to 518.4 ns (equal, 5 %). One MAX_RETRY escalation occurred in the 3 nominal-clock runs at 5 % (a flit NAKed four times by chance); no other retrain request in the sweep.

**Replay-buffer depth** (`window`, 8 entries instead of 64, 40 × 4 KiB): the link sends 0.285–0.286 flits per link cycle in every configuration, i.e. 8 flits per ≈ 28 link cycles, so the measured ACK round trip at the default latencies is ≈ 28 link cycles (ESTIMATED from the simulated rate). Throughput falls to 71.4 % (nominal), 28.6 % (equal), 28.6 % (slowlink), 57.1 % (fastmem) and 80.8 % (odd) of the ANALYTICAL bound. With the default depth of 64 no window stall occurred in any run, consistent with the sizing rule in architecture.md §8; experiment X1 sweeps this.

**Lane failure** (one data lane dead for 1000 cycles during 12 × 4 KiB): 939–998 corrupted flits, all detected; 1 NAK plus 16 re-sends; one MAX_RETRY retrain request per run; no loss; throughput over the run 18.089 GB/s at nominal clocks (ANALYTICAL bound 22.141 GB/s). A failed **spare** lane (2903–2927 corrupted beats) causes no CRC error and no replay, since spares carry no data before M3.

**Back-pressure recovery:** throughput before and after a 20 % sink phase equals the ANALYTICAL bound (slowest clock × 4096 B / 148 flits) in all five configurations: 22.141, 27.676, 13.838, 27.676 and 16.979 GB/s.

**Fault-free cost of the retry layer:** the 60 M1 runs on the M2 link: 52 byte-identical to the M1 results; the other 8 (backpressure and reset tests) differ by at most 0.3 ns mean latency, 2.0 ns maximum latency and 1–2 stall cycles, with identical throughput. Cause: ACKs now take sideband slots ahead of credit messages, which occasionally delays a credit return by one cycle.

**Forced replay timeouts** (`dup`, 20-cycle timeout): 1–242 timeouts and 2–3626 duplicates per run, all dropped; no loss or reordering.

## 4. Known issues and limitations

1. **Retrain requests are not acted on yet.** Escalations are counted and output; the LTSM (M4) will quiesce, retrain and replay.
2. **`FM_CRC_CORRUPT` and the per-flit targeting in the tests assume the full-width identity lane map** (one beat = one flit). M3's gearbox and mapper change where a flit's CRC sits; the injector mode is generalized then.
3. **The NAK re-send interval must exceed the NAK → replay loop** (21 link cycles here). Its default is derived from the channel and sideband latencies; a shorter value would not lose data but would cause extra replays and could trigger MAX_RETRY early.
4. **Verilator 5.020 issues found (testbench only), recorded in verification.md §5:** (a) a `$urandom` on the right of a packed-struct member write is evaluated more than once (26 204 non-one-hot masks in 10⁵ draws in a minimal repro) — this silently turned an intended single-bit fault into none or two bits until fixed; (b) in a clocked block, `p != 0 && ($urandom ...)` drew a random number even with `p == 0`, shifting the random stimulus of other tests. Both are avoided by testbench rules now.
5. **Deterministic tests repeat exactly across seeds** (`crc1`, `bitflip` give identical numbers for seeds 1–3: one error anywhere in a sustained stream costs the same); `nak_last` and `window` are run with one seed for that reason.
6. Replay-buffer and ACK timing were measured at the default 8-cycle channel and sideband latencies only; X1 varies them.
7. Yosys elaboration of the first fault-injector version took 290 s (variable-index writes in loops); rewritten with constant-index masks it takes 5 s, and `make lint` went from 629 s to 43 s.

## 5. Next milestone (M3, not started)

32 + 4 lanes with the gearbox (32 / 16 / 8), extended and compact lane mappers, lane failure and the repair controller with a statically configured bad-lane mask (plan.md).
