---
name: app-flow-screenshots
description: Capture a complete "state of the app" screenshot dump of Recap — builds the dev app, launches it with fixture data, drives every core flow (library, meeting detail, search, one-page settings, recording view + session capsule, floating capsule, first run, menu bar) via accessibility identifiers, and saves clean per-window PNGs plus a README manifest to a timestamped folder in ~/Downloads, ready to drop into Claude Design or any design tool. Use whenever the user asks for app screenshots, a screenshot dump, "state of the app", captures of the core flows, design-reference images, or wants to show the current UI to a design tool — even if they only say "grab the screens", "export the UI", or "screenshot the app".
---

# App flow screenshots

Produce a folder in `~/Downloads` containing one clean window screenshot per core flow of
Recap, plus a `README.md` manifest describing each shot — a self-contained "state of the
app" dump the user can hand to Claude Design or any design tool.

## Output contract

- Folder: `~/Downloads/Recap-flows-<YYYY-MM-DD>/` (append `-2`, `-3`… if it exists — never overwrite a previous dump).
- Numbered PNGs, one per flow (see the flow list in [references/flows.md](references/flows.md)).
- `README.md` manifest: app version + git commit, capture date, a note that data is fixture
  sample data, and a table of every file with a one-line description of the flow/state it
  shows. This gives Claude Design context for each image — write real descriptions, not
  filenames restated.
- When done, `open` the folder so it's visible in Finder, and tell the user the path.

## How to run it

You are the manager. Build and launch inline (cheap shell work), delegate the
GUI-driving to **cheap subagents (`model: "sonnet"`), run strictly one at a time** —
they share the one physical desktop and app instance, so parallel agents would fight
over the same process and corrupt each other's shots. Include "You ARE the worker — do
not spawn further agents" in every brief, or they'll inherit the delegate-by-default
preference and cascade.

### 1. Preflight: permissions

Two TCC grants must exist for the host process (the app running Claude). Probe both
*before* building, and if either fails, stop and tell the user exactly what to grant in
System Settings → Privacy & Security:

```bash
swift -e 'import ApplicationServices; print("AX_TRUSTED:", AXIsProcessTrusted())'          # Accessibility
swift -e 'import CoreGraphics; print("SCREEN_RECORDING:", CGPreflightScreenCaptureAccess())' # Screen Recording
```

Accessibility powers `ax-probe` (click/type by identifier) and the keyboard-shortcut
fallback (`scripts/input.swift`); Screen Recording powers `shot.sh`'s
`screencapture -l`. Also confirm the screen is UNLOCKED — a locked screen makes every
newly launched app run windowless forever (looks exactly like an app bug; it isn't):

```bash
swift -e 'import Quartz; let d = CGSessionCopyCurrentDictionary() as? [String: Any]; print((d?["CGSSessionScreenIsLocked"] as? Int) == 1 ? "LOCKED — stop, ask the user to unlock" : "unlocked")'
``` Do NOT drive input through `osascript`/System Events — that needs
the separate Apple Events "Automation" grant, which this host typically lacks
(error -1743).

### 2. Build once, then launch per phase

```bash
.claude/skills/app-flow-screenshots/scripts/launch.sh -fixtures
```

builds Debug (`xcodegen` + `xcodebuild`, derived data in `build/screenshots/` so it
never collides with soak or dev-install builds), launches via `open -n` (raw-exec'd
binaries sometimes never register with the window server on this host), waits until
the main window is on screen, and prints `APP=` and `PID=`. Keep the PID — it's how you
target the right instance. All arguments except `--skip-build` are forwarded to the app,
so scenario launches work: `launch.sh -fixtures recording --skip-build`. `-fixtures`
(any scenario) is disk-free and idempotent — safe to relaunch endlessly; use
`--skip-build` for every relaunch after the first.

### 3. Drive the app with ax-probe, by accessibility identifier

All navigation goes through `Tools/AXProbe` (`ax-probe`), a standalone driver built
against the public Accessibility API — no coordinate math, no screen-scaling, no
Retina-scale guessing. ~90 stable identifiers are already tagged across the app (grep
`Packages/RecapUI/Sources/RecapUI/**/AXID+*.swift` for the authoritative, current list —
it changes as UI ships, don't trust a stale copy in this doc). Full per-flow recipes,
including the exact identifiers and known gotchas, live in
[references/flows.md](references/flows.md); have each subagent read that file.

```bash
swift build --package-path Tools/AXProbe   # once, fast — cache it like input.swift used to be
Tools/AXProbe/.build/debug/ax-probe tree   --pid "$PID"                       # dump the AX hierarchy to find identifiers
Tools/AXProbe/.build/debug/ax-probe click  --pid "$PID" meeting-row-<id>      # AXPress, CGEvent fallback
Tools/AXProbe/.build/debug/ax-probe type   --pid "$PID" search-field "sam"    # focus + set value, else key events
Tools/AXProbe/.build/debug/ax-probe windows --pid "$PID" --json               # window titles/frames for shot.sh
```

(`swift run --package-path Tools/AXProbe ax-probe ...` also works and rebuilds only on
change, at the cost of a slower first invocation per phase.)

**Always pass `--pid`, never `--app <bundle-id>`.** `--app` resolves via
`NSRunningApplication.runningApplications(withBundleIdentifier:)`, which returns an
*arbitrary* matching instance when more than one `com.gregfoster.recap.dev` process is
running — and that happens routinely: the user's installed `/Applications/Recap
Dev.app`, another concurrent Claude session's own screenshot/smoke build, a soak run
left over from earlier. `--pid` targets the exact process `launch.sh` printed, with no
ambiguity. Verified live during this rewrite: with two `com.gregfoster.recap.dev`
processes running simultaneously, `--app` silently drove the *other* session's
instance while `--pid` correctly isolated to the one this session launched.

A very small number of actions have no reasonable AX path — currently just the ⌘,
Settings shortcut (opening Settings via a real menu click is more brittle than the
shortcut). For those, `scripts/input.swift` still exists but is slimmed to exactly two
subcommands: `activate` (bring the target PID frontmost) and `key` (post a keycode
chord). It no longer supports click/doubleclick/type/scroll — that's ax-probe's job now.

### 4. Fan out (sequentially)

Two subagent phases; the full flow list, per-shot ax-probe invocations, and expected
content live in [references/flows.md](references/flows.md). Have each subagent read
that file — its brief then only needs: the output dir, the app PID, which flows it
owns, and the worker/no-delegation rule.

- **Phase A — default fixtures instance** (`-fixtures`): library (footer + banner-free
  home), meeting detail (summary disclosure + inline transcript), search overlay,
  the one-page Settings window (⌘,), menu-bar dropdown (via `-show-menubar-content`),
  nudge panel (via `-show-nudge`).
- **Phase B — scenario instances** (kill the previous PID, relaunch per shot with
  `launch.sh -fixtures <scenario> --skip-build`): `recording` for the full-window
  recording view + session capsule, then deactivate the app (activate Finder) for the
  floating capsule; `nextMeetingSoon` for the next-meeting banner; `firstRun` for the
  onboarding sheet; `backupStuck` for the amber footer state.

The one non-negotiable in every brief: **verify every shot by Reading the PNG** before
moving on — confirm the intended state is actually visible (overlay open, disclosure
expanded, capsule present) and retake if not. A dump with a wrong or stale frame is
worse than a missing one, because nobody re-checks it downstream. Also verify each
`ax-probe click`/`type` actually landed by re-querying (`ax-probe find <axid>`) or
checking the window title/AX tree changed — a `click` that fell back to a CGEvent
center-click can silently miss if the element's frame was stale.

### 5. Verify, write the manifest, clean up

Subagent reports are claims, not evidence: personally Read every PNG against the
expected-content column in flows.md before writing the manifest. Then write `README.md`
(version from `project.yml`'s `MARKETING_VERSION`, commit from `git rev-parse --short
HEAD`), kill any remaining app PID, and `open` the folder.

Known fixture limitations to state in the manifest, not apologize for: the `recording`
scenario's session is synthetic (no live-transcript text, canned waveform levels).
Onboarding renders only under `-fixtures firstRun` (every other scenario forces
`hasOnboarded` true so its own surface shows underneath).
