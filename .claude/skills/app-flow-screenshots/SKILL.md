---
name: app-flow-screenshots
description: Capture a complete "state of the app" screenshot dump of Recap — builds the dev app, launches it with fixture data, drives every core flow (library, meeting detail, search, models, settings, recording pill, floating capsule, menu bar), and saves clean per-window PNGs plus a README manifest to a timestamped folder in ~/Downloads, ready to drop into Claude Design or any design tool. Use whenever the user asks for app screenshots, a screenshot dump, "state of the app", captures of the core flows, design-reference images, or wants to show the current UI to a design tool — even if they only say "grab the screens", "export the UI", or "screenshot the app".
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
they share the one physical desktop, keyboard, and app instance, so parallel agents
would fight over focus and corrupt each other's shots. Include "You ARE the worker — do
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

Accessibility powers the CGEvent input helper (`scripts/input.swift`); Screen Recording
powers `screencapture -l`. Do NOT drive input through `osascript`/System Events — that
needs the separate Apple Events "Automation" grant, which this host typically lacks
(error -1743); the CGEvent helper deliberately avoids it.

### 2. Build once, then launch per phase

```bash
.claude/skills/app-flow-screenshots/scripts/launch.sh -fixtures
```

builds Debug (`xcodegen` + `xcodebuild`, derived data in `build/screenshots/` so it
never collides with soak or dev-install builds), launches the raw binary, waits until
the main window is on screen, and prints `APP=` and `PID=`. Keep the PID; you kill it
between phases. `-fixtures` is disk-free and idempotent — safe to relaunch endlessly.
For the second phase relaunch with `-soak --skip-build` (same binary, no rebuild).

`scripts/shot.sh` is the capture tool — window-targeted `screencapture`, no desktop
background in the shots. `shot.sh list <pid>` shows on-screen windows
(id / size / position); `window` captures the largest, `id` a specific one, `region` a
screen rect (for the menu-bar dropdown).

**Coexistence hazard**: the user's installed `/Applications/Recap Dev.app` may be
running at the same time, with identical window names. Never kill or quit that instance
— it isn't yours. Always target windows and activation by the PID launch.sh printed
(`shot.sh list $PID`, `input activate $PID`), never by app name or bundle id.

### 3. Fan out (sequentially)

Two subagent phases; the full flow list, per-shot navigation steps, expected content,
and the input-driving recipes (keystrokes, coordinate clicks, retina scaling) live in
[references/flows.md](references/flows.md). Have each subagent read that file — its
brief then only needs: the output dir, the app PID/window owner ("Recap Dev"), which
flows it owns, and the worker/no-delegation rule.

- **Phase A — fixtures instance**: library, meeting detail (staged notes), search
  overlay, models, settings (two scroll positions), menu-bar dropdown.
- **Phase B — soak instance** (kill the fixtures process first, relaunch with
  `-soak --skip-build`): recording pill in the main window, then deactivate the app
  (activate Finder) and capture the floating capsule.

The one non-negotiable in every brief: **verify every shot by Reading the PNG** before
moving on — confirm the intended state is actually visible (overlay open, right sidebar
section selected, pill present) and retake if not. A dump with a wrong or stale frame is
worse than a missing one, because nobody re-checks it downstream.

### 4. Verify, write the manifest, clean up

Subagent reports are claims, not evidence: personally Read every PNG against the
expected-content column in flows.md before writing the manifest. Then write `README.md`
(version from `project.yml`'s `MARKETING_VERSION`, commit from `git rev-parse --short
HEAD`), kill any remaining app PID, and `open` the folder.

Known fixture limitations to state in the manifest, not apologize for: fixture meetings
have no transcript/enhanced-notes content (detail-view notes are staged by typing), and
the soak instance produces no live-transcript text (no engine attached). Onboarding is
unreachable in both modes (`hasOnboarded` is forced true) — it is deliberately not part
of the dump.
