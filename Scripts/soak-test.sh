#!/bin/bash
# Launches the real app in `-soak` mode (synthetic audio, no hardware, no
# transcription) and samples CPU/memory for ~30s, failing on a runaway
# main-thread loop (e.g. the MenuBarExtra re-render freeze). Not run per-PR
# — see the `soak-test` CI job (nightly + workflow_dispatch).
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/lib.sh

CPU_MAX=70
MEM_GROWTH_MAX_MB=600
WARMUP_SECONDS=8
SAMPLE_INTERVAL=2
SAMPLE_COUNT=12

acquire_build_lock
xcodegen
xcodebuild build -project Recap.xcodeproj -scheme Recap -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/soak \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" | tail -3
release_build_lock

APP="build/soak/Build/Products/Debug/Recap Dev.app"
EXE=$(defaults read "$PWD/$APP/Contents/Info" CFBundleExecutable)

"$APP/Contents/MacOS/$EXE" -soak >/dev/null 2>&1 &
PID=$!
trap 'kill "$PID" 2>/dev/null || true' EXIT

echo "Launched PID $PID, warming up ${WARMUP_SECONDS}s..."
sleep "$WARMUP_SECONDS"

if ! kill -0 "$PID" 2>/dev/null; then
  echo "FAIL: app exited during warmup"
  exit 1
fi

read -r baseline_cpu baseline_rss < <(ps -o %cpu=,rss= -p "$PID")
echo "baseline rss=$((baseline_rss / 1024))MB"

over_limit=0
peak_cpu="0"
final_rss="$baseline_rss"
elapsed=0

for i in $(seq 1 "$SAMPLE_COUNT"); do
  sleep "$SAMPLE_INTERVAL"
  elapsed=$((elapsed + SAMPLE_INTERVAL))

  if ! kill -0 "$PID" 2>/dev/null; then
    echo "FAIL: app exited during soak (t+${elapsed}s)"
    exit 1
  fi

  read -r cpu rss < <(ps -o %cpu=,rss= -p "$PID")
  rss_mb=$((rss / 1024))
  echo "t+${elapsed}s cpu=${cpu}% rss=${rss_mb}MB"

  if (($(echo "$cpu > $CPU_MAX" | bc -l))); then
    over_limit=$((over_limit + 1))
  fi
  if (($(echo "$cpu > $peak_cpu" | bc -l))); then
    peak_cpu="$cpu"
  fi
  final_rss="$rss"
done

mem_growth_mb=$(((final_rss - baseline_rss) / 1024))

if [ "$over_limit" -gt 1 ]; then
  echo "FAIL: $over_limit/$SAMPLE_COUNT samples exceeded CPU_MAX=${CPU_MAX}%"
  exit 1
fi

if [ "$mem_growth_mb" -gt "$MEM_GROWTH_MAX_MB" ]; then
  echo "FAIL: memory grew ${mem_growth_mb}MB (max ${MEM_GROWTH_MAX_MB}MB)"
  exit 1
fi

echo "PASS: peak cpu ${peak_cpu}%, mem growth ${mem_growth_mb}MB over ${elapsed}s"
