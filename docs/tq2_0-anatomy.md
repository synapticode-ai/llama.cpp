# TQ2_0 Block Layout — Ternary Quantisation Format

_A field guide to mainline llama.cpp's ternary quantisation format, written while bringing BitNet b1.58 2B4T up on it. The format itself is upstream's (ggml-org/llama.cpp); this document explains how it works and what we measured._

## Overview

TQ2_0 is mainline llama.cpp's purpose-built ternary quantisation format:
`GGML_TYPE_TQ2_0 = 35`. Designed for {-1, 0, +1} weight models (BitNet b1.58).

| Property | Value |
|----------|-------|
| Type ID | 35 |
| File type | 37 (`MOSTLY_TQ2_0`) |
| Block size (QK_K) | 256 elements |
| Block bytes | 66 (64 data + 2 scale) |
| Bits per weight | 2.0625 |
| Encoding | `{-1, 0, +1} → {0, 1, 2}` (unsigned 2-bit) |

## Block Structure

```c
typedef struct {
    uint8_t qs[QK_K/4];   // 64 bytes — 2 bits per element, 4 elements per byte
    ggml_half d;           //  2 bytes — FP16 scale factor (absolute max of block)
} block_tq2_0;             // 66 bytes total
// static_assert: sizeof == sizeof(ggml_half) + QK_K / 4
```

### Bit packing (qs array)

Each byte holds 4 ternary values in 2-bit pairs, packed least-significant first:

```
byte = (q0 & 3) | ((q1 & 3) << 2) | ((q2 & 3) << 4) | ((q3 & 3) << 6)
```

Encoding: `-1 → 0`, `0 → 1`, `+1 → 2` (offset +1 from the ternary value).

### Memory layout within a block (256 elements)

The 64 bytes of `qs` are processed in chunks of 32 bytes. Within each 32-byte chunk, elements are interleaved across 4 groups of 32:

```
qs[0..31]   → elements at positions [0..31], [32..63], [64..95], [96..127]
qs[32..63]  → elements at positions [128..159], [160..191], [192..223], [224..255]
```

Each byte within a chunk encodes 4 elements spaced 32 apart:
- bits [1:0] → position m
- bits [3:2] → position m + 32
- bits [5:4] → position m + 64
- bits [7:6] → position m + 96

### Scale factor (d)

FP16 scalar — the absolute maximum value in the block. Dequantisation:

```
float_value = (q_2bit - 1) * d
```

where `q_2bit ∈ {0, 1, 2}` maps back to `{-1, 0, +1}`.

## Quantisation (encode)

```
amax = max(|x[i]|) for all 256 elements
d = amax
id = 1/d  (or 0 if d == 0)

For each element:
    xi = round(x[i] * id) + 1     // clamps to {0, 1, 2}
    pack xi into 2-bit slot
```

## SIMD Dot Product Kernels

TQ2_0 dot products compute against Q8_K (8-bit quantised activations).

| Architecture | Function | Instruction set |
|-------------|----------|-----------------|
| ARM | `ggml_vec_dot_tq2_0_q8_K` | NEON + optional SDOT |
| x86 | `ggml_vec_dot_tq2_0_q8_K` | AVX2 |
| RISC-V | `ggml_vec_dot_tq2_0_q8_K` | RVV (vl128/vl256) |
| Vulkan | shader pipeline | Compute shaders |
| Fallback | `_generic` | Scalar C |

### ARM NEON kernel strategy

1. Load 32 bytes of `qs` → two `uint8x16_t` registers
2. Shift-and-mask to extract 4 groups of 2-bit values (8 registers)
3. Cast to `int8x16_t` (values 0, 1, 2)
4. Load corresponding Q8_K activations (8 × 16 bytes)
5. Multiply-accumulate with `vdotq_s32` (SDOT) or widening multiply + pairwise add
6. Scale by `d * d_q8` at block boundary

## Comparison: TQ2_0 vs TQ1_0

| | TQ2_0 | TQ1_0 |
|--|-------|-------|
| Type ID | 35 | 34 |
| Encoding | 2-bit pairs | Base-3 packed (5 trits/byte) + high bits |
| bpw | 2.0625 | 1.6875 |
| Block bytes | 66 | 34 |
| Kernel complexity | Simple shift+mask | Base-3 decode (multiply by powers of 3) |
| Maturity | Production kernels on all SIMD | Production kernels on all SIMD |

TQ2_0 trades ~22% more storage for substantially simpler decode and faster kernels.
For a 2.4B model: TQ2_0 = ~1.1GB, TQ1_0 = ~0.9GB. Both fit comfortably in memory.

## Benchmark: TQ2_0 vs i2_s (BitNet b1.58 2B4T, CPU-only, Mac mini M4 Pro)

Measured on a Mac mini M4 Pro, CPU-only (`-ngl 0`; TQ2_0 has no Metal path — the
NEON SIMD path is the fast path). i2_s numbers were measured on our ARM-patched
bitnet.cpp build (NEON i2_s kernels, duplicate-symbol guards) on the same
machine and model; they characterise that patched build and are not asserted
against stock bitnet.cpp.

| Metric | i2_s (bitnet.cpp) | TQ2_0 (mainline llama.cpp) | Speedup |
|--------|-------------------|----------------------------|---------|
| Prompt eval | 12.2 tok/s | 237–279 tok/s | 19–23x |
| Generation | 10.93 tok/s | 89–112 tok/s | 8–10x |
| Model size on disk | 1.1 GB | 1.1 GB | parity |

## Quality (perplexity) — measured on this tree

llama-perplexity, WikiText-2 raw test set (reconstructed from the
Salesforce/wikitext parquet; corpus sha256 `bbf94c53a05abe9e…`), CPU
(`-ngl 0`), substrate = this repo at v0.1.0. Same corpus, commands, and
binary for both columns.

**bf16-equivalent quality at 2.06 bits per weight.**

| n_ctx | bf16 reference | TQ2_0 | relative Δ |
|-------|---------------|-------|-----------|
| 512   | 82.09 ± 0.76  | 82.21 ± 0.77 | +0.15% |
| 2048  | 77.16 ± 0.71  | 77.31 ± 0.71 | +0.19% |

**Quality parity, architecturally grounded:** BitNet b1.58 2B4T is
QAT-trained natively ternary, and TQ2_0 is its native alphabet — quantising
to it costs, measured here, under 0.2% relative perplexity. Absolute values
reflect an instruction-tuned model scored on raw text and are comparable
only within this methodology; the columns share everything but the weights.

## Conversion determinism

A fresh bf16 → TQ2_0 conversion on this tree reproduces the distributed GGUF
**byte-for-byte** (sha256
`9f8e1097502528a0d80d885c603ea7ee3e4d214a6685356e39baaf697c02cbb6`):
the converter is deterministic end-to-end, and the shipped artifact is exactly
what this tree produces from Microsoft's bf16 checkpoint.
