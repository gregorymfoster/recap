#!/bin/bash
# ui-smoke.sh — agent-runnable UI smoke test.
#
# Builds (or reuses) the Debug app, launches it with `-fixtures
# -show-menubar-content`, waits for the main window, asserts a fixed list of
# core AXIDs resolve via ax-probe, screenshots the main window, then kills the
# app. Wired into `Scripts/check.sh --ui`.
#
# Usage:
#   ./Scripts/ui-smoke.sh                  # build into an isolated derived-data path, then run
#   ./Scripts/ui-smoke.sh --app <path>     # skip building, launch this .app bundle instead
#   ./Scripts/ui-smoke.sh --skip-build     # skip building, reuse the last build at build/ui-smoke
#
# Output: human-readable lines per assertion, then exactly one JSON object as
# the LAST line of stdout:
#   {"ok":bool,"found":N,"missing":["id", ...],"seconds":S}
# Exit codes: 0 pass, 1 failure/assertion miss, 5 ax-probe reports missing
# Accessibility/Screen Recording TCC (its fix-it text is printed), 64 usage.
set -uo pipefail
cd "$(dirname "$0")/.."
source Scripts/lib.sh

DD="build/ui-smoke"
APP_PATH=""
SKIP_BUILD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      APP_PATH="${2:-}"
      if [[ -z "$APP_PATH" ]]; then
        echo "--app requires a path" >&2
        exit 64
      fi
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    *)
      echo "unknown argument: $1" >&2
      echo "usage: $0 [--app <path>] [--skip-build]" >&2
      exit 64
      ;;
  esac
done

start_time=$(date +%s)

AXPROBE_BIN=".build/release/ax-probe"
echo "── building ax-probe ──"
if ! swift build -c release --package-path Tools/AXProbe; then
  echo "FAIL: ax-probe build failed"
  exit 1
fi
AXPROBE="Tools/AXProbe/$AXPROBE_BIN"

if [[ -z "$APP_PATH" && "$SKIP_BUILD" -eq 0 ]]; then
  echo "── building app (Debug, isolated derived data) ──"
  if ! acquire_build_lock; then
    echo "FAIL: could not acquire build lock"
    exit 1
  fi
  if ! xcodegen; then
    release_build_lock
    echo "FAIL: xcodegen failed"
    exit 1
  fi
  if ! xcodebuild build -project Recap.xcodeproj -scheme Recap -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$DD" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" | tail -3; then
    release_build_lock
    echo "FAIL: app build failed"
    exit 1
  fi
  release_build_lock
fi

if [[ -z "$APP_PATH" ]]; then
  APP_PATH="$DD/Build/Products/Debug/Recap Dev.app"
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "FAIL: app bundle not found at $APP_PATH"
  exit 1
fi

EXE=$(defaults read "$PWD/$APP_PATH/Contents/Info" CFBundleExecutable)
BIN="$APP_PATH/Contents/MacOS/$EXE"

if [[ ! -x "$BIN" ]]; then
  echo "FAIL: executable not found at $BIN"
  exit 1
fi

echo "── launching $BIN -fixtures -show-menubar-content ──"
"$BIN" -fixtures -show-menubar-content >/dev/null 2>&1 &
PID=$!

cleanup() {
  kill "$PID" 2>/dev/null || true
}
trap cleanup EXIT

# Wait for the main window to appear (poll ax-probe windows --pid).
echo "── waiting for main window (pid $PID) ──"
window_ready=0
for _ in $(seq 1 30); do
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "FAIL: app exited before showing a window"
    exit 1
  fi
  windows_json="$("$AXPROBE" windows --pid "$PID" --json 2>/dev/null | tail -1)"
  exit_code=$?
  if [[ "$exit_code" -eq 5 ]]; then
    echo "FAIL: ax-probe reports missing Accessibility/Screen Recording permission:"
    echo "$windows_json"
    exit 5
  fi
  if echo "$windows_json" | grep -q '"ok":true' && ! echo "$windows_json" | grep -q '"windows":\[\]'; then
    window_ready=1
    break
  fi
  sleep 1
done

if [[ "$window_ready" -eq 0 ]]; then
  echo "FAIL: main window never appeared after 30s"
  exit 1
fi

echo "── asserting AXIDs ──"
# Fixed list of core AXIDs, per feature area. All are expected to resolve in
# the default -fixtures launch state (no interaction needed): the app opens
# straight to the Library list with no meeting selected, so `library-detail-pane`
# is asserted only after clicking into a fixture meeting row below.
#
# `root-view` is dropped: SwiftUI's NavigationSplitView appends its own
# generated identifier onto the AXSplitGroup's AXIdentifier attribute
# alongside `.axID(.rootView)`'s "root-view" (observed as
# "main-AppWindow-1, SidebarNavigationSplitView" in the AX tree) — it never
# resolves to a plain "root-view" match. Same underlying element is reachable
# indirectly via the window list instead (asserted as part of the
# wait-for-main-window step above).
ids=(
  sidebar
  library-list
  search-field
  queue-widget
  menu-bar-content
)

found=0
missing=()
for id in "${ids[@]}"; do
  if out="$("$AXPROBE" find "$id" --pid "$PID" --json 2>/dev/null | tail -1)"; then
    if echo "$out" | grep -q '"ok":true'; then
      echo "PASS: $id"
      found=$((found + 1))
      continue
    fi
  fi
  echo "FAIL: $id not found"
  missing+=("$id")
done

# `library-detail-pane` only exists once a meeting is selected. Find the first
# fixture meeting row in the AX tree and click it, then assert the detail pane.
tree_json="$("$AXPROBE" tree --pid "$PID" --depth 25 --json 2>/dev/null | tail -1)"
row_id="$(python3 -c "
import json, sys
def walk(node):
    ident = node.get('identifier')
    if isinstance(ident, str) and ident.startswith('meeting-row-'):
        return ident
    for child in node.get('children', []):
        found = walk(child)
        if found:
            return found
    return None
try:
    data = json.loads(sys.argv[1])
    row = walk(data.get('tree', {}))
    print(row or '')
except Exception:
    print('')
" "$tree_json" 2>/dev/null)"

if [[ -n "$row_id" ]]; then
  # Click twice: on launch, the auxiliary -show-menubar-content debug window
  # can race the main Library window for key-window status. A click on a
  # non-key window's screen coordinates only brings it forward (the click
  # itself doesn't land on the target) — the second click, now that Library
  # is key, reliably lands on the row.
  "$AXPROBE" click "$row_id" --pid "$PID" --json >/dev/null 2>&1
  sleep 0.5
  "$AXPROBE" click "$row_id" --pid "$PID" --json >/dev/null 2>&1
  sleep 1
  if out="$("$AXPROBE" find library-detail-pane --pid "$PID" --json 2>/dev/null | tail -1)" && echo "$out" | grep -q '"ok":true'; then
    echo "PASS: library-detail-pane"
    found=$((found + 1))
  else
    echo "FAIL: library-detail-pane not found after selecting a meeting"
    missing+=("library-detail-pane")
  fi
else
  echo "FAIL: no meeting-row-* found in AX tree to click for library-detail-pane"
  missing+=("library-detail-pane")
fi

echo "── screenshot ──"
mkdir -p build/ui-smoke
screenshot_path="$PWD/build/ui-smoke/main-window.png"
if ! "$AXPROBE" screenshot "$screenshot_path" --pid "$PID" >/dev/null 2>&1; then
  echo "FAIL: screenshot failed"
  missing+=("screenshot")
fi
if [[ -f "$screenshot_path" ]]; then
  echo "PASS: screenshot at $screenshot_path"
else
  echo "FAIL: screenshot file not written"
fi

end_time=$(date +%s)
seconds=$((end_time - start_time))

ok=false
if [[ ${#missing[@]} -eq 0 ]]; then
  ok=true
fi

if [[ ${#missing[@]} -eq 0 ]]; then
  missing_json="[]"
else
  missing_json="$(printf '"%s",' "${missing[@]}")"
  missing_json="[${missing_json%,}]"
fi

printf '{"ok":%s,"found":%s,"missing":%s,"seconds":%s}\n' "$ok" "$found" "$missing_json" "$seconds"

if [[ "$ok" == "true" ]]; then
  exit 0
else
  exit 1
fi
