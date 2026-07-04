# Flow list and driving recipes

Read this whole file before driving the app. The app under automation is **"Recap Dev"**
(Debug build, bundle id `com.gregfoster.recap.dev`), one main window ~1060×660. Every
interactive element worth targeting has a stable AXIdentifier — navigate by identifier,
never by screen coordinate.

## Driving toolkit

Build `ax-probe` once per session (`swift build --package-path Tools/AXProbe`), then call
`Tools/AXProbe/.build/debug/ax-probe <subcommand> --pid "$PID" [--json]` for every action.
`$PID` is the exact process id `launch.sh` printed.

```bash
ax-probe windows --pid "$PID" --json                          # window titles/frames — use before/after every nav step
ax-probe tree    --pid "$PID" [--depth N]                      # dump the AX hierarchy; grep for the identifier you need
ax-probe find    --pid "$PID" <axid>                            # locate one element, confirm it exists before clicking
ax-probe click   --pid "$PID" <axid>                            # AXPress, falls back to a CGEvent click at the element's center
ax-probe type    --pid "$PID" <axid> "text"                     # focus + set AXValue, falls back to key events
ax-probe screenshot --pid "$PID" <out.png> [--window <n|title>] # screencapture -l of one of the app's windows
```

**Always use `--pid`, never `--app <bundle-id>`.** More than one `com.gregfoster.recap.dev`
process is often running at once — the user's installed `/Applications/Recap Dev.app`,
another concurrent session's own build, a leftover soak run — and `--app` picks an
*arbitrary* one of them by bundle id. `--pid` is unambiguous. Never kill or activate a PID
you didn't get from `launch.sh` in this session.

**Finding identifiers**: `Packages/RecapUI/Sources/RecapUI/**/AXID+*.swift` is the
authoritative, current source — grep it rather than trusting the specific identifier names
below if the UI has changed since this doc was written. Dynamic rows (meeting rows, model
rows, queue rows) are keyed by a stable id suffix, not title or position — get the live
value with `ax-probe tree --pid "$PID" | grep meeting-row` (or `find`/`grep` for whatever
prefix you need) rather than hardcoding a UUID, since fixture ids can differ per launch.

**Gotcha — SF Symbols leak as AXIdentifiers.** `Image(systemName:)` views expose their
symbol name (e.g. `"text.quote"`, `"waveform"`) as their own AXIdentifier when nothing
else was tagged, so a `tree` dump can show noise that looks like a real id but isn't one
this skill defined. Match only against the exact known identifiers in the AXID+*.swift
files, not anything symbol-shaped you spot in a tree dump.

**Gotcha — a `click`/`type` can report success without landing.** `ax-probe click`
prints "pressed" when `AXPress` succeeds, or "clicked (CGEvent) center of …" when it falls
back to a synthetic click. The CGEvent fallback path posts a mouse event at the element's
last-known frame — if that frame is stale (e.g. a scroll happened since `tree` was last
run, or another window is actually on top at that screen point) the click can miss
silently and the command still exits 0. After every navigation step, confirm the state
actually changed: re-run `ax-probe windows --pid "$PID"` (window title changes on
navigating into a meeting) or `ax-probe find --pid "$PID" <axid-you-expect-now>` before
capturing the final PNG.

**Keyboard-only fallback**: `scripts/input.swift` (compiled by `launch.sh` to
`build/screenshots/input`) is deliberately slimmed to two subcommands now that ax-probe
handles clicking/typing:

```bash
"$INPUT" activate $PID     # bring OUR instance frontmost — do this before any key command
"$INPUT" key 43 cmd        # ⌘, opens Settings — no reliable AX path to it otherwise
"$INPUT" key 40 cmd        # ⌘K search overlay — ax-probe click on the search-field id works too; either is fine
"$INPUT" key 53            # Esc
```

Use `key` only where there's no reasonable AX equivalent (currently: ⌘, for Settings).
Prefer `ax-probe click search-field` over ⌘K where both exist — one less tool in the loop.
`activate` does not always take effect on the first try (a fullscreen app on another Space
can hold focus); verify with `swift -e 'import AppKit; print(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1)'`
and retry until it prints your PID before sending a `key` command.

Capture: `ax-probe screenshot --pid "$PID" <out.png>` (first/frontmost on-screen window),
`--window <index>` or `--window <title-substring>` for a specific one (e.g. the menu-bar
content debug window), or fall back to `scripts/shot.sh` (`list`/`window`/`id`/`region`
by PID) if you need a raw screen-region capture ax-probe doesn't do (e.g. the floating
capsule, which is a small borderless panel best grabbed by window id from `shot.sh list`).

The process can end up owning more than one similarly-sized window if SwiftUI restores a
prior session's scene (this happens even with a completely fresh `-fixtures` launch and no
prior `-show-*` flags — a known app-shell quirk, not something to fight in this skill).
Always confirm you're capturing the live one via `ax-probe windows --pid "$PID"` (title
reflects current navigation state, e.g. "Weekly standup" once you've opened that meeting)
rather than assuming index 0.

## Phase A — fixtures instance (`-fixtures`)

Fixture data: 6 meetings ("Design sync — Q3 roadmap" transcribing at 42%,
"Customer call — Meridian" queued, "Budget review" needs-model, "Weekly standup",
"1:1 with Sam", "Pricing brainstorm" ready) plus a sidebar processing-queue widget.
Statuses are frozen — nothing progresses, so shots are stable. Meeting detail views now
ship with real fixture notes/transcript content (no staging needed) — verify this is
still true for the meeting you pick before assuming an empty pane means something broke.

| # | File | Flow | How to get there | Must be visible in the PNG |
|---|------|------|------------------|----------------------------|
| 1 | `01-library.png` | Library home | Default view on launch. If you've navigated away, use `library-back-button` from a detail view to return. | Sidebar (`sidebar`) + `library-list` with mixed status chips (Transcribing 42%, Queued, Needs model, Ready), `library-record-button` |
| 2 | `02-meeting-detail.png` | Meeting detail | Find a meeting row: `ax-probe tree --pid "$PID" \| grep meeting-row \| grep "Weekly standup"` to get its live id, then `ax-probe click --pid "$PID" meeting-row-<id>`. Confirm navigation via `ax-probe windows --pid "$PID"` (title becomes the meeting name). | Meeting title, attendee chips, `library-detail-pane` with notes content, `library-player-bar` at the bottom |
| 3 | `03-meeting-detail-transcript.png` | Transcript pane | From the detail view, `ax-probe click --pid "$PID" library-transcript-toggle-button`. | Split view: `library-transcript-pane` + `library-detail-pane` both visible |
| 4 | `04-search.png` | ⌘K search overlay | Go back to Library via `ax-probe click --pid "$PID" library-back-button`. Then `ax-probe click --pid "$PID" search-field` (opens the overlay), then `ax-probe type --pid "$PID" library-search-overlay-field "sam"`. Confirm via `ax-probe find --pid "$PID" library-search-overlay-field` that the value actually contains the query before capturing. | `library-search-overlay` with query "sam" in `library-search-overlay-field`, at least one result row (search matches titles only, not attendees) |
| 5 | `05-models.png` | Model manager | From Library, click the sidebar's "Models" entry — find its identifier live with `ax-probe tree --pid "$PID" | grep -i model` if it isn't obviously one of the `settings-models-*` ids (those tag the list/rows once you're on the screen, not necessarily the sidebar nav item itself). | `settings-models-list` with model rows showing Download/Use actions and Recommended/Active chips |
| 6 | `06-settings.png` | Settings (top) | No reliable AX path into Settings from the main window chrome — use the keyboard fallback: `"$INPUT" activate $PID && "$INPUT" key 43 cmd` (⌘,). Confirm via `ax-probe windows --pid "$PID"` that a `settings-window` titled window appeared. Then `ax-probe click --pid "$PID" settings-tab-privacy`. | `settings-window`, Privacy tab active: `settings-privacy-microphone-permission-button`, `settings-privacy-system-audio-permission-button`, `settings-privacy-calendar-permission-button` rows |
| 7 | `07-settings-recording.png` | Settings (Recording tab) | `ax-probe click --pid "$PID" settings-tab-recording`. | `settings-recording-input-device-picker`, `settings-recording-system-audio-toggle`, `settings-recording-label-speakers-toggle`, `settings-recording-transcription-language-picker` |
| 8 | `08-menubar.png` | Menu bar dropdown | Relaunch (or launch a second, disposable instance) with `-fixtures -show-menubar-content` — this opens an ordinary, screenshot-able window hosting the same `menu-bar-content` view instead of the real status-item popover, which headless tooling can't reach. `ax-probe windows --pid "$PID"` to find the "Menu Bar Content" window index, then `ax-probe screenshot --pid "$PID" 08-menubar.png --window "Menu Bar Content"`. | `menu-bar-content` root with `menu-bar-start-recording-button` (idle) or the recording header controls, recent-meetings rows, `menu-bar-open-app-button`, `menu-bar-settings-button` |
| 9 | `09-nudge.png` | "Meeting started?" nudge | Relaunch with `-fixtures -show-nudge` — opens a debug window stacking all three `MeetingNudgeView` variants (ask-with-match, ask-app-only, recordingStarted) so nothing needs a real calendar/call-app event. `ax-probe screenshot --pid "$PID" 09-nudge.png --window "Nudge Preview"`. | `nudge-panel` instances showing `nudge-record-button`/`nudge-dismiss-button`/`nudge-dont-ask-button` (ask variants) and `nudge-stop-button` (recordingStarted variant) |

## Phase B — soak instance (`-soak`)

Kill the fixtures PID first, then `launch.sh -soak --skip-build`. Soak auto-starts a
synthetic recording at launch — no clicks, no mic/system-audio permission prompts, no
real hardware. There is no transcription engine attached, so live-transcript text stays
empty ("Listening…"-style states are expected and correct).

| # | File | Flow | How to get there | Must be visible in the PNG |
|---|------|------|------------------|----------------------------|
| 10 | `10-recording-pill.png` | Recording in progress | Wait ~5s after launch for the session to start; the app auto-navigates to the live meeting. `ax-probe screenshot --pid "$PID" 10-recording-pill.png`. | `recording-pill` pinned to the bottom: `recording-pause-button`, `recording-stop-button`, elapsed timer, waveform; live transcript pane in its empty/loading state |
| 11 | `11-floating-capsule.png` | Floating capsule | Deactivate Recap so it backgrounds: `"$INPUT" activate <Finder-pid>` (or `open -a Finder`), wait ~2s. The capsule (`floating-indicator`) is a small borderless always-on-top panel — `ax-probe windows --pid "$PID"` may not enumerate it if it's a non-standard-layer panel; if so fall back to `scripts/shot.sh list $PID` to find its window id by size (small, not 1060×660) and `shot.sh id <id> 11-floating-capsule.png`. | The capsule: elapsed time, waveform, recording state |

Kill the soak PID when done (soak writes only to a throwaway temp dir; SIGTERM is fine).

## Flows still needing a non-AX step, and why

- **Settings (⌘,)** — no toolbar/menu button opens Settings from the main window; the
  real entry points are the app menu ("Recap Dev → Settings…") and the global shortcut.
  Driving the actual menu bar item needs the Apple Events "Automation" TCC grant this
  host doesn't have, so the keyboard shortcut via `scripts/input.swift key 43 cmd` is the
  practical option. Once the Settings window is open, every tab/control inside it is
  reached by `ax-probe click`/`type` as normal.
- **Menu bar dropdown / nudge panel** — the real surfaces (status-item popover,
  borderless all-spaces `NSPanel`) aren't reliably reachable by any UI-automation tool,
  AX or otherwise, so the app ships dedicated debug windows (`-show-menubar-content`,
  `-fixtures -show-nudge`) that host the identical view in an ordinary screenshot-able
  window. This isn't a coordinate-clicking workaround — it's the same identifier-driven
  approach, just against the debug window instead of the unreachable real one.
- **Floating capsule** — a small borderless panel; `ax-probe windows` targets standard
  app windows, so grabbing this one may still need `shot.sh list $PID` for its window id.
  It has a stable AXIdentifier (`floating-indicator`) for future `ax-probe` reads even if
  the capture path goes through `shot.sh`.
