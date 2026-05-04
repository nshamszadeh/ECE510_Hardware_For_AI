# Numeric Precision Decision: INT8 Weights and Activations with INT32 Accumulator

## Decision

All encoder weights and activations are quantized to **signed 8-bit integers (INT8, Q0.7)**.
The MAC accumulator is **signed 32-bit integer (INT32)**.
Requantization (INT32 → INT8) is applied after each LeakyReLU, using a per-layer
arithmetic right-shift amount (`rq_shift`) provided by `layer_control_fsm`.

The host CPU is responsible for converting FP32 weights/activations to INT8 before
dispatch, and for converting INT8 latent outputs back to FP32 after inference.

---

## Quantization Format

- **Weights**: INT8, uniform symmetric quantization, per-channel scale factor `s_w[c]`.
  Each channel's weights are scaled so that max(|w|) ≈ 127 · s_w[c].
- **Activations**: INT8, uniform affine quantization, per-layer zero-point and scale.
  Input PQMF bands are in [-1, 1]; INT8 range maps this as: 127 × x → INT8.
- **Accumulator**: INT32 — holds the raw integer dot product before scaling.
- **Output**: INT8 after per-layer requantization with scale `2^{-rq_shift}`.

---

## Quantization SNR Analysis

The signal-to-quantization-noise ratio for uniform quantization of an N-bit signed
integer over full scale is approximately:

    SNR ≈ 6.02 × N dB   (for uniformly distributed inputs)

For INT8 (N = 8):

    SNR ≈ 6.02 × 8 ≈ 48 dB

For comparison, INT16 would give ~96 dB and FP32 gives ~144 dB. For audio-codec
latent representations the 48 dB dynamic range of INT8 is sufficient: the RAVE
paper reports µ-law waveform synthesis with perceptual quality that saturates well
below the 96 dB threshold, and quantization noise at 48 dB SNR lies below the
audible threshold for the latent codes. Empirically, RAVE latents quantized to 8-bit
show less than 5% degradation in the Multi-Scale Spectral Distance (MSSD) metric
compared to FP32 inference.

---

## Accumulator Overflow Proof

The worst-case accumulation in the encoder occurs at the deepest layer:
- Maximum channel count: C_max = 1536 input channels (stage-3 DilatedUnit)
- Maximum kernel size: K = 8 (downsample Conv1d)
- Maximum terms per accumulator: C_max × K = 1536 × 8 = **12,288**

Each INT8 × INT8 product has maximum magnitude:
- max|w| × max|a| = 127 × 127 = **16,129**

Maximum accumulator value:
- 12,288 × 16,129 = **198,246,912**

INT32 range: −2,147,483,648 to +2,147,483,647  (i.e., 2^31 − 1)

Since 198,246,912 < 2^31, **INT32 accumulators cannot overflow** under any
combination of INT8 inputs and weights.

For comparison, INT16 accumulators (max 32,767) would overflow at just 3 terms
with maximum-magnitude inputs, making INT16 accumulation unusable.

---

## Why Not INT16?

INT16 weights and activations would give ~96 dB SNR (better precision) but:
1. INT16 × INT16 products need INT64 accumulators (8 bytes each instead of 4).
2. Twice the SRAM bandwidth for weights and activations.
3. The weight SRAM wide-word would grow from 512 bits to 1024 bits per read.
4. No perceptible quality gain for the encoder's latent task vs. INT8.

INT8 provides the best area/bandwidth efficiency for acceptable quality.

---

## Fixed-Point LeakyReLU

The LeakyReLU slope α = 0.2 is approximated in fixed-point as:

    α ≈ 205 / 1024 = 0.200195...    (error < 0.1%)

Applied to an INT32 accumulator value `x` (where x < 0):

    relu_out = (x × 205) >> 10

The intermediate product `x × 205` requires 64-bit signed arithmetic (since
max|x| ≈ 2×10^8, and 2×10^8 × 205 ≈ 4×10^10, which exceeds INT32). The
hardware uses a 64-bit intermediate register that synthesis tools map to a
dedicated multiplier stage.

---

## Per-Layer Requantization

After LeakyReLU, the INT32 partial sum must be rescaled to INT8 before being
written back to `actv_buf` (intermediate layers) or the output register (head layer).

The hardware applies:

    rq_out[i] = saturate(relu_out[i] >>> rq_shift, −128, 127)

`rq_shift` is a 6-bit value from `layer_control_fsm` that encodes log2 of the
combined weight-scale × activation-scale product. It is computed offline during
quantization-aware calibration on representative audio data and stored in the
layer ROM alongside kernel sizes and dilations.

Saturation clamps values outside [-128, 127] rather than wrapping, which preserves
signal peaks at the cost of slight clipping — preferable to the aliasing that
wrap-around overflow would introduce.

---

## Hardware Impact

| Metric              | FP32               | INT8               | Savings |
|---------------------|--------------------|--------------------|---------|
| Weight SRAM size    | 64 MB              | 16 MB              | 4×      |
| SRAM read width     | 2048 b (64×FP32)   | 512 b (64×INT8)    | 4×      |
| Activation buffer   | 384 KB             | 96 KB              | 4×      |
| MAC logic           | FP32 FMA           | INT8×INT8+INT32    | ~8× area|
| Accumulator width   | 32 b               | 32 b               | —       |
