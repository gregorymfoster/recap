#!/bin/bash
# Grep-based house-rule checks from CLAUDE.md's Conventions section. Fast
# (<1s), no external deps beyond standard macOS tools (grep, awk, find).
#
# BLOCKING checks (exit 1 on any hit):
#   - Swift Testing only: no `import XCTest` / `XCTAssert` under Recap/ or
#     Packages/*/Sources or Packages/*/Tests.
#   - No new `@unchecked Sendable` / `nonisolated(unsafe)` without an
#     explaining comment within 2 lines above or below.
#   - No `ProcessInfo.processInfo.environment` under Recap/ or
#     Packages/*/Sources (probe/eval executables are allowlisted).
#
# ADVISORY checks (printed, never affect exit code):
#   - Any .swift source file > 600 lines.
#   - Total lines of Recap/*.swift > 350.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0

# Swift source roots we care about, excluding build artifacts / tooling dirs.
find_swift_sources() {
  find Recap Packages \
    \( -path '*/.build/*' -o -path '*/.claude/*' -o -path '*/build/*' -o -path '*/.swiftpm/*' \) -prune -o \
    -type f -name '*.swift' -print 2>/dev/null
}

find_swift_sources_and_tests() {
  find_swift_sources | grep -E '^(Recap/|Packages/[^/]+/(Sources|Tests)/)'
}

swift_files="$(find_swift_sources)"

# --- BLOCKING: Swift Testing only ---
xctest_hits=""
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  matches="$(grep -n -E 'import XCTest|XCTAssert' "$f" 2>/dev/null || true)"
  if [[ -n "$matches" ]]; then
    while IFS= read -r m; do
      [[ -z "$m" ]] && continue
      xctest_hits+="${f}:${m}"$'\n'
    done <<< "$matches"
  fi
done <<< "$(find_swift_sources_and_tests)"

if [[ -n "$xctest_hits" ]]; then
  echo "BLOCKING: Swift Testing only — zero XCTest, keep it that way (CLAUDE.md Conventions)"
  printf '%s' "$xctest_hits" | sed -E 's/^([^:]+:[0-9]+):(.*)$/  \1: \2/'
  fail=1
fi

# --- BLOCKING: @unchecked Sendable / nonisolated(unsafe) needs adjacent comment ---
#
# Consecutive escape-hatch lines (e.g. a `nonisolated(unsafe) var fed` /
# `nonisolated(unsafe) let input` pair covered by one shared explanation)
# are treated as a single block: the window is measured from the block's
# first and last line, not from each line individually, since a comment
# sitting between two such lines (or just above/below the block) explains
# the whole block.
escape_hatch_hits=""
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  hit_lines="$(awk '
    /@unchecked[ \t]+Sendable/ || /nonisolated\(unsafe\)/ { print NR }
  ' "$f")"
  [[ -z "$hit_lines" ]] && continue

  # Group consecutive (or adjacent-by-1, to allow a one-line gap within a
  # block) hit lines into blocks: block_start block_end pairs.
  blocks="$(awk '
    { lines[NR] = $1 }
    END {
      n = NR
      if (n == 0) { exit }
      start = lines[1]; prev = lines[1]
      for (i = 2; i <= n; i++) {
        cur = lines[i]
        if (cur - prev <= 1) {
          prev = cur
          continue
        }
        print start, prev
        start = cur; prev = cur
      }
      print start, prev
    }
  ' <<< "$hit_lines")"

  while IFS=' ' read -r block_start block_end; do
    [[ -z "$block_start" ]] && continue
    has_comment=$(awk -v bstart="$block_start" -v bend="$block_end" -v window=2 '
      NR >= bstart - window && NR <= bend + window && /\/\// { found = 1 }
      END { print found ? "1" : "0" }
    ' "$f")
    if [[ "$has_comment" != "1" ]]; then
      for ((ln = block_start; ln <= block_end; ln++)); do
        line_text="$(sed -n "${ln}p" "$f")"
        escape_hatch_hits+="${f}:${ln}:${line_text}"$'\n'
      done
    fi
  done <<< "$blocks"
done <<< "$swift_files"

if [[ -n "$escape_hatch_hits" ]]; then
  echo "BLOCKING: no new @unchecked Sendable / nonisolated(unsafe) without a comment explaining why it's safe (CLAUDE.md Conventions)"
  printf '%s' "$escape_hatch_hits" | sed -E 's/^([^:]+:[0-9]+):(.*)$/  \1: \2/'
  fail=1
fi

# --- BLOCKING: no ProcessInfo.processInfo.environment outside allowlisted probes/evals ---
env_hits=""
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  # Allowlist probe/eval executable targets: Sources/*Probe*/ or Sources/*Eval*/
  if [[ "$f" =~ Sources/[^/]*(Probe|Eval)[^/]*/ ]]; then
    continue
  fi
  matches="$(grep -n 'ProcessInfo.processInfo.environment' "$f" 2>/dev/null || true)"
  if [[ -n "$matches" ]]; then
    while IFS= read -r m; do
      [[ -z "$m" ]] && continue
      env_hits+="${f}:${m}"$'\n'
    done <<< "$matches"
  fi
done <<< "$(find_swift_sources | grep -E '^(Recap/|Packages/[^/]+/Sources/)')"

if [[ -n "$env_hits" ]]; then
  echo "BLOCKING: ProcessInfo.processInfo.environment not allowed outside probe/eval targets (CLAUDE.md Conventions)"
  printf '%s' "$env_hits" | sed -E 's/^([^:]+:[0-9]+):(.*)$/  \1: \2/'
  fail=1
fi

# --- ADVISORY: file length ---
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  lines=$(wc -l < "$f" | tr -d ' ')
  if [[ "$lines" -gt 600 ]]; then
    echo "warning: $f is $lines lines — token hotspot, consider splitting"
  fi
done <<< "$swift_files"

# --- ADVISORY: app shell size ---
if [[ -d Recap ]]; then
  app_total=$(find Recap -maxdepth 1 -type f -name '*.swift' -exec cat {} + 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$app_total" -gt 350 ]]; then
    echo "warning: Recap/*.swift totals $app_total lines — keep logic out of the app shell"
  fi
fi

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi

echo "lint: OK"
