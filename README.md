# High-Speed UART with Metastability Handling

Verilog implementation of a high-speed UART transmitter/receiver on a Spartan-7 FPGA, operating at **4 Mbps** with a **100 MHz** clock. The core focus of this project is **clock domain crossing (CDC)** — specifically, detecting and resolving **metastability** that arises when the transmitter and receiver run on independent, non-synchronous clocks.

Designed, simulated, and synthesized in **Xilinx Vivado**.
---

## Table of Contents

- [Overview](#overview)
- [Repository Structure](#repository-structure)
- [System Architecture](#system-architecture)
- [How It Works](#how-it-works)
- [Metastability: The Core Problem](#metastability-the-core-problem)
- [Two-Stage Synchronizer Solution](#two-stage-synchronizer-solution)
- [Verification Strategy](#verification-strategy)
- [Running the Simulation](#running-the-simulation)
- [Results](#results)
- [Tools Used](#tools-used)
- [Limitations](#limitations)
- [Future Scope](#future-scope)
- [References](#references)

---

## Overview

UART (Universal Asynchronous Receiver Transmitter) is a simple, low-cost serial protocol used widely in embedded and FPGA-based systems. It supports **simplex**, **half-duplex**, and **full-duplex** communication.

This project implements a UART transmitter and receiver pair that:
- Operates at a baud rate of **4 Mbps**
- Uses **independent clocks** for TX and RX (true asynchronous communication, no shared clock line)
- Frames data into **11-bit frames**: `1 start bit + 8 data bits + 1 parity bit + 1 stop bit`
- Explicitly detects and resolves **metastability** caused by clock domain crossing
- Is verified through **simulation with injected metastability** to quantitatively prove the synchronizer works

---

## Repository Structure

```
uart-metastability/
├── README.md
├── LICENSE
├── .gitignore
├── src/
│   ├── uart_tx.v       # UART transmitter (FSM + serialization)
│   ├── uart_rx.v       # UART receiver with 2-stage synchronizer + metastability injection
│   └── UART_ma.v       # Top-level module wiring uart_tx + uart_rx together
└── sim/
    └── uart_tb.v       # Self-checking testbench (20 random bytes, pass/fail tracking)
```

---

## System Architecture

### Transmitter

```
sys_clk, reset ──▶ Baud Rate Generator ──▶ baud_clk
tx_enable ────────▶ Transmitter FSM ──▶ load / shift / busy
tx_data_in ───────▶ Parity Generator ──▶ parity_bit
                                  │
                                  ▼
                          PISO Register ──▶ serial_data (TX line)
```

- **Baud Rate Generator** — divides the 100 MHz system clock down to a 4 Mbps `baud_clk` using a counter that resets on reaching a calculated division value.
- **Parity Generator** — computes a single parity bit via XOR across all 8 data bits (even parity used in this design; odd parity = inverted XOR).
- **Transmitter FSM** — states: `IDLE → LOAD → SHIFT → IDLE`. Waits for `tx_enable`, loads the 11-bit frame into the PISO register, then shifts it out one bit per `baud_clk` pulse.
- **PISO Register** (Parallel-In Serial-Out) — loads the full 11-bit frame in parallel, then shifts it out serially: start bit → LSB-first data → parity → stop bit.

### Receiver

```
serial_data_in ──▶ 2-FF Synchronizer ──▶ Negative Edge Detector ──▶ start_detect_bit
                                                                          │
sys_clk, reset ──▶ Baud Rate Generator ──▶ baud_clk                      ▼
                                                                   Receiver FSM ──▶ load/shift
                                                                          │
                                                                          ▼
                                                                   SIPO Register ──▶ parallel_data_out
                                                                          │
                                                                          ▼
                                                                   Parity Checker ──▶ data_valid / parity_error
```

- **Baud Rate Generator** — same division logic as TX, locally generates `baud_clk` for sampling.
- **2-FF Synchronizer** — the metastability-mitigation block (see below); the *first* thing the asynchronous serial input passes through.
- **Negative Edge Detector** — a D-flip-flop-based circuit that detects the high-to-low transition marking the start bit, and fires `start_detect_bit` to wake up the FSM.
- **Receiver FSM** — states: `IDLE → SHIFT → LOAD → IDLE`. Waits for the start bit, samples all 11 bits into the SIPO register at `baud_clk` intervals, then outputs the parallel byte.
- **SIPO Register** (Serial-In Parallel-Out) — shifts in bits one at a time; outputs the full 8-bit byte once all 11 bits are captured.
- **Parity Checker** — recomputes parity over the received 8 bits via XOR and compares it to the received parity bit; asserts `data_valid` only on a match, else flags `parity_error`.

---

## How It Works

1. **Idle state** — the serial line sits at logic high (`1`).
2. **Transmission begins** — TX FSM pulls the line low (start bit), then shifts out the 8 data bits (LSB first), the parity bit, and finally a stop bit (`1`).
3. **Reception** — the RX line is constantly synchronized through the 2-FF chain. The negative edge detector watches for the high→low transition and fires the start pulse.
4. **Sampling** — once triggered, the receiver FSM uses its own `baud_clk` to sample each subsequent bit at the correct interval, filling the SIPO register.
5. **Validation** — after 11 bits are captured, the parity checker verifies integrity and the parallel byte is presented on `rx_data_out` with a `data_valid` pulse.

---

## Metastability: The Core Problem

- TX runs on `tx_clk` at **exactly 100 MHz**. RX runs on `rx_clk` at **100.01 MHz** — a deliberate, tiny frequency offset to model real-world clock drift between independent oscillators.
- Because the two clocks are not phase-locked, the serial line can change state at unpredictable times relative to the RX clock edge.
- If a flip-flop samples the input while it's *mid-transition* (violating setup/hold time), its output goes into an **indeterminate ("metastable") state** — neither a clean 0 nor 1 — for a finite, unpredictable resolution time.
- Over many frames, the slow drift between `tx_clk` (10 ns period) and `rx_clk` (9.999 ns period) causes the RX sampling point to "walk" across TX bit edges, occasionally landing exactly on a transition and triggering metastability.
- Left unhandled, this causes **random bit errors and frame corruption** — a serious reliability risk in any clock domain crossing (CDC) design.

---

## Two-Stage Synchronizer Solution

The receiver's defense is a **two-stage flip-flop synchronizer**, placed immediately after `serial_in`, before any other logic touches the signal:

- **Stage 1 (`sync_stage1`)** — captures the raw asynchronous `serial_in` on the RX clock edge. This is the flip-flop most likely to go metastable if sampling lands on a transition.
- **Stage 2 (`sync_stage2`)** — samples the (possibly still-settling) output of Stage 1 on the *next* RX clock edge. This extra clock cycle gives Stage 1 time to resolve to a stable `0` or `1` with a probability greater than **99.99%**.
- **`ASYNC_REG = "TRUE"`** attribute is applied to both flip-flops — this is a synthesis directive that tells Vivado to preserve these registers exactly as placed and *not* retime or optimize them across the clock boundary, which would defeat their purpose.
- The clean `sync_stage2` output is the only signal that feeds into the rest of the receiver FSM — nothing downstream ever sees a potentially metastable value.

---

## Verification Strategy

To *prove* the synchronizer works (rather than just asserting it), the testbench includes a built-in fault-injection mode:

| Mode | Setting | Behavior |
|---|---|---|
| **Normal** | `INJECT_META = 0` | Uses the clean, synchronized `sync_stage2` signal. Expected result: ~100% success rate despite clock drift. |
| **Injection** | `INJECT_META = 1` | Randomly flips `sync_stage2` using `$random`, artificially simulating the bit errors that would occur **without** proper CDC handling. |

- The testbench transmits a packet of **20 random bytes** in each mode and tracks `meta_event_count`, byte mismatches, and overall success rate.
- This dual-mode comparison gives a **quantitative, side-by-side proof** that the synchronizer is what's preventing data corruption — not just a qualitative claim.

---

## Running the Simulation

This design was verified using **Icarus Verilog** (open-source, free to install) in addition to Vivado. To run it yourself:

```bash
# Compile
iverilog -g2012 -o sim_out src/uart_tx.v src/uart_rx.v src/UART_ma.v sim/uart_tb.v

# Run
vvp sim_out
```

By default, `INJECT_META` is set to `0` in `sim/uart_tb.v`, which runs the **normal mode** — expect a **100% success rate** with 0 metastability events.

To see the failure mode (no synchronizer protection), open `sim/uart_tb.v` and change:
```verilog
parameter INJECT_META = 0;  // change to 1
```
Re-compile and re-run — you should see corrupted bytes, mismatches against expected data, and a rising `meta_event_count`, exactly as described below.

---

## Results

Verified directly against this repository's code (Icarus Verilog, 20-byte randomized test):

| | Normal mode (`INJECT_META = 0`) | Injection mode (`INJECT_META = 1`) |
|---|---|---|
| Bytes sent | 20 | 20 |
| Bytes received correctly | **20 / 20** | **0 / 20** |
| Metastability events | 0 | 20 |
| Success rate | **100%** | **0%** |

- **With the 2-stage synchronizer active:** every byte sent on `tx_data[7:0]` was correctly recovered on `rx_data[7:0]` despite the deliberate clock drift between `tx_clk` (100 MHz) and `rx_clk` (100.01 MHz).
- **With metastability injected:** every byte was corrupted — a stark, reproducible demonstration of why CDC synchronization isn't optional in asynchronous designs.
- Post-synthesis schematic (Vivado) confirms a true asynchronous architecture — `uart_tx` and `uart_rx` share no clock net; each runs off its own clock via `BUFG` primitives, with `IBUF`/`OBUF` handling the parallel-to-serial boundary.

---

## Tools Used

- **HDL:** Verilog
- **Simulation / Synthesis:** Xilinx Vivado
- **Target Device:** Spartan-7 FPGA
- **Verification:** Self-checking testbench with randomized data and fault injection

---

## Limitations

- Fixed baud rate (4 Mbps) — no adaptive/auto baud detection.
- Even parity only in this implementation, despite a configurable parity generator.
- No FIFO buffering — not suited to bursty/back-to-back data without gaps.
- Verification is limited to 20 random bytes per run with injected (not real-world) jitter; no long-term MTBF measurement yet.

---

## Future Scope

- Quantitative **MTBF (Mean Time Between Failures)** analysis for the synchronizer.
- Add **FIFO buffering** to support continuous/bursty data streams.
- Use **MMCM/PLL** blocks for more sophisticated clock management, enabling baud rates beyond 4 Mbps.
- Support **adaptive baud rate** and configurable frame formats (odd parity, variable data widths).
- Explore advanced CDC techniques (e.g., Gray coding) for multi-bit signal crossings.
- Study the power-consumption trade-offs of adaptive synchronization schemes.

---

## References

Full citation list available in the project report / IEEE paper. Key references include Cummings (CDC Design & Verification), R. Ginosar (Metastability and Synchronizers: A Tutorial), and Veendrick (flip-flop synchronizer failure rate analysis).

---

## Acknowledgement

This work was conducted under the **Chips to Startup (C2S) grant** of MeitY, under the guidance of **Dr. Seema Rajput**, Department of Electronics and Telecommunication, MKSSS' Cummins College of Engineering for Women, Pune.
