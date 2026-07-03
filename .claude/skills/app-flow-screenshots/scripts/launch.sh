#!/bin/bash
# launch.sh — build and launch Recap Dev for screenshotting.
#
# Usage: launch.sh [-fixtures|-soak] [--skip-build]
#
# Builds Debug into build/screenshots/ (own derived-data path, never collides with
# soak/dev-install builds), launches the raw binary (not `open`, so we get the exact
# PID and multiple sequential launches behave), waits until the main window is on
# screen, then prints APP= and PID=. Kill the PID when done; both modes are safe to
# SIGTERM (-fixtures is disk-free, -soak uses a throwaway temp dir).

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="${1:--fixtures}"
DD=build/screenshots

if [[ "${2:-}" != "--skip-build" ]]; then
  xcodegen
  xcodebuild build -project Recap.xcodeproj -scheme Recap -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$DD" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" | tail -3
fi

APP="$DD/Build/Products/Debug/Recap Dev.app"
EXE=$(defaults read "$PWD/$APP/Contents/Info" CFBundleExecutable)

# Compile the CGEvent input helper once so subagents get a fast binary, not a 2s swift-interpreter hit per event.
if [[ ! -x "$DD/input" || "$SCRIPT_DIR/input.swift" -nt "$DD/input" ]]; then
  swiftc -O -o "$DD/input" "$SCRIPT_DIR/input.swift"
fi

nohup "$APP/Contents/MacOS/$EXE" "$MODE" >/dev/null 2>&1 &
PID=$!

for _ in $(seq 1 30); do
  sleep 1
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "app exited during launch" >&2
    exit 1
  fi
  if "$SCRIPT_DIR/shot.sh" list "Recap Dev" 2>/dev/null | grep -q .; then
    echo "APP=$PWD/$APP"
    echo "PID=$PID"
    echo "INPUT=$PWD/$DD/input"
    exit 0
  fi
done

echo "main window never appeared after 30s" >&2
kill "$PID" 2>/dev/null || true
exit 1
