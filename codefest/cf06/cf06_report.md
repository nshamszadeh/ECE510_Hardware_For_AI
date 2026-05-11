# CF06: 4×4 Binary-Weight Crossbar MAC Unit

## Module Design

### Overview

`crossbar_mac_4x4` implements a 4×4 crossbar multiply-accumulate unit where each weight is binary: either +1 or −1. Four signed 8-bit inputs are presented each clock cycle, and four 10-bit signed outputs are produced one cycle later.

### Port Summary

| Port | Direction | Width | Description |
|---|---|---|---|
| `clk` | input | 1 | Clock |
| `rst_n` | input | 1 | Active-low async reset |
| `in_data[3:0]` | input | 8b signed (unpacked) | Input activations |
| `weight_wr_en` | input | 1 | Weight write enable |
| `weight_row` | input | 2 | Row address for weight write |
| `weight_col` | input | 2 | Column address for weight write |
| `weight_val` | input | 1 | Weight value: 1 = +1, 0 = −1 |
| `out` | output | [3:0][9:0] packed | Registered MAC outputs |

### Weight Storage

Weights are stored in a packed `[3:0][3:0]` register array, indexed as `weight[row][col]`. A `1` bit encodes +1 and a `0` bit encodes −1. On reset (`rst_n = 0`), all 16 weights are initialized to `1` (+1). Weights are updated one cell at a time through the serial write port using a `case` decode on `{weight_row, weight_col}`.

### MAC Computation

Each input is sign-extended from 8 to 10 bits:

```
sx[i] = { {2{in_data[i][7]}}, in_data[i] }
```

Each cell's weighted contribution is:

```
wc[i][j] = weight[i][j] ? sx[i] : -sx[i]
```

The output for column `j` is the sum of contributions from all four rows:

```
out[j] = wc[0][j] + wc[1][j] + wc[2][j] + wc[3][j]
       = Σ_i weight[i][j] × in_data[i]
```

The combinational sum is registered on the rising clock edge, producing a one-cycle pipeline latency. Output width is 10 bits, which covers the full range of 4 × [−128, 127] = [−512, 508].

### Implementation Notes

Two iverilog-specific constraints shaped the implementation:

- **Packed arrays only in `always_ff`:** Iverilog does not support procedural assignment to unpacked array ports. All internal storage (`weight`, `out`) uses packed types so they can be driven from `always_ff` blocks.
- **Case decode for weight write:** Iverilog rejects variable indices into packed 2D arrays in procedural blocks, so weight writes are decoded with a 16-entry `case` on `{weight_row, weight_col}`.

---

## Testbench Strategy

### Reset Handling

The testbench initializes `rst_n = 1`, then pulses it low for one half-cycle before releasing it. This ensures the flip-flops see a proper 1→0 falling edge, which is required to trigger the asynchronous reset.

### Weight Loading

Weights are written serially using the `write_weight` task, one entry per clock cycle. The task asserts `weight_wr_en` on a `negedge`, holds through the following `posedge` (where the FF captures the value), then deasserts.

### Weight Matrix Loaded

The following 4×4 weight matrix was programmed (rows = input index, columns = output index):

```
         col0  col1  col2  col3
row 0:   +1    −1    +1    −1
row 1:   +1    +1    −1    −1
row 2:   −1    +1    +1    −1
row 3:   −1    −1    −1    +1
```

Stored as bits (1 = +1, 0 = −1):

```
weight[0] = 1010
weight[1] = 1100
weight[2] = 0110
weight[3] = 0001
```

### Input Vector Applied

```
in_data = [10, 20, 30, 40]
```

### Expected Outputs (Hand-Calculated)

`out[j] = Σ_i W[i][j] × in[i]`

| j | Computation | Result |
|---|---|---|
| 0 | (+1)(10) + (+1)(20) + (−1)(30) + (−1)(40) | **−40** |
| 1 | (−1)(10) + (+1)(20) + (+1)(30) + (−1)(40) | **0** |
| 2 | (+1)(10) + (−1)(20) + (+1)(30) + (−1)(40) | **−20** |
| 3 | (−1)(10) + (−1)(20) + (−1)(30) + (+1)(40) | **−20** |

---

## Simulation Results

Simulation was run with Icarus Verilog 12.0. The log below was captured in `sim_log.log`:

```
─── Results ───────────────────────────
PASS  out[0] = -40
PASS  out[1] = 0
PASS  out[2] = -20
PASS  out[3] = -20
─── 4 passed, 0 failed ────────────
```

All four outputs matched the hand-calculated values exactly. The simulation confirms correct signed MAC behavior across both positive and negative output values, including the zero case at `out[1]`.
