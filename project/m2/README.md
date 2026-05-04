# Milestone 2 — RAVE v2 Encoder Hardware Accelerator

## Overview

RTL implementation of the RAVE v2 variational encoder as a systolic Conv1d accelerator
with an AXI4-Stream host interface.  The design comprises eight SystemVerilog modules and
a cocotb testbench suite covering every module individually plus full integration.

---

## Repository Layout

```
project/m2/
├── rtl/
│   ├── mac_lane.sv          # Single MAC unit: INT8 multiply-accumulate
│   ├── mac_array.sv         # 64-lane parallel MAC array (MAC_LANES=64)
│   ├── leaky_relu.sv        # Leaky ReLU activation (α=0.2, INT8 I/O)
│   ├── weight_sram.sv       # Single-port weight SRAM (512-bit wide words)
│   ├── actv_buf.sv          # Activation history ring buffer (Conv1d taps)
│   ├── layer_control_fsm.sv # 10-layer encoder FSM: SRAM sequencing, MAC control
│   ├── compute_core.sv      # Top-level compute wrapper (all sub-modules)
│   └── interface.sv         # AXI4-Stream ↔ compute_core bridge (encoder_axi)
└── tb/
    ├── Makefile
    ├── tb_mac_lane.py
    ├── tb_mac_array.py
    ├── tb_leaky_relu.py
    ├── tb_weight_sram.py
    ├── tb_actv_buf.py
    ├── tb_layer_control_fsm.py
    ├── tb_compute_core.py
    └── tb_interface.py
```

---

## Dependencies

| Tool / Package | Version | Notes |
|---|---|---|
| Icarus Verilog | **12.0 (stable)** | Simulator |
| GTKWave | 3.3.125 | Waveform viewer (optional) |
| Python | **3.13** | Must match the venv |
| cocotb | **2.0.1** | Install via pip (see below) |

No other Python packages are required.  cocotb pulls in its own VPI libraries.

### Setting up the Python environment

```bash
python3 -m venv ~/venv
source ~/venv/bin/activate
pip install cocotb==2.0.1
```

Verify the install:

```bash
cocotb-config --version   # should print 2.0.1
iverilog -V               # should print version 12.0
```

---

## Running the Testbenches

All commands are run from `project/m2/tb/`.  Activate the venv first:

```bash
source ~/venv/bin/activate
cd project/m2/tb
```

### Individual module tests

```bash
make TOPLEVEL=mac_lane
make TOPLEVEL=mac_array
make TOPLEVEL=leaky_relu
make TOPLEVEL=weight_sram
make TOPLEVEL=actv_buf
make TOPLEVEL=layer_control_fsm
```

### Integration tests

```bash
# compute_core (all 6 sub-modules wired together; ~182 k cycles per run)
make TOPLEVEL=compute_core

# encoder_axi AXI4-Stream wrapper (full end-to-end; ~183 k cycles per run)
make TOPLEVEL=encoder_axi
```

Each `make` invocation compiles with Icarus Verilog (`iverilog -g2012`) and runs the
simulation under `vvp`.  Build artefacts land in `sim_build/<TOPLEVEL>/`; switching
`TOPLEVEL` never reuses a stale binary.

### Viewing waveforms

Append `WAVES=1` to any make command to capture an FST dump:

```bash
make TOPLEVEL=compute_core WAVES=1
gtkwave sim_build/compute_core/compute_core.fst
```

### Expected output

A passing run prints a summary table to stdout:

```
** TESTS=N PASS=N FAIL=0 SKIP=0 **
```

The `compute_core` testbench (`tb_compute_core.py`) explicitly zeros all
177,632 weight SRAM words before running inference, so that test takes
roughly **20–30 s** of real time.  The `encoder_axi` `test_full_pipeline`
sends only one 64-byte weight word and relies on the FSM's cycle-count
sequencing for correctness (weight SRAM data is not numerically checked),
so it completes in roughly **20 s**.

---

## Test Summary

| TOPLEVEL | Tests | What is verified |
|---|---|---|
| `mac_lane` | — | Multiply-accumulate correctness, clear, overflow |
| `mac_array` | — | 64-lane parallel accumulation |
| `leaky_relu` | — | Positive pass-through, negative slope (α=0.2) |
| `weight_sram` | — | Write-then-read round-trip, address independence |
| `actv_buf` | — | Ring-buffer wrap, history tap reads |
| `layer_control_fsm` | 6 | Reset/load, ST_INPUT addresses, SRAM sequencing, mac_en pipeline timing, ST_ACTIVATE addresses, mac_grp advancement |
| `compute_core` | 2 | s_ready gating on w_load_done; full 10-layer pipeline (m_valid, m_last, s_ready recovery) |
| `encoder_axi` | 3 | S_AXIS tready in weight/input phases; full AXI4-Stream weight→input→output cycle (256 output bytes, m_axis_tlast) |

---

## Deviations from the Milestone 1 Plan

### 1. AXI4-Stream data width: 128-bit → 8-bit (INT8 byte-serial)

**M1 plan:** The interface selection document specified AXI4-Stream at a
**128-bit data width** operating at 200 MHz, yielding 3.2 GB/s rated bandwidth.

**M2 implementation:** `interface.sv` (`encoder_axi`) uses an **8-bit (INT8)**
TDATA width with the host streaming one byte per beat.

**Why:** The 128-bit figure in M1 was a bandwidth headroom analysis, not a
physical TDATA constraint.  INT8 byte-serial was chosen for M2 because:
- It directly matches the INT8 precision of the weight SRAM and MAC array,
  eliminating any width-conversion logic at the boundary.
- The packed 16-channel input word (128 bits) and 64-byte weight word (512 bits)
  are assembled inside `encoder_axi` from consecutive byte beats, keeping the
  AXI4-Stream slave port minimal and host-agnostic.
- Bandwidth is not the bottleneck: the M1 analysis showed 12.5× headroom even
  at ~1,190× real-time throughput, so narrowing TDATA to 8 bits does not affect
  the performance target.

### 2. Encoder kernel scope: FP32 → INT8

**M1 plan:** The software baseline profiled PyTorch FP32 (`float32`) convolutions.
No explicit precision was committed to for the hardware implementation.

**M2 implementation:** All MAC units, the weight SRAM, the activation buffer,
and the AXI4-Stream data path operate in **INT8**.

**Why:** INT8 enables 4× weight density compared to FP32 (reducing on-chip SRAM
area), and the 64-lane INT8 MAC array fits the systolic Conv1d pattern with
minimal routing complexity.  Quantisation correctness is deferred to a later
milestone; M2 verifies the control and datapath structure with zero-weight
smoke tests.

### 3. frame_last_r capture point (implementation correction)

During integration testing, `m_last` was found to be permanently 0.  Root cause:
`s_last` is de-asserted by the testbench immediately after the single-cycle
`s_valid` beat in `ST_IDLE`; by the time `state_r` reaches `ST_INPUT`,
`s_last` is already 0.  The fix — latching `frame_last_r` inside the `ST_IDLE`
`if (s_valid)` branch of `layer_control_fsm.sv` — was verified by re-running
all six FSM tests (still passing) before the compute_core integration tests
passed.
