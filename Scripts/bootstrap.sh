#!/bin/bash
# Generate Recap.xcodeproj and open it. Run after cloning and whenever
# files are added to the app target (Recap/).
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null; then
  echo "xcodegen not found — install with: brew install xcodegen" >&2
  exit 1
fi

git config core.hooksPath .githooks

xcodegen
echo "Generated Recap.xcodeproj"

if [[ "${1:-}" != "--no-open" ]]; then
  open Recap.xcodeproj
fi
