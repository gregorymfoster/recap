#!/bin/bash
# Runs every package's test suite. Extra args pass through to `swift test`
# (e.g. ./Scripts/test.sh --filter LibraryStorage).
set -euo pipefail
cd "$(dirname "$0")/.."
for pkg in RecapCore RecapAudio RecapTranscription RecapEnhancement RecapUI; do
  echo "── $pkg ──"
  swift test --package-path "Packages/$pkg" "$@"
done
echo "All package tests passed."
