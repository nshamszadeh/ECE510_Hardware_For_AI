# ResNet-18 Layer Analysis

## Top 5 Layers by MAC Count (FP32, batch=1, input 3×224×224)

| Rank | Layer | MACs | Params |
|------|-------|------|--------|
| 1 | Conv2d: 1-1 | 117,964,800 | 9,408 |
| 2 | Conv2d: 3-1 | 115,605,504 | 36,864 |
| 3 | Conv2d: 3-4 | 115,605,504 | 36,864 |
| 4 | Conv2d: 3-7 | 115,605,504 | 36,864 |
| 5 | Conv2d: 3-10 | 115,605,504 | 36,864 |

## Arithmetic Intensity — Conv2d: 1-1 (No Data Reuse)

**Layer config:** 7×7 kernel, C_in=3, C_out=64, output 112×112, stride=2, FP32 (4 bytes/element)

### DRAM Traffic

| Tensor | Shape | Elements | Bytes (FP32) |
|--------|-------|----------|--------------|
| Input activations | 3 × 224 × 224 | 150,528 | 602,112 |
| Weights | 7 × 7 × 3 × 64 | 9,408 | 37,632 |
| Output activations | 64 × 112 × 112 | 802,816 | 3,211,264 |
| **Total** | | | **3,851,008** |

### Compute

| Quantity | Value |
|----------|-------|
| MACs | 117,964,800 |
| FLOPs (×2) | 235,929,600 |

### Arithmetic Intensity

```
AI = FLOPs / Bytes
   = 235,929,600 / 3,851,008
   ≈ 61.3 FLOP/byte
```

> **Interpretation:** Most modern GPUs and accelerators have a hardware ridge point well above 61 FLOP/byte (e.g. A100 FP32 ~208 FLOP/byte), so this layer is **memory-bandwidth bound** under the no-reuse assumption. In practice, on-chip tiling reuses weights and activations, raising effective arithmetic intensity and shifting the layer toward the compute-bound regime.
