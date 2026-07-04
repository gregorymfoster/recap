#!/bin/bash
# Runs every package's test suite. Extra args pass through to `swift test`
# (e.g. ./Scripts/test.sh --filter LibraryStorage).
#
# Self-heal: after a new source file lands in a shared package (e.g. RecapCore),
# a sibling package's incremental build of that dependency can fail with stale
# "cannot find type/'X' in scope" errors pointing at the *other* package's
# sources, even though the owning package itself builds green. When a
# package's `swift test` fails with that exact signature, we clean the
# implicated package's build artifacts and retry this package's tests once.
# Any other failure (including a second failure after the clean) fails the
# script immediately with the original exit code.
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/lib.sh

acquire_build_lock

# Detects the stale-dependency signature in a captured `swift test` log for
# $1 (the package currently under test). Echoes the name of the OTHER
# package whose sources the error points at, or nothing if the signature
# doesn't match. Returns non-zero when there's no match.
detect_stale_dependency() {
  local testing_pkg="$1" log_file="$2"

  grep -q "cannot find" "$log_file" || return 1

  # Look for an error path under Packages/<other>/Sources where <other> is
  # not the package we're currently testing.
  local other_pkg
  other_pkg="$(grep -oE 'Packages/[A-Za-z0-9_]+/Sources' "$log_file" | \
    sed -E 's#Packages/([A-Za-z0-9_]+)/Sources#\1#' | \
    sort -u | \
    grep -v -x "$testing_pkg" | \
    head -n 1)"

  [[ -n "$other_pkg" ]] || return 1
  printf '%s\n' "$other_pkg"
}

run_package_tests() {
  local pkg="$1"; shift
  local log_file
  log_file="$(mktemp)"

  if swift test --package-path "Packages/$pkg" "$@" 2>&1 | tee "$log_file"; then
    rm -f "$log_file"
    return 0
  fi

  local status=${PIPESTATUS[0]}
  local stale_pkg
  stale_pkg="$(detect_stale_dependency "$pkg" "$log_file" || true)"

  if [[ -n "$stale_pkg" ]]; then
    echo "── SPM stale dependency build detected — cleaning Packages/$stale_pkg and retrying once ──"
    rm -f "$log_file"
    swift package --package-path "Packages/$stale_pkg" clean

    local retry_log
    retry_log="$(mktemp)"
    if swift test --package-path "Packages/$pkg" "$@" 2>&1 | tee "$retry_log"; then
      rm -f "$retry_log"
      return 0
    fi
    local retry_status=${PIPESTATUS[0]}
    rm -f "$retry_log"
    return "$retry_status"
  fi

  rm -f "$log_file"
  return "$status"
}

for pkg in RecapCore RecapAudio RecapTranscription RecapEnhancement RecapUI; do
  echo "── $pkg ──"
  run_package_tests "$pkg" "$@"
done
echo "All package tests passed."
