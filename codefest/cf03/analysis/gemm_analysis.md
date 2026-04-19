# GEMM Roofline Analysis — RTX 3070

Kernels were run locally on my RTX 3070. Performance and bandwidth specs were taken from https://www.techpowerup.com/gpu-specs/geforce-rtx-3070.c3674.
Tiling with T = 8 showed no significant performance improvement. A hypothesized reason for this was because of the 3070's 4MB L2 cache handling a lot of reuse in the naive GEMM kernel under the hood. Even though the next bit isn't required for this assignment, the kernel was run and profiled for T=32 to try and see if increasing tile size yielded more significant performance improvements.

## Roofline Construction

The roofline bounds peak FP32 throughput at **20.31 TFLOP/s** and peak DRAM
bandwidth at **448 GB/s**, giving a ridge point of **45.3 FLOP/byte**. Kernels
left of the ridge are memory-bound; kernels right of it are compute-bound.
Arithmetic intensity (AI) for each kernel was derived from `ncu`'s
`dram__bytes_read.sum` and `dram__bytes_write.sum` counters for accurate
placement on the plot.

| Kernel | DRAM traffic | AI (FLOP/byte) | Achieved | Memory ceiling at AI |
|---|---|---|---|---|
| Naive       | 79.7 MB  | 26.9 | 1.23 TFLOP/s | 12.1 TFLOP/s |
| Tiled (T=8) | 90.9 MB  | 22.6 | 1.25 TFLOP/s | 10.1 TFLOP/s |
| Tiled (T=32)| 112.4 MB | 19.1 | 1.53 TFLOP/s |  8.6 TFLOP/s |

## Why the Naive Kernel is Memory-Bound

Each output element independently streams N=1024 values from A and N values
from B out of DRAM with no cross-thread reuse. This produces an AI of ~27
FLOP/byte — well below the ridge point of 45.3 — so the kernel stalls on DRAM
latency rather than saturating the FP32 pipelines. All three kernels fall in
the memory-bound region.

## How Tiling Reduces DRAM Traffic

Shared-memory tiling loads an T×T tile of A and B once per k-step, letting all
T² threads in the block reuse those values before the next fetch. In theory this
reduces DRAM reads by a factor of T. In practice, the RTX 3070's 4 MB L2 cache
already intercepts repeated accesses at this matrix size (each 1024×1024 FP32
matrix is 4 MB), so measured DRAM traffic does not follow theory — T=32 actually
generates *more* DRAM traffic (112 MB) than the naive kernel (80 MB) because
1024 threads per block issue a larger working set simultaneously, increasing L2
pressure and evictions.

## Did T=32 Tiling Achieve the Expected Improvement?

Partially. T=32 delivers a **~24% throughput gain** over naive (1533 vs
1234 GFLOP/s), but the mechanism is occupancy rather than traffic reduction.
A 32×32 block provides 1024 threads (32 warps) versus 256 (8 warps) for the
naive 16×16 block, giving the warp scheduler far more in-flight warps to
overlap with memory latency. Despite this, both kernels sit at roughly
**12–15% of their respective memory-bound ceilings**, indicating that
memory-access latency, not bandwidth saturation, is the dominant bottleneck.
Further gains would require double-buffering tiles to overlap shared-memory
loads with computation, or moving to a larger problem size where L2 reuse
breaks down and explicit tiling provides genuine DRAM traffic reduction.
