# ax-probe

UI-automation driver for any running macOS app via the public Accessibility API — replaces
coordinate-based clicking. Standalone SwiftPM executable, deliberately outside the app's
package DAG.

```
swift build --package-path Tools/AXProbe
Tools/AXProbe/.build/debug/ax-probe <subcommand> --app <bundle-id> [--json]

  tree [--depth N]                                dump AX hierarchy (default depth 15)
  find <axid>                                     locate element by AXIdentifier
  click <axid>                                    AXPress, CGEvent-click fallback
  type <axid> <text>                              focus + set AXValue, else key events
  windows                                         list windows (title, frame, main/focused)
  screenshot <path> [--window <index-or-title>]   screencapture -l of an app window
```

Probe contract: human-readable output by default; `--json` adds exactly one JSON object as the
last stdout line. Exit codes: `0` ok, `1` failure, `3` identifier/window not found,
`5` Accessibility permission missing (grant the host process in System Settings > Privacy &
Security > Accessibility), `64` usage. Screenshots also need Screen Recording permission.

Example against the fixtures app (`.claude/skills/app-flow-screenshots/scripts/launch.sh -fixtures`):
`ax-probe windows --app com.gregfoster.recap.dev --json`
