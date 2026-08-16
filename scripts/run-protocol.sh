#!/usr/bin/env bash
# run-protocol.sh — Pi 5 benchmark protocol, public lane (T1–T6)
# Part of the synapticode-ai/llama.cpp ternary fork.
#
# Every record is one JSON line in $OUT with a common header: timestamp,
# substrate tag, board, PSU, cooling, threads, model file + sha256, plus
# vcgencmd temperature and throttle flags sampled around the run. Board
# power is read by the operator from the inline FNB58 USB meter (in frame
# on camera) and typed in when prompted — it lands in the same record.
#
# Usage:
#   ./scripts/run-protocol.sh t1                       # boot/idle baseline
#   ./scripts/run-protocol.sh t2 MODEL.gguf [...]      # llama-bench pp512/tg128
#   ./scripts/run-protocol.sh t3 MODEL.gguf [...]      # sustained-gen power
#   ./scripts/run-protocol.sh t4 MODEL.gguf            # 10-min thermal sustain
#   ./scripts/run-protocol.sh t5 MODEL.gguf [...]      # memory + load
#   PSU=apple61w ./scripts/run-protocol.sh t3 MODEL... # T6 envelope repeat
#
# Env: OUT (default bench_results/protocol_<ts>.jsonl), THREADS, PSU,
#      COOLING, REPEATS (default 5).
set -euo pipefail

PHASE="${1:?usage: run-protocol.sh t1|t2|t3|t4|t5 [MODEL.gguf ...]}"; shift || true
TS_RUN="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${OUT:-bench_results/protocol_${TS_RUN}.jsonl}"
mkdir -p "$(dirname "$OUT")"
THREADS="${THREADS:-$(nproc)}"
PSU="${PSU:-reference-27w-official}"
COOLING="${COOLING:-active-cooler}"
REPEATS="${REPEATS:-5}"
SUBSTRATE="$(git describe --tags --always 2>/dev/null || echo unknown)"
BOARD="$(grep -m1 '^Model' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ //' || uname -m)"

sha() { sha256sum "$1" | cut -d' ' -f1; }
temps() {
  command -v vcgencmd >/dev/null 2>&1 || { echo '"temp_c":null,"throttled":null'; return; }
  local t th
  t=$(vcgencmd measure_temp | grep -oE '[0-9.]+')
  th=$(vcgencmd get_throttled | cut -d= -f2)
  echo "\"temp_c\":${t},\"throttled\":\"${th}\""
}
hdr() { # hdr <test> <model-or-empty>
  local m="$1_model" model="${2:-}" msha="null" mbytes="null"
  if [ -n "$model" ]; then msha="\"$(sha "$model")\""; mbytes=$(stat -c%s "$model"); fi
  echo "\"ts\":\"$(date -u +%FT%TZ)\",\"test\":\"$1\",\"substrate\":\"${SUBSTRATE}\",\"board\":\"${BOARD}\",\"psu\":\"${PSU}\",\"cooling\":\"${COOLING}\",\"threads\":${THREADS},\"model\":\"${model}\",\"model_sha256\":${msha},\"model_bytes\":${mbytes}"
}
ask_watts() { # ask_watts <label>  -> echoes number
  local w
  read -rp "FNB58 ${1} watts (read meter, type number): " w
  echo "$w"
}
rec() { echo "{$*}" >> "$OUT"; echo "  -> $OUT"; }

case "$PHASE" in
t1)
  echo "== T1 virgin-bytes boot / idle baseline =="
  echo "Radios off, Ethernet only, camera rolling on FNB58, 5-minute settle."
  read -rp "Press enter when the 5-minute settle is complete..."
  W=$(ask_watts "idle")
  rec "$(hdr t1_idle)","$(temps)",\"idle_watts\":$W,\"settle_min\":5
  ;;
t2)
  for MODEL in "$@"; do
    echo "== T2 llama-bench pp512/tg128 : $MODEL =="
    J=$(./build/bin/llama-bench -m "$MODEL" -t "$THREADS" -ngl 0 -p 512 -n 128 -r "$REPEATS" -o json)
    rec "$(hdr t2_bench "$MODEL")","$(temps)",\"repeats\":$REPEATS,\"llama_bench\":"$J"
  done
  ;;
t3)
  for MODEL in "$@"; do
    echo "== T3 sustained generation + power : $MODEL =="
    echo "Generation starts now; read FNB58 at ~60s in, steady state."
    T0=$(temps)
    START=$(date +%s)
    LOG=$(./build/bin/llama-cli -m "$MODEL" -t "$THREADS" -ngl 0 -n 512 --ignore-eos \
      -p "Write a detailed field guide to the birds of northern Australia." \
      --no-display-prompt 2>&1 >/dev/null | grep -E "eval time|sampl" || true)
    DUR=$(( $(date +%s) - START ))
    W=$(ask_watts "sustained-generation")
    TGS=$(echo "$LOG" | grep -oE '[0-9.]+ tokens per second' | tail -1 | grep -oE '^[0-9.]+' || echo null)
    rec "$(hdr t3_power "$MODEL")",$T0,\"gen_tokens\":512,\"duration_s\":$DUR,\"tg_tok_s\":${TGS:-null},\"watts\":$W
    echo "   tokens/joule and Wh/1k tokens derive offline: tg_tok_s / watts."
  done
  ;;
t4)
  MODEL="${1:?t4 needs one model}"
  echo "== T4 thermal sustain 10 min : $MODEL =="
  END=$(( $(date +%s) + 600 ))
  ( while [ "$(date +%s)" -lt "$END" ]; do
      echo "{\"ts\":\"$(date -u +%FT%TZ)\",\"test\":\"t4_thermal_sample\",$(temps)}" >> "$OUT"
      sleep 10
    done ) &
  SAMPLER=$!
  N=0
  while [ "$(date +%s)" -lt "$END" ]; do
    L=$(./build/bin/llama-cli -m "$MODEL" -t "$THREADS" -ngl 0 -n 256 --ignore-eos \
        -p "Continue the story." --no-display-prompt 2>&1 >/dev/null | grep "eval time" | tail -1)
    TGS=$(echo "$L" | grep -oE '[0-9.]+ tokens per second' | grep -oE '^[0-9.]+' || echo null)
    echo "{$(hdr t4_thermal_gen "$MODEL"),$(temps),\"segment\":$((N+=1)),\"tg_tok_s\":${TGS:-null}}" >> "$OUT"
  done
  kill "$SAMPLER" 2>/dev/null || true
  echo "T4 done — any non-zero throttled flag in the samples is disclosed, not edited out."
  ;;
t5)
  for MODEL in "$@"; do
    echo "== T5 memory + load : $MODEL =="
    sync; command -v sudo >/dev/null && sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches' || echo "(no sudo: cold-load is warm-cache — disclose)"
    START=$(date +%s.%N)
    /usr/bin/time -v ./build/bin/llama-cli -m "$MODEL" -t "$THREADS" -ngl 0 -n 8 \
      -p "hi" --no-display-prompt >/dev/null 2> /tmp/t5_time.txt || true
    LOAD=$(echo "$(date +%s.%N) - $START" | bc)
    RSS=$(grep "Maximum resident" /tmp/t5_time.txt | grep -oE '[0-9]+' || echo null)
    rec "$(hdr t5_memload "$MODEL")","$(temps)",\"cold_load_s\":$LOAD,\"peak_rss_kb\":${RSS:-null}
  done
  echo "Max usable context: raise -c stepwise with llama-cli until allocation fails; record last-good."
  ;;
*) echo "unknown phase: $PHASE"; exit 1;;
esac

echo "== reporting discipline =="
echo "Median-of-${REPEATS} with spread; thermals + substrate pinned in-record;"
echo "raw JSONL archived to the evidence pack; claims follow the measured table only."
