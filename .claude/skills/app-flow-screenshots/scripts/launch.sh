#!/bin/bash
# launch.sh — build and launch Recap Dev for screenshotting.
#
# Usage: launch.sh [--skip-build] [<app-args>...]
#   launch.sh -fixtures
#   launch.sh -fixtures recording --skip-build
#   launch.sh -fixtures -show-menubar-content
#
# All arguments except --skip-build are forwarded verbatim to the app, so
# multi-arg launches (`-fixtures <scenario>`, `-fixtures -show-nudge`) work.
# Defaults to `-fixtures` when no app args are given.
#
# Builds Debug into build/screenshots/ (own derived-data path, never collides with
# soak/dev-install builds), launches via `open -n` (raw-exec'd binaries sometimes
# never register with the window server on this host — see root CLAUDE.md), waits
# until the main window is on screen, then prints APP= and PID=. Kill the PID when
# done; fixture modes are disk-free and -soak uses a throwaway temp dir.

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DD=build/screenshots
SKIP_BUILD=0
APP_ARGS=()
for arg in "$@"; do
  if [[ "$arg" == "--skip-build" ]]; then
    SKIP_BUILD=1
  else
    APP_ARGS+=("$arg")
  fi
done
if [[ ${#APP_ARGS[@]} -eq 0 ]]; then
  APP_ARGS=(-fixtures)
fi

if [[ "$SKIP_BUILD" -eq 0 ]]; then
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

# `open -n` detaches, so discover the new PID by diffing the executable's PID
# set from before the launch (same pattern as Scripts/ui-smoke.sh).
before_pids="$(pgrep -x "$EXE" 2>/dev/null || true)"
open -n "$PWD/$APP" --args "${APP_ARGS[@]}"

PID=""
for _ in $(seq 1 30); do
  sleep 1
  for candidate in $(pgrep -x "$EXE" 2>/dev/null || true); do
    if ! grep -qx "$candidate" <<<"$before_pids"; then
      PID="$candidate"
      break
    fi
  done
  if [[ -n "$PID" ]] && "$SCRIPT_DIR/shot.sh" list "Recap Dev" 2>/dev/null | grep -q .; then
    echo "APP=$PWD/$APP"
    echo "PID=$PID"
    echo "INPUT=$PWD/$DD/input"
    exit 0
  fi
done

echo "main window never appeared after 30s" >&2
[[ -n "$PID" ]] && kill "$PID" 2>/dev/null || true
exit 1
