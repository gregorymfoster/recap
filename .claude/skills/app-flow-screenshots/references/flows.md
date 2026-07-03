# Flow list and driving recipes

Read this whole file before driving the app. The app under automation is **"Recap Dev"**
(Debug build, bundle id `com.gregfoster.recap.dev`), one main window ~1060×660, no
accessibility identifiers anywhere — so you navigate with keyboard shortcuts where they
exist and coordinate clicks where they don't, and you confirm every state visually.

## Driving toolkit

All input goes through the compiled CGEvent helper (`launch.sh` prints its path as
`INPUT=`, normally `build/screenshots/input`). It needs only the Accessibility grant the
manager already verified — do NOT use `osascript`/System Events for input; that requires
a separate Automation TCC grant the host usually lacks (error -1743).

Always target by **PID** (the `PID=` from launch.sh), never by app name or bundle id:
the user's installed `/Applications/Recap Dev.app` is often running at the same time
with identical window names, and by-name matching can pick the wrong instance.

```bash
"$INPUT" activate $PID                       # bring OUR instance frontmost — do this before every input burst
"$INPUT" key 40 cmd                          # ⌘K (search overlay)
"$INPUT" key 43 cmd                          # ⌘, (settings)
"$INPUT" key 53                              # Esc
"$INPUT" key 36                              # Return
"$INPUT" type "standup"                      # type into the focused element
"$INPUT" click 612 340                       # left-click at screen coords (points)
"$INPUT" scroll 612 400 -600                 # scroll content down at those coords (use this, NOT Page Down —
                                             #   key 121 does not scroll SwiftUI Forms)
```

**`activate` does not always take effect** — a fullscreen app on another Space can hold
focus through several attempts, and input sent then lands in the wrong app (this has
opened System Settings by accident). After every `activate`, verify before sending input:

```bash
swift -e 'import AppKit; print(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1)'
```

Retry `activate` until that prints your PID.

**Coordinate clicks**: get the window's origin and size from
`scripts/shot.sh list $PID` (`id  WxH  x,y`), capture the window, Read the PNG,
locate the target in image pixels, then convert: the PNG is Retina-scaled, so
`scale = imageWidth / windowWidth` (usually 2) and
`click point = (windowX + imagePx.x/scale, windowY + imagePx.y/scale)`.
After every click or keystroke, wait ~0.5–1s, retake the window shot, and Read it to
confirm the state changed as intended before capturing the final numbered PNG. Never
assume a click landed.

Capture: `scripts/shot.sh window $PID <out.png>` (largest window — the main window),
`shot.sh id <windowid> <out.png>` for a specific one (the floating capsule),
`shot.sh region <x,y,w,h> <out.png>` for the menu-bar dropdown.

The process sometimes owns TWO identical-size main windows (SwiftUI leaves a frozen
ghost behind after in-window navigation like opening Settings). `shot.sh window` picks
the frontmost of equal-size windows, which is usually right — but if a capture looks
stale, capture each id and Read them: the live window has colored traffic-light buttons,
the ghost's are gray.

## Phase A — fixtures instance (`-fixtures`)

Fixture data: 6 meetings ("Design sync — Q3 roadmap" transcribing at 42%,
"Customer call — Meridian" queued, "Budget review" needs-model, "Weekly standup",
"1:1 with Sam", "Pricing brainstorm" ready) plus a sidebar processing-queue widget.
Statuses are frozen — nothing progresses, so shots are stable.

| # | File | Flow | How to get there | Must be visible in the PNG |
|---|------|------|------------------|----------------------------|
| 1 | `01-library.png` | Library home | Default view on launch. If you've navigated away, click "Library" in the sidebar. | Sidebar + date-grouped meeting cards with mixed status chips (Transcribing 42%, Queued, Needs model, Ready), red Record button |
| 2 | `02-meeting-detail.png` | Meeting detail | Click the "Weekly standup" card. Fixtures ship no notes content, so the editor is empty — stage it: click into the editor and type 3–4 short markdown lines (e.g. `# Weekly standup`, two `- ` bullets, an action item) so the pane looks lived-in. Note in your report that notes were staged. | Meeting title, attendee chips, notes editor with the staged text, bottom status bar |
| 3 | `03-meeting-detail-transcript.png` | Transcript pane | From the detail view, click the "Transcript" toggle in the toolbar (text.quote icon, top-right area). Pane will be empty — that's the real fixtures state, capture it anyway. | Split view: transcript pane (empty state) + notes pane |
| 4 | `04-search.png` | ⌘K search overlay | Go back to Library via the `<` chevron button at the TOP-LEFT of the detail view, next to the window title (the sidebar "Library" row does nothing here — it's already selected). Press ⌘K, click into the search field, then type `sam` — keystrokes sent immediately after ⌘K get dropped. Verify the query text actually appears before capturing. | Centered search overlay with query "sam" and at least one result ("1:1 with Sam"; search matches titles only, not attendees) |
| 5 | `05-models.png` | Model manager | Esc to close search, click "Models" in the sidebar. | Whisper model cards with Download/Use actions, Recommended/Active chips |
| 6 | `06-settings.png` | Settings (top) | Press ⌘,. **Gotcha**: this spawns a NEW CGWindowID at a slightly shifted origin (the old entry may linger as a frozen ghost) — re-run `shot.sh list $PID` and redo all coordinate math against the new/live window before further clicks. | Permissions rows (Microphone / System Audio / Calendar), Storage section |
| 7 | `07-settings-scrolled.png` | Settings (bottom) | Scroll down with `"$INPUT" scroll <x> <y> -900` over the form (Page Down does nothing in SwiftUI Forms). | Recording tail, Calendar, Sync & Backup sections; the Processing section header at the bottom is enough — all four don't fit one 660px window |
| 8 | `08-menubar.png` | Menu bar dropdown | See recipe below. Optional — skip after 2 failed attempts rather than burning time. Known issue: the waveform status icon may not be visible at all (menu-bar managers / notch overflow can hide it, and two Recap Dev instances confuse matters) — skipping is fine and expected. | Dropdown with Start Recording, recent meetings, Open Recap, Settings… |

**Menu-bar dropdown recipe** — the status item's position isn't queryable without System
Events, so find it visually: capture the right end of the menu bar
(`shot.sh region "<screenWidth-500>,0,500,30" menubar-strip.png`), Read it, locate the
Recap waveform icon (remember retina scaling), then:

```bash
"$INPUT" click <iconX> 12          # opens the dropdown
sleep 1.5
scripts/shot.sh region "<iconX-350>,0,400,500" 08-menubar.png
"$INPUT" key 53                    # Esc closes the menu
```

Get the screen width from `swift -e 'import AppKit; print(NSScreen.main!.frame)'`.

## Phase B — soak instance (`-soak`)

Kill the fixtures PID first, then `launch.sh -soak --skip-build`. Soak auto-starts a
synthetic recording at launch — no clicks, no mic/system-audio permission prompts, no
real hardware. There is no transcription engine attached, so live-transcript text stays
empty ("Listening…"-style states are expected and correct).

| # | File | Flow | How to get there | Must be visible in the PNG |
|---|------|------|------------------|----------------------------|
| 9 | `09-recording-pill.png` | Recording in progress | Wait ~5s after launch for the session to start; the app auto-navigates to the live meeting. Capture the main window. | Recording pill pinned to the bottom: pulsing red dot, elapsed timer, waveform, Pause/Stop controls; live transcript pane with its empty/loading state |
| 10 | `10-floating-capsule.png` | Floating capsule | Deactivate Recap: `"$INPUT" activate com.apple.finder` (or `open -a Finder`), wait ~2s. The capsule is a small borderless always-on-top panel owned by the soak process — find it with `shot.sh list $PID` (the small window, not 1060×660) and capture it with `shot.sh id <id>`. | The capsule: elapsed time, waveform, recording state |

Kill the soak PID when done (soak writes only to a throwaway temp dir; SIGTERM is fine).
