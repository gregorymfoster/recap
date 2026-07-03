#!/bin/bash
# shot.sh — window-targeted screenshots for the app-flow-screenshots skill.
#
# Usage:
#   shot.sh list   <owner>                          list on-screen windows: "id<TAB>WxH<TAB>x,y"
#   shot.sh window <owner> <out.png>                capture the largest window owned by <owner>
#   shot.sh id     <window-id> <out.png>            capture a specific window by id
#   shot.sh region <x,y,w,h> <out.png>              capture a screen region (points)
#
# <owner> is a PID (preferred — unambiguous) or an app name. Prefer the PID printed by
# launch.sh: the user's installed "Recap Dev.app" may be running at the same time, and
# by-name matching can't tell the two instances apart.
#
# Requires the Screen Recording TCC grant for the host process; without it,
# captures of other apps' windows come back blank or fail.

set -euo pipefail

list_windows() {
  swift - "$1" <<'EOF'
import CoreGraphics
import Foundation
let owner = CommandLine.arguments[1]
let ownerPID = Int(owner)
guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { exit(1) }
for w in list {
    if let pid = ownerPID {
        guard (w[kCGWindowOwnerPID as String] as? Int) == pid else { continue }
    } else {
        guard (w[kCGWindowOwnerName as String] as? String) == owner else { continue }
    }
    guard let num = w[kCGWindowNumber as String] as? Int,
          let bounds = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
    let width = Int(bounds["Width"] ?? 0), height = Int(bounds["Height"] ?? 0)
    let x = Int(bounds["X"] ?? 0), y = Int(bounds["Y"] ?? 0)
    if width < 20 || height < 20 { continue }  // skip status-item slivers and shadow artifacts
    print("\(num)\t\(width)x\(height)\t\(x),\(y)")
}
EOF
}

case "${1:-}" in
  list)
    list_windows "$2"
    ;;
  window)
    owner="$2"; out="$3"
    id=$(list_windows "$owner" | sort -t$'\t' -k2 -rn | awk -F'\t' '
      { split($2, d, "x"); area = d[1] * d[2]; if (area > best) { best = area; id = $1 } }
      END { if (id) print id; else exit 1 }')
    screencapture -x -o -l "$id" "$out"
    echo "captured window $id -> $out"
    ;;
  id)
    screencapture -x -o -l "$2" "$3"
    echo "captured window $2 -> $3"
    ;;
  region)
    screencapture -x -R "$2" "$3"
    echo "captured region $2 -> $3"
    ;;
  *)
    sed -n '2,10p' "$0" >&2
    exit 64
    ;;
esac
