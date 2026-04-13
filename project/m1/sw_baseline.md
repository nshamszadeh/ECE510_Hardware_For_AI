# Software Baseline Benchmark — ECE 510 Project Milestone 1

## Platform and Configuration

| Parameter | Value |
|---|---|
| **CPU** | Intel Core Ultra 7 155H (Meteor Lake, 6 P-cores + 8 E-cores + 2 LP E-cores, up to 4.8 GHz) |
| **RAM** | LPDDR5X 7467 MT/s, 2 channels |
| **OS** | Linux 6.17.0-20-generic x86_64 (glibc 2.42) |
| **Python** | 3.13.7 |
| **PyTorch** | 2.11.0+cu130 |
| **Device** | CPU only (`CUDA_VISIBLE_DEVICES=''`) |
| **Model** | RAVE v2 (`rave/configs/v2.gin`, `SAMPLING_RATE=48000`) |
| **Input** | 1 second of mono audio @ 48 kHz — tensor shape `[1, 1, 48000]` (batch size 1) |
| **Warmup runs** | 5 (excluded from timing) |
| **Timed runs** | 10 |

## Execution Time

Wall-clock time measured with `time.perf_counter()` over 10 runs (5 warmup excluded).
Full inference pipeline: PQMF filterbank → encoder → reparametrize → decoder → inverse PQMF.

| Metric | Value |
|---|---|
| **Median** | **86.0 ms / run** |
| Mean | 84.8 ms / run |
| Std dev | 7.1 ms |
| Min | 73.6 ms |
| Max | 93.1 ms |

Individual run times (ms): 75.8, 73.6, 76.4, 85.5, 91.0, 84.9, 89.5, 93.1, 91.3, 86.5

> **Note on profiler vs. wall-clock discrepancy:** `torch.profiler` (run separately, 10 runs)
> reported 51.44 ms/run for the same pipeline. The gap versus wall-clock reflects PyTorch
> dispatcher and framework overhead not captured by the profiler's internal CPU timers. The
> wall-clock figure above is the reproducible end-to-end latency and is used as the M4 baseline.

### Stage-level breakdown (from `torch.profiler`, CPU time)

| Stage | CPU time / run | % of total |
|---|---|---|
| PQMF filterbank | 0.81 ms | 1.6% |
| **Variational encoder** | **24.87 ms** | **48.4%** |
| Reparametrize | 0.26 ms | 0.5% |
| Decoder + inverse PQMF | 25.49 ms | 49.6% |

The encoder and decoder are essentially tied in wall time — the 1.2% difference is within
profiling noise on a general-purpose laptop with background OS load. The encoder is selected
as the hardware acceleration target for three reasons beyond raw timing:

1. **Dominant low-level kernel:** `aten::mkldnn_convolution` accounts for 76.9% of total
   profiler CPU time and originates primarily from the encoder's strided Conv1d layers, not
   the decoder's ConvTranspose1d layers.
2. **Natural partition boundary:** The encoder output is a 128-dimensional latent vector
   at 24 Hz (12 KB/frame) — a compact interface that transfers cheaply to the host CPU for
   decoding. The alternative boundary (before the decoder) would require passing 192 KB of
   PQMF sub-band audio in the reverse direction.
3. **Architectural regularity:** The encoder consists entirely of strided Conv1d and dilated
   Conv1d layers, mapping cleanly to a systolic MAC array. The decoder includes amplitude
   modulation and a noise synthesis path that add control-flow complexity unsuitable for
   a first-generation accelerator.

Full justification is in `codefest/cf02/analysis/ai_calculation.md` §1.

## Throughput

Analytical FLOPs for full pipeline (PQMF + encoder + decoder):

| Stage | FLOPs |
|---|---|
| PQMF filterbank | 49.3 M |
| Variational encoder | 3,448.3 M |
| Decoder (GeneratorV2) | 3,557.8 M |
| **Total** | **7,055.4 M (7.055 GFLOPs)** |

$$\text{Throughput} = \frac{7.055 \text{ GFLOPs}}{0.0860 \text{ s}} = \textbf{82.0 GFLOPS}$$

$$\text{Real-time factor} = \frac{1.0 \text{ s audio}}{0.0860 \text{ s inference}} = \textbf{11.6}\times \text{ faster than real-time}$$

The encoder stage alone: 3,448.3 MFLOPs / 24.87 ms (profiler) = **138.6 GFLOPS** — 9.3% of
the CPU's theoretical 1,488 GFLOPS AVX2 FMA ceiling, confirming the L3 cache overflow bottleneck
identified in the roofline analysis.

## Memory Usage

Peak RSS measured via `resource.getrusage(RUSAGE_SELF)` after 10 inference runs:

| Metric | Value |
|---|---|
| **Peak RSS** | **1,331.9 MB** |

The dominant contributor is model weights (58.7M parameters × 4 B = 234.8 MB loaded weights),
plus PyTorch framework allocations, intermediate activation buffers, and the RAVE gin/module
registry overhead.
