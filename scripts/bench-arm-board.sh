#!/usr/bin/env bash
# bench-arm-board.sh — TQ2_0 throughput on ARM SBCs (Raspberry Pi 5 class)
# Part of the synapticode-ai/llama.cpp ternary fork. Performance glue only.
#
# Usage:  ./scripts/bench-arm-board.sh /path/to/bitnet-2b4t-tq2_0.gguf
#
# Measures prompt-eval and generation tok/s via llama-bench on the CPU path
# (TQ2_0 executes on NEON SDOT; no GPU/NPU involved). For power-in-frame
# demos, pair with an inline USB-C PD power meter on the board's supply and
# film meter + terminal together during the generation phase; report watts
# observed during generation, board model, PSU, cooling, and ambient.
#
# Build (on the board, from a clean clone of this fork):
#   cmake -B build -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=ON
#   cmake --build build --target llama-bench llama-cli -j$(nproc)
set -euo pipefail
MODEL="${1:?usage: bench-arm-board.sh MODEL.gguf}"
THREADS="${THREADS:-$(nproc)}"

echo "== board =="
uname -m; grep -m1 "^Model" /proc/cpuinfo 2>/dev/null || sysctl -n machdep.cpu.brand_string 2>/dev/null || true
nproc 2>/dev/null || sysctl -n hw.ncpu

echo "== llama-bench (pp512 / tg128, CPU, t=${THREADS}) =="
./build/bin/llama-bench -m "$MODEL" -t "$THREADS" -ngl 0 -p 512 -n 128 -r 3

cat <<'NOTE'
== reporting discipline ==
Publish measured numbers only, hardware always stated (board, RAM, PSU,
cooling, threads). Watts are read from the inline meter during the tg
(generation) phase, in frame. No extrapolated or "up to" figures.
NOTE
