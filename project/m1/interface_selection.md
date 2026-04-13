# Interface Selection — ECE 510 Project Milestone 1

## Host Platform

The accelerator chiplet is assumed to be co-packaged or connected to a **general-purpose
laptop/desktop CPU host** (baseline: Intel Core Ultra 7 155H). The host runs the remaining
RAVE inference stages (reparametrize, GeneratorV2 decoder) in PyTorch on CPU.

## Interface Selected: AXI4-Stream

**AXI4-Stream** is chosen from the approved interface list (SPI, I²C, AXI4-Lite, AXI4-Stream,
PCIe, UCIe).

Justification:
- **Streaming-native:** RAVE encoder inference is a one-shot feedforward pipeline — audio
  sub-bands stream in, a latent vector streams out. AXI4-Stream has no addressing overhead
  (unlike AXI4-Lite), matching this dataflow directly.
- **Unidirectional channels:** Separate TDATA channels for input and output eliminate
  arbitration logic; the chiplet acts as a pure streaming accelerator.
- **Standard in ASIC/FPGA flows:** AXI4-Stream is natively supported in OpenLane-compatible
  SoC integration and is a common target for chiplet-to-host interconnects at this bandwidth
  class.

## Bandwidth Requirement

Per 1-second inference frame the accelerator exchanges:

| Direction | Data | Size |
|---|---|---|
| Host → Chiplet | PQMF sub-band audio (16 ch × 3,000 frames × 4 B) | 192,000 B |
| Chiplet → Host | Encoder output µ \|\| log σ² (256 ch × 24 frames × 4 B) | 24,576 B |
| **Total per frame** | | **216,576 B ≈ 216 KB** |

Required bandwidth at each operating point:

| Operating point | Frames/s | Required BW |
|---|---|---|
| 1× real-time | 1 | 216 KB/s = **0.000216 GB/s** |
| Measured SW baseline (11.6× RT) | 11.6 | 2.5 MB/s = **0.0025 GB/s** |
| HW accelerator target (~1,190× RT) | ~1,190 | 257 MB/s = **0.257 GB/s** |

The HW accelerator throughput estimate: encoder analytical FLOPs (3.448 GFLOPs) ÷ target
peak compute (4,096 GFLOPS) = 0.84 ms/frame ≈ 1,190 frames/s.

## Interface Rated Bandwidth

AXI4-Stream configured at **128-bit data width, 200 MHz**:

$$\text{Rated BW} = 16\ \text{B} \times 200 \times 10^6\ \text{Hz} = \textbf{3.2 GB/s}$$

## Bottleneck Assessment

| Operating point | Required BW | Rated BW | Headroom |
|---|---|---|---|
| 1× real-time | 0.000216 GB/s | 3.2 GB/s | 14,800× |
| SW baseline (11.6× RT) | 0.0025 GB/s | 3.2 GB/s | 1,280× |
| HW target (~1,190× RT) | 0.257 GB/s | 3.2 GB/s | 12.5× |

The design is **not interface-bound** at any realistic operating point. Even at the projected
HW accelerator throughput (~1,190× real-time), the interface operates at 8% of its rated
capacity. The performance ceiling is determined by the accelerator's compute throughput
(4,096 GFLOPS) and on-chip SRAM bandwidth (2,048 GB/s), not the host interface.
