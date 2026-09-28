# Milestone 1 Report — CDC + Basic Link Datapath

**Date:** 2026-09-28 · **Status:** complete, awaiting approval for Milestone 2.
All numbers below are **SIMULATED** (Verilator 5.020 RTL simulation of this repository) unless labeled **ANALYTICAL**. They describe this RTL at the stated clock periods; they are not silicon or timing claims.
*T-FLEX is a UCIe-inspired research architecture, not a UCIe implementation.*

Reproduce: `make check-env && make lint && make test` (full regression ≈ 15 s after the build on a 2-core machine). Raw results: `results/reports/m1_test_summary.txt`, `results/raw/m1/m1_results.csv`.

## 1. What was implemented

One direction of a D2D link across three clock domains:

```
clk_core : traffic_src -> packetizer -> [TX async FIFO] ->|
clk_link : adapter_tx (credits) -> phy_tx (32 lanes + 4 idle spares + valid) -> channel (8-cycle latency) -> phy_rx -> adapter_rx -> [RX async FIFO] ->|
           credit_return -> sideband pipe (8-cycle latency) -> adapter_tx
clk_mem  : depacketizer -> traffic_sink (regenerates and checks every payload byte)
```

| File | Purpose |
|---|---|
| `rtl/common/tflex_pkg.sv` | + `pkt_item_t`, `flit_body_t`, payload generator `payload_word(addr, tag, idx)`, `keep_bytes`, `has_payload`; width modes now 32/16/8 |
| `rtl/common/tflex_reset_sync.sv` | async-assert / sync-deassert reset per domain |
| `rtl/common/tflex_sync_bits.sv` | N-flop synchronizer for Gray-coded / quasi-static vectors |
| `rtl/common/tflex_delay_line.sv` | fixed-latency pipe (channel lanes, sideband) |
| `rtl/common/tflex_async_fifo.sv` | dual-clock FIFO, Gray pointers, 2-flop sync, FWFT, valid/ready, exports synchronized read pointer for credits |
| `rtl/adapter/tflex_pkt_len_check.sv` | framing/length checker shared by packetizer and depacketizer |
| `rtl/adapter/tflex_packetizer.sv` | item stream → flit bodies (HEAD / DATA / TAIL / HEAD_TAIL), zero added latency |
| `rtl/adapter/tflex_depacketizer.sv` | flit bodies → item stream, drops IDLE, flags framing errors |
| `rtl/adapter/tflex_adapter_tx.sv` | credit-gated flit transmitter (seq/CRC fields zero until M2) |
| `rtl/adapter/tflex_adapter_rx.sv` | writes flits into RX FIFO; flags credit-protocol overflow |
| `rtl/adapter/tflex_credit_return.sv` | turns RX FIFO reads (synchronized read pointer) into coalesced credit counts |
| `rtl/phy/tflex_phy_tx.sv`, `tflex_phy_rx.sv` | flit ↔ 32 logical lanes × 8 bits, identity map, spares idle |
| `rtl/link/tflex_d2d_channel.sv` | [sim] lane latency model |
| `rtl/link/tflex_sideband_channel.sv` | [sim] fixed-latency message pipe (credit counts now, `sb_msg_t` from M2) |
| `rtl/link/tflex_d2d_link_simplex.sv` | structural: FIFOs + adapter + PHY + channel + credit loop |
| `rtl/top/tflex_traffic_src.sv`, `tflex_traffic_sink.sv` | descriptor-driven packet source and checking sink |
| `tb/assertions/*.sv` | bound SVA (below) |
| `tb/directed/tb_async_fifo.sv`, `tb_link_m1.sv` | directed + seeded-random tests |
| `scripts/run_m1_tests.sh`, `Makefile` | regression matrix, `make test`, `make test-m1`, RTL lint of every top + sv2v/Yosys elaboration |

Design choices made in M1 (all within the Phase 1 spec):
- **Credits in M1.** The brief's M1 asks for backpressure; end-to-end backpressure across a pipelined channel needs credits, so the minimal credit loop was built now. It reuses the module and path planned for M2 (credit counts become `SB_CREDIT` messages then), so nothing is implemented twice.
- **Packet item stream.** The source emits header + payload words with sop/eop; the packetizer maps these to flit types and checks framing against the header length. Latency measurement uses simulation time in the testbench; the `inject_ts` header field is stamped with a core-cycle counter for later use.
- **Payload integrity without storage.** Payload bytes are `payload_word(addr, tag, idx)`; the sink regenerates and compares every byte.

## 2. Tests

| Suite | Configurations | Runs | Result |
|---|---|---|---|
| `make lint` | Verilator `-Wall` on 6 tops; sv2v → Yosys `hierarchy -check; proc` on the same tops | 12 | PASS |
| `tb_pkg_sizes` | struct sizes, width modes | 1 | PASS |
| `tb_async_fifo` (DEPTH 16) | 5 clock configs × 3 seeds | 15 | PASS |
| `tb_link_m1` | 5 clock configs × {single, burst ×3 seeds, sustained, backpressure ×3 seeds, reset} | 45 | PASS |
| **Total** | | **60 regression runs + lint + package** | **all PASS, 0 failed** |

Async FIFO tests: T1 empty after reset, T2 fill to exactly DEPTH then no further write accepted, T3 in-order drain then empty, T4 simultaneous read/write (2000 words), T5 random valid/ready on both sides (5000 words), T6 reset mid-traffic then clean restart. Clock configs (write/read period, ps): eq 1000/1000, eqphase 1000/1000 with 370 ps offset, fastw 1000/3333, fastr 3333/1000, drift 1000/1003. 114 k words written in total, every one checked in order.

Link tests: `single` (idle link, one packet at a time: header-only, 0, 1, 27, 28, 29, 56, 57, 256, 1024, 4096, 65535 B), `burst` (2 × 64 back-to-back random packets ≤ 512 B with an idle gap), `sustained` (300 × 4 KiB), `backpressure` (500 random packets ≤ 1 KiB, sink ready 30 % of cycles), `reset` (reset all domains with 200 packets in flight, check credits restored and FIFO empty, then 100 fresh packets). Clock configs (core/link/mem period, ps): nominal 1000/500/1250 (1.0/2.0/0.8 GHz), equal 1000/1000/1000, slowlink 1000/2000/1250, fastmem 1000/500/500, odd 1002/576/1630. In every run: each packet delivered exactly once, in order, header fields and every payload byte correct, zero framing/length/overflow errors.

Assertions bound in every run: true-occupancy no-overflow / no-underflow in both clock domains, write only with space, read only with data, Gray pointers change ≤ 1 bit per clock, Gray/binary consistency, reset state (from the second reset clock), valid/ready hold + data stability on FIFO ports, source output and depacketizer output, credits ≤ receiver buffer, no flit sent without a credit, no RX FIFO overflow. No assertion fired in the passing regression.

### Mutation check (does the verification catch bugs?)

Bugs were injected one at a time into a scratch copy of the RTL and the relevant test re-run:

| Mutation | Detected by |
|---|---|
| FIFO ignores full | `a_push_space` assertion |
| FIFO synchronizes the binary (not Gray) write pointer | `a_wgray_1bit` assertion |
| Adapter ignores credits | `a_credit_send` assertion |
| One payload bit flipped in the PHY | sink payload check |
| Packetizer never emits TAIL | depacketizer framing error |
| Credit return drops single-slot returns (credit leak) | deadlock → test timeout |
| One bit flipped in the flit's CRC field | **not detected** — expected: there is no CRC until M2 |
| Read side uses the *unsynchronized* write pointer | **not detected** — zero-delay simulation has no metastability; see Known issues |

## 3. Measured results (SIMULATED)

Sustained 4 KiB writes, payload throughput vs the ANALYTICAL bound (slowest clock × one flit per cycle × 4096 B / 148 flits):

| Config | core / link / mem | Simulated | Analytical bound | Ratio | Bottleneck |
|---|---|---|---|---|---|
| nominal | 1.0 / 2.0 / 0.8 GHz | 22.136 GB/s | 22.141 GB/s | 99.98 % | mem clock |
| equal | 1.0 / 1.0 / 1.0 GHz | 27.666 GB/s | 27.676 GB/s | 99.97 % | all equal |
| slowlink | 1.0 / 0.5 / 0.8 GHz | 13.833 GB/s | 13.838 GB/s | 99.97 % | link clock |
| fastmem | 1.0 / 2.0 / 2.0 GHz | 27.670 GB/s | 27.676 GB/s | 99.98 % | core clock |
| odd | 0.998 / 1.736 / 0.613 GHz | 16.976 GB/s | 16.979 GB/s | 99.98 % | mem clock |

Interpretation: with 64-flit FIFOs and the default 8-cycle channel and sideband latencies, the CDC FIFOs and the credit loop add no measurable throughput loss; the slowest clock domain sets the rate. The remaining 0.02–0.03 % is the pipeline fill at the start of the measurement window. Where the link is faster than the consumer (nominal, odd), the transmitter runs out of credits (66 k and 81 k stall cycles) — the intended backpressure behaviour.

Idle-link packet latency (descriptor accepted at the source → packet completed at the sink), nominal clocks:

| Payload | Latency |
|---|---|
| header-only / 0 B | 11.9–12.2 ns |
| 1–28 B | 13.9 ns |
| 29–57 B | 14.4–15.9 ns |
| 256 B | 25.2 ns |
| 1024 B | 58.2 ns |
| 4096 B | 195.7 ns |
| 65535 B (maximum length, 2342 flits) | 2938.7 ns |

The minimum (~12 ns) is the fixed pipeline: FIFO synchronizers on both crossings, adapter, PHY registers and the 8-cycle channel. Large packets are dominated by serialization at the slowest domain (4096 B = 148 flits at 0.8 GHz = 185 ns). The 65535-byte packet confirms the full 16-bit length range end to end. Worst latencies in the other tests across all configs: burst 233 ns, reset-restart 262 ns, backpressure (30 % sink duty) 1023 ns.

## 4. Known issues and limitations

1. **Missing synchronizers are invisible to simulation.** The mutation that bypassed the read-side synchronizer passed every test: zero-delay 2-state simulation cannot show metastability. Mitigation plan: a structural CDC check (script that verifies every cross-domain signal goes through `tflex_sync_bits` or `tflex_async_fifo`) — proposed for M4 with the CDC stress work.
2. **Reset of one domain only is not supported** by the async FIFO (documented in the module header); all tests reset every domain together.
3. **Verilator 5.020 issues found and worked around (testbench only):** (a) a delay written as `#(int_var / 2)` generates C++ that does not compile (`VL_SHIFTR_QII` undeclared) — clocks use 64-bit half-period variables; (b) a reset held low from time 0 has no edge, so async-reset flops and assertion samples disagree at the first clock — testbenches now start with reset high and pull it low at t = 1 ps, and reset-state assertions are checked from the second clock of a reset.
4. **Clock periods are even numbers of picoseconds** (the testbench toggles every period/2).
5. Seq, flags and CRC fields are transmitted as zero until M2; spare lanes carry zeros until M3/M4.

## 5. Next milestone (M2, not started)

CRC-16 generation/check, sequence numbers, go-back-N retry with the replay buffer, `sb_msg_t` sideband (ACK/NAK/credits), minimal fault injector (CRC corruption, single-bit corruption, selected lane failure); measurements: packet latency, retry count, throughput, error-recovery latency, dropped/duplicated packets.
