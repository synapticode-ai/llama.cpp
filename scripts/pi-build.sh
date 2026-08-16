#!/usr/bin/env bash
# pi-build.sh — Raspberry Pi 5 build of the synapticode-ai/llama.cpp ternary
# fork, PINNED to the v0.1.0 release tag. Run on the board.
#
#   git clone https://github.com/synapticode-ai/llama.cpp.git && cd llama.cpp
#   ./scripts/pi-build.sh
#
# The pin is the point: every published number names its substrate, and the
# substrate is this tag, not a moving branch.
set -euo pipefail

TAG="${TAG:-v0.1.0}"
git fetch --tags origin
git checkout "$TAG"
echo "substrate: $(git describe --tags --always) ($(git rev-parse --short HEAD))"

sudo apt-get update -qq && sudo apt-get install -y -qq build-essential cmake libcurl4-openssl-dev time bc

cmake -B build -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=ON -DLLAMA_CURL=OFF
cmake --build build --target llama-bench llama-cli llama-server llama-tokenize -j"$(nproc)"

echo "== binaries =="
ls -la build/bin/llama-{bench,cli,server}
echo "== sanity =="
./build/bin/llama-bench --help >/dev/null && echo "llama-bench OK"
echo "Build pinned to ${TAG}. Next: scripts/run-protocol.sh t1"
