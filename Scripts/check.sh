#!/bin/bash
# The single agent verification gate. Fast tier by default; --full adds the
# app-shell xcodebuild. Always prints exactly one JSON object as the LAST
# line of stdout summarizing the result, mirroring the probe --json
# convention documented in CLAUDE.md.
#
# Usage:
#   ./Scripts/check.sh            # fast tier: lint + package tests
#   ./Scripts/check.sh --full     # fast tier + xcodegen/xcodebuild app build
#   ./Scripts/check.sh --ui       # no-op placeholder for a future ui-smoke tier
set -uo pipefail
cd "$(dirname "$0")/.."
source Scripts/lib.sh

full=0
for arg in "$@"; do
  case "$arg" in
    --full) full=1 ;;
    --ui) ;; # placeholder, no-op for now
    *)
      echo "unknown argument: $arg" >&2
      echo "usage: $0 [--full] [--ui]" >&2
      exit 64
      ;;
  esac
done

start_time=$(date +%s)

lint_ok=true
packages_ok=true
app_build_ok=null

echo "── lint ──"
if ! Scripts/lint.sh; then
  lint_ok=false
fi

if [[ "$lint_ok" == "true" ]]; then
  echo "── package tests ──"
  if ! Scripts/test.sh; then
    packages_ok=false
  fi
else
  echo "── package tests skipped (lint failed) ──"
  packages_ok=false
fi

if [[ "$full" -eq 1 ]]; then
  echo "── app build (--full) ──"
  if [[ "$lint_ok" == "true" && "$packages_ok" == "true" ]]; then
    app_build_ok=true
    if ! acquire_build_lock; then
      app_build_ok=false
    else
      if ! xcodegen; then
        app_build_ok=false
      elif ! xcodebuild build -project Recap.xcodeproj -scheme Recap \
        -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=""; then
        app_build_ok=false
      fi
      release_build_lock
    fi
  else
    echo "── app build skipped (fast tier failed) ──"
    app_build_ok=false
  fi
fi

end_time=$(date +%s)
seconds=$((end_time - start_time))

tier="fast"
if [[ "$full" -eq 1 ]]; then
  tier="full"
fi

ok=false
if [[ "$lint_ok" == "true" && "$packages_ok" == "true" ]]; then
  if [[ "$full" -eq 0 ]]; then
    ok=true
  elif [[ "$app_build_ok" == "true" ]]; then
    ok=true
  fi
fi

printf '{"ok":%s,"tier":"%s","lint":%s,"packages":%s,"appBuild":%s,"seconds":%s}\n' \
  "$ok" "$tier" "$lint_ok" "$packages_ok" "$app_build_ok" "$seconds"

if [[ "$ok" == "true" ]]; then
  exit 0
else
  exit 1
fi
