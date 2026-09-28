# T-FLEX Limitations and Scope

**This project is a UCIe-inspired architectural/RTL research model and is not a certified implementation of the UCIe specification.** No compliance, interoperability or silicon claims are made.

## 1. Real UCIe vs. this model

| Topic | UCIe (general concepts) | T-FLEX |
|---|---|---|
| Layering | protocol layer, die-to-die adapter, physical layer | same split in spirit; no protocol layer mapping (no PCIe/CXL/streaming) |
| Flit formats, CRC polynomial, retry encoding | defined by the specification | **our own** 256-bit flit, CRC-16/CCITT (configurable), go-back-N over a sideband |
| Sideband | defined messages and wires | abstract reliable message channel with fixed latency; its own errors are out of scope |
| PHY | analog transmitters/receivers, clocking, valid/track lanes, electrical specs | **digital behavioural abstraction**: 8 bits per lane per link-clock cycle, no UI-level serialization, no signal integrity, no clock recovery; dedicated valid lane assumed fault-free |
| Lane repair / degradation | redundant lanes and width degradation defined by the spec | compaction-based remapping with configurable spares; width modes 32/24/16/8 (24 is our extension) |
| Link training | detailed state machine, parameter exchange | simplified LTSM with our own states and timers |
| Data rates, energy, reach | spec-defined targets per package type | configuration parameters; energy/bit values are placeholders unless a cited source is added |

## 2. Behavioural assumptions

- Both ends of a link share one link clock (forwarded-clock abstraction); link-frequency changes are instantaneous at a retrain boundary.
- The channel is a latency + skew + fault model; there is no crosstalk, ISI, jitter or BER derived from physics. Bit errors come only from the injector (explicit schedule or the hypothetical thermal fault model).
- Memories are behavioural: payloads are regenerated from `LFSR(addr, tag)`, not stored; the HBM-like model has banks and a service-rate cap but no HBM command protocol, refresh or row-buffer policy.
- The accelerator does not compute; compute progress and compute power come from a roofline-style Python model coupled to data delivery.
- The `inject_ts` header field exists only for measurement.
- Epoch time scaling (K) assumes traffic is stationary within an epoch and overstates the relative cost of each retrain by K (thermal_model.md §6).

## 3. Power model

Architectural, event-energy based: static power + energy per event (bit, flit, byte) from placeholder coefficients. It is **not** signoff power, has no gate-level activity by default, and absolute watt values are only as good as their coefficients. Conclusions are drawn from relative comparisons between configurations that share the same coefficients.

## 4. Thermal model

Compact RC network from geometry and bulk material properties: 1-D vertical conduction per tile pair plus lateral conduction within layers, temperature-independent conductivities, effective (homogenized) interface layers, a lumped heatsink and a lumped secondary path. No convection details, no spreading-resistance correction beyond tile discretization, no transistor-level hotspots below tile size. Absolute temperatures depend strongly on assumed parameters; E0 reports sensitivity, and results are framed as comparisons under stated parameters.

## 5. Reliability model

The temperature dependence of fault rates is **hypothetical** (Arrhenius-shaped with placeholder parameters, inflated base rate). It is a tool to ask "what if faults rise with temperature?", not a prediction of real interconnect reliability.

## 6. Synthesis results

Pre-layout Yosys + ABC estimates with open standard-cell libraries (Nangate45, sky130): no placement, routing, clock tree, SRAM macros (FIFOs and buffers are flops) or signoff STA. Estimated maximum frequencies in these libraries will be far below the 2 GHz architectural link clock used in simulation; the simulation clock is an architectural parameter, not a timing claim.

## 7. Labels used in all results

`simulated` (RTL simulation output) · `modeled` (Python power/thermal/fault model output) · `estimated` (synthesis or analytical) · `assumed parameter` (input values). Anything not measured by running code in this repository carries one of these labels.
