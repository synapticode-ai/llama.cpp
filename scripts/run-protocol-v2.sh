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
# v2: producer-of-record log, independent of shell history (which the 27 Aug
# audit found absent on this rig, making producing commands unrecoverable).
echo "$(date -Iseconds) ${USER:-?} $$ $0 $*" >> "${HOME}/run.log"

PHASE="${1:?usage: run-protocol.sh t1|t2|t3|t4|t5 [MODEL.gguf ...]}"; shift || true
TS_RUN="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${OUT:-bench_results/protocol_${TS_RUN}.jsonl}"
mkdir -p "$(dirname "$OUT")"
THREADS="${THREADS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu)}"
# --- v2 (2026-08-27 post-audit): hardware metadata is probe-or-UNPROBED.
# Env-var defaults for supply/cable/meter are forbidden: an unset value must
# record UNPROBED, never a plausible-looking default. The 27 Aug audit found
# PSU="${PSU:-reference-27w-official}" stamping a supply label on rows with no
# instrument attached.
PSU="${PSU:-UNPROBED}"
CABLE="${CABLE:-UNPROBED}"
METER="${METER:-UNPROBED}"
COOLING="${COOLING:-UNPROBED}"
REPEATS="${REPEATS:-5}"
GEN_N="${GEN_N:-512}"
SUSTAIN_S="${SUSTAIN_S:-600}"
SUBSTRATE="$(git describe --tags --always 2>/dev/null || echo unknown)"
BOARD="$(grep -m1 '^Model' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ //' || uname -m)"

msrc() { # msrc VARNAME -> default | operator-declared
  if [ -n "${!1+x}" ] && [ "${!1}" != "UNPROBED" ]; then echo "operator-declared"; else echo "default"; fi
}
supply_probe() { # machine-probed supply facts — never a label
  local mc="null" pdo="null" v="null"
  if [ -r /proc/device-tree/chosen/power/max_current ]; then
    mc=$(python3 - <<'PP' 2>/dev/null || echo null
import struct
print(struct.unpack(">I", open("/proc/device-tree/chosen/power/max_current","rb").read())[0])
PP
)
  fi
  if [ -r /proc/device-tree/chosen/power/usbpd_power_data_objects ]; then
    pdo=$(python3 - <<'PP' 2>/dev/null || echo null
b = open("/proc/device-tree/chosen/power/usbpd_power_data_objects","rb").read()
print('"none"' if not any(b) else '"%s"' % b.hex())
PP
)
  fi
  if command -v vcgencmd >/dev/null 2>&1; then
    v=$(vcgencmd pmic_read_adc 2>/dev/null | grep EXT5V_V | sed 's/.*=//; s/V$//')
    [ -z "$v" ] && v="null"
  fi
  printf '"probed_max_current_ma":%s,"probed_usbpd":%s,"probed_ext5v_v":%s' "$mc" "$pdo" "$v"
}
provenance() { # sidecar: how this run was invoked, and what was declared vs defaulted
  local out="$1"; shift
  python3 - "$out" "$PSU" "$CABLE" "$METER" "$COOLING" "$0" "$@" <<'PP'
import json, os, sys, socket, platform, hashlib, datetime
out, psu, cable, meter, cooling, script = sys.argv[1:7]
argv = sys.argv[7:]
try: ssha = hashlib.sha256(open(script,"rb").read()).hexdigest()
except OSError: ssha = None
def state(name, val):
    set_ = name in os.environ and val != "UNPROBED"
    return {"value": val, "probed": False,
            "source": "operator-declared" if set_ else "default",
            "is_measurement": False}
def throttled():
    try:
        import subprocess
        return subprocess.run(["vcgencmd","get_throttled"],capture_output=True,
                              text=True).stdout.strip().split("=")[-1]
    except Exception: return None
def fnb58(path):
    if not path or not os.path.exists(path): return None
    import statistics as st
    w=[]
    for ln in open(path):
        p=ln.split()
        if len(p)>=4:
            try: w.append(float(p[2])*float(p[3]))
            except ValueError: pass
    if not w: return None
    return {"samples":len(w),"mean_w":round(st.mean(w),3),
            "std_w":round(st.pstdev(w),3),"min_w":round(min(w),3),
            "max_w":round(max(w),3),"capture":path}
json.dump({
  "output": out,
  "invoked_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
  "argv": argv, "pid": os.getpid(), "user": os.environ.get("USER"),
  "hostname": socket.gethostname(), "uname": " ".join(platform.uname()),
  "producer_script": script, "producer_sha256": ssha,
  "hardware_metadata": {"PSU": state("PSU", psu), "CABLE": state("CABLE", cable),
                        "METER": state("METER", meter), "COOLING": state("COOLING", cooling)},
  "throttled_at_start": os.environ.get("THROTTLED_START"),
  "throttled_at_end": throttled(),
  "fnb58_window": fnb58(os.environ.get("WATTS_CAPTURE")),
  "output_sha256": (hashlib.sha256(open(out,"rb").read()).hexdigest()
                    if os.path.exists(out) else None),
  "note": "hardware_metadata is probed:false — informational, NOT measurement",
}, open(out + ".provenance.json", "w"), indent=1)
print("  -> " + out + ".provenance.json")
PP
}
sha() { (sha256sum "$1" 2>/dev/null || shasum -a 256 "$1") | cut -d' ' -f1; }
temps() {
  command -v vcgencmd >/dev/null 2>&1 || { echo '"temp_c":null,"throttled":null'; return; }
  local t th
  t=$(vcgencmd measure_temp | grep -oE '[0-9.]+')
  th=$(vcgencmd get_throttled | cut -d= -f2)
  echo "\"temp_c\":${t},\"throttled\":\"${th}\""
}
hdr() { # hdr <test> <model-or-empty>
  local m="$1_model" model="${2:-}" msha="null" mbytes="null"
  if [ -n "$model" ]; then msha="\"$(sha "$model")\""; mbytes=$(stat -c%s "$model" 2>/dev/null || stat -f%z "$model"); fi
  echo "\"ts\":\"$(date -u +%FT%TZ)\",\"test\":\"$1\",\"substrate\":\"${SUBSTRATE}\",\"board\":\"${BOARD}\",\"psu\":{\"value\":\"${PSU}\",\"probed\":false,\"source\":\"$(msrc PSU)\"},\"cable\":{\"value\":\"${CABLE}\",\"probed\":false,\"source\":\"$(msrc CABLE)\"},\"meter\":{\"value\":\"${METER}\",\"probed\":false,\"source\":\"$(msrc METER)\"},\"supply_probed\":{$(supply_probe),\"probed\":true,\"source\":\"instrument\"},\"cooling\":\"${COOLING}\",\"threads\":${THREADS},\"model\":\"${model}\",\"model_sha256\":${msha},\"model_bytes\":${mbytes}"
}
ask_watts() { # ask_watts <label>  -> echoes number
  local w
  if [ -n "${WATTS_CAPTURE:-}" ] && [ -r "${WATTS_CAPTURE}" ]; then
    w=$(python3 - "${WATTS_CAPTURE}" <<'PP'
import sys, statistics as st
r = []
for ln in open(sys.argv[1]):
    p = ln.split()
    if len(p) >= 4:
        try: r.append(float(p[2]) * float(p[3]))
        except ValueError: pass
print(f"{st.median(r):.3f}" if r else "")
PP
)
    WATTS_SOURCE="fnb58_capture"
  else
    read -rp "FNB58 ${1} watts (OPERATOR READ, not instrument-probed): " w
    WATTS_SOURCE="operator_read"
  fi
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
    J=$(./build/bin/llama-bench -m "$MODEL" -t "$THREADS" -ngl 0 -p 512 -n 128 -r "$REPEATS" -o json </dev/null | tr -d "\n")
    rec "$(hdr t2_bench "$MODEL")","$(temps)",\"repeats\":$REPEATS,\"llama_bench\":"$J"
  done
  ;;
t3)
  for MODEL in "$@"; do
    echo "== T3 sustained generation + power : $MODEL =="
    echo "Generation starts now; read FNB58 at ~60s in, steady state."
    T0=$(temps)
    START=$(date +%s)
    LOG=$(./build/bin/llama-completion -m "$MODEL" -t "$THREADS" -ngl 0 -c 4096 -no-cnv -n "$GEN_N" --ignore-eos \
      -p "Write a detailed field guide to the birds of northern Australia." \
      --no-display-prompt </dev/null 2>&1 >/dev/null | grep -E "eval time|sampl" || true)
    DUR=$(( $(date +%s) - START ))
    W=$(ask_watts "sustained-generation")
    TGS=$(echo "$LOG" | grep -oE '[0-9.]+ tokens per second' | tail -1 | grep -oE '^[0-9.]+' || echo null)
    rec "$(hdr t3_power "$MODEL")",$T0,\"gen_tokens\":$GEN_N,\"duration_s\":$DUR,\"tg_tok_s\":${TGS:-null},\"watts\":$W
    echo "   tokens/joule and Wh/1k tokens derive offline: tg_tok_s / watts."
  done
  ;;
t4)
  MODEL="${1:?t4 needs one model}"
  echo "== T4 thermal sustain 10 min : $MODEL =="
  END=$(( $(date +%s) + SUSTAIN_S ))
  ( while [ "$(date +%s)" -lt "$END" ]; do
      echo "{\"ts\":\"$(date -u +%FT%TZ)\",\"test\":\"t4_thermal_sample\",$(temps)}" >> "$OUT"
      sleep 10
    done ) &
  SAMPLER=$!
  N=0
  while [ "$(date +%s)" -lt "$END" ]; do
    L=$(./build/bin/llama-completion -m "$MODEL" -t "$THREADS" -ngl 0 -c 4096 -no-cnv -n 256 --ignore-eos \
        -p "Continue the story." --no-display-prompt </dev/null 2>&1 >/dev/null | grep "eval time" | tail -1)
    TGS=$(echo "$L" | grep -oE '[0-9.]+ tokens per second' | grep -oE '^[0-9.]+' || echo null)
    echo "{$(hdr t4_thermal_gen "$MODEL"),$(temps),\"segment\":$((N+=1)),\"tg_tok_s\":${TGS:-null}}" >> "$OUT"
  done
  kill "$SAMPLER" 2>/dev/null || true
  echo "T4 done — any non-zero throttled flag in the samples is disclosed, not edited out."
  ;;
t5)
  for MODEL in "$@"; do
    echo "== T5 memory + load : $MODEL =="
    sync; if [ -e /proc/sys/vm/drop_caches ]; then sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'; else echo "(no drop_caches on this OS: cold-load is warm-cache — disclose)"; fi
    if /usr/bin/time -v true >/dev/null 2>&1; then TV="-v"; else TV="-l"; fi
    START=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
    /usr/bin/time "$TV" ./build/bin/llama-completion -m "$MODEL" -t "$THREADS" -ngl 0 -c 4096 -no-cnv -n 8 \
      -p "hi" --no-display-prompt </dev/null >/dev/null 2> /tmp/t5_time.txt || true
    LOAD=$(perl -MTime::HiRes=time -e "printf \"%.3f\", time - $START")
    RSS=$(grep -iE "maximum resident" /tmp/t5_time.txt | grep -oE '[0-9]+' | head -1 || echo null)
    # normalise to kb at capture: GNU time -v reports kbytes, BSD -l bytes
    if [ "$TV" = "-l" ] && [ "$RSS" != "null" ] && [ -n "$RSS" ]; then RSS=$((RSS / 1024)); fi
    rec "$(hdr t5_memload "$MODEL")","$(temps)",\"cold_load_s\":$LOAD,\"peak_rss_kb\":${RSS:-null}
  done
  echo "Max usable context: raise -c stepwise with llama-cli until allocation fails; record last-good."
  ;;
*) echo "unknown phase: $PHASE"; exit 1;;
esac

echo "== reporting discipline =="
echo "Median-of-${REPEATS} with spread; thermals + substrate pinned in-record;"
echo "raw JSONL archived to the evidence pack; claims follow the measured table only."
