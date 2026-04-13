# HW/SW Partition Rationale — ECE 510 Codefest 02, Task 8

## (a) Kernel Selected for Hardware Acceleration

The **EncoderV2 stage** is selected. It contributes ~49% of total inference FLOPs (3.45 GFLOPs)
and is the primary compute bottleneck. The roofline places it at AI = 53.5 FLOP/byte, above the
CPU ridge of 12.45 FLOP/byte (nominally compute-bound). However, the measured throughput of
~135 GFLOPS is only 9% of the 1,488 GFLOPS CPU ceiling because the 61.5 MB weight set overflows
the 24 MB L3 cache, forcing repeated DRAM accesses each frame. A custom ASIC caches all weights
in on-chip SRAM, eliminating this traffic and raising the effective AI to 15,922 FLOP/byte. The
hypothetical design point (4,096 GFLOPS peak, 2,048 GB/s on-chip SRAM) sits above the CPU
ceiling on the roofline, representing a ~30× improvement over the measured baseline.

## (b) Software Baseline Responsibilities

The host CPU retains the **reparametrization step** (< 1% of inference time) and the full
**GeneratorV2 decoder** including inverse PQMF. The decoder stays in software to preserve
flexibility for latent-space manipulation; its input — a 12 KB latent vector per frame —
imposes negligible demand on the host interface.

## (c) Interface Bandwidth Requirement

Per 1-second inference frame: 16-channel PQMF input = 192 KB; encoder output = 24 KB;
**total = 216 KB/frame**.

$$\text{Required BW} = 216\ \text{KB/frame} \times 1\ \text{frame/s} = 0.000216\ \text{GB/s}$$

AXI4-Stream at 128-bit width, 200 MHz: **rated BW = 3.2 GB/s**

The interface provides over 14,000× the required bandwidth at real-time throughput. The interface
is not a bottleneck under any realistic operating condition, including throughput targets well
beyond real-time.

## (d) Bound Classification — Before and After

**Today (CPU):** Nominally compute-bound per the roofline, but effectively memory-bound in
practice — the 61.5 MB weight set overflows L3 cache and reduces utilization to ~9% of
peak compute.

**After acceleration:** Weights are loaded into on-chip SRAM once at startup. Per-frame off-chip
traffic drops to 216 KB (activations only), raising effective AI to 15,922 FLOP/byte. The
hypothetical SRAM ridge point is 4,096 / 2,048 = 2.0 FLOP/byte — far below the operating AI
— making the design fully **compute-bound** and achieving the intended operating regime for a
custom accelerator.
