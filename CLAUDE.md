# Project preferences

## Committing and pushing

Commit and push to `main` liberally — don't wait to be asked each time. Whenever a
change is at a good, coherent checkpoint (a feature works, a fix is verified, a
build succeeds), commit it and push to `main` directly without checking in first.

## Layout

- `Packages/RecapCore` — domain models, storage, search, processing queue. No UI, no hardware.
- `Packages/RecapAudio` — mic + system-audio capture, mixing, transcoding.
- `Packages/RecapTranscription` — engine protocol, WhisperKit transcription, FluidAudio diarization.
- `Packages/RecapEnhancement` — on-device note enhancement (Apple FoundationModels).
- `Packages/RecapUI` — SwiftUI views, design tokens, stores (`AppStores`, `QueueStore`, etc.).
- `Recap/` — thin app shell: `@main`, assets, entitlements, Sparkle updater. Keep logic out of here.

Packages are pure SPM. The app shell is XcodeGen-generated — `Recap.xcodeproj` is gitignored; run
`./Scripts/bootstrap.sh --no-open` after adding files under `Recap/` or editing `project.yml`.

## Build & test

- `./Scripts/check.sh` is the single verification gate. Fast tier (default) runs
  lint + all package tests (~40s) and emits one JSON object as the last stdout
  line, same contract as the probes; `./Scripts/check.sh --full` adds the
  xcodegen + app build and is REQUIRED before claiming app-shell (`Recap/`) work
  done. `Scripts/lint.sh` mechanically enforces the Conventions section below
  (Swift Testing only, commented concurrency escape hatches, no
  `ProcessInfo.environment` in app code, file-size advisories). A versioned
  `.githooks/pre-push` hook runs the gate automatically — fast tier, escalating
  to `--full` when `Recap/`, `project.yml`, or `Scripts/` changed;
  `RECAP_SKIP_CHECK=1 git push` bypasses it.
- Just package tests, no lint/gate: `./Scripts/test.sh` (extra args pass
  through, e.g. `./Scripts/test.sh --filter LibraryStorage`).
- One package: `swift test --package-path Packages/RecapCore`.
- SPM quirk: after ADDING a new source file to a shared package, sibling packages'
  incremental builds can fail with "cannot find type '<NewType>' in scope" (the owning
  package stays green — that's the signature). Fix the build, not the code:
  `swift package --package-path Packages/<failing-pkg> clean` and re-run.

## Parallel feature work (multi-agent)

- Scaffold shared API surfaces (new SettingsStore keys, store/view skeletons, helper
  entry points) in a commit on main BEFORE fanning out parallel worktree agents —
  worktrees can't see each other's edits, so any cross-package contract must exist at
  branch time. Pin exact signatures in every brief that consumes them.
- One agent = one disjoint file set. Merge branches sequentially, then run the full
  suite AND the app build centrally — per-package green doesn't cover integration.
- UI work isn't done until it's been seen: launch `-fixtures` and screenshot the
  changed surface (app-flow-screenshots skill), in both light and dark mode. Diff
  review catches logic bugs; only screenshots catch wrong-side panels, banned copy
  ("Zero kB"), and dropped toolbar items.
- New UI surfaces must ship with fixture state that renders them — a surface the
  fixture app can't show is a surface QA can't verify.

## Run the app with fixture data

Build, then launch with the `-fixtures` arg: `open -n <path>/Recap.app --args -fixtures`, or run the
`Recap (Fixtures)` scheme in Xcode. Swaps in sample meetings and ephemeral settings — no disk
writes, no processing queue. Use for UI work and screenshots.

Always launch via `open -n`, never the raw executable (`.app/Contents/MacOS/<exe>` directly) — on
some hosts a raw-exec launch never registers with LaunchServices/the window server, so the process
runs but no window ever appears (looks identical to a hang). `Scripts/ui-smoke.sh` and the
`app-flow-screenshots` skill both launch this way; any new automation should too.

`-soak` is a similar launch argument, for the soak harness only: it auto-starts a synthetic-audio
recording (no mic/system-audio hardware, no transcription engine) against throwaway temp storage
with no processing queue. Driven by `Scripts/soak-test.sh`; not for interactive use.

`-show-menubar-content` (combine with `-fixtures`) opens an auxiliary, non-resizable window hosting
the menu bar extra's popover content (`MenuBarContent`) so it can be screenshotted — the real
status-item popover lives in menu-bar overflow that headless tooling can't reach.

`-seed-dir <path>` is deterministic real-storage state injection, normal-mode only (ignored under
`-fixtures`/`-soak`): at launch, `<path>` (a library folder in the on-disk `LibraryStorage` layout —
one subfolder per meeting) is copied into a throwaway temp directory, and the real storage stack
(`LibraryStorage`, search index, processing queue) is rooted there instead of `~/Recap*`. The source
directory is never written to. Use it to reproduce a real-library bug deterministically: copy the
problem library once, then every `-seed-dir` launch starts from an identical snapshot. Falls back to
normal storage (logging an error) if the source is missing or unreadable.

## Dev build vs prod

Debug builds produce a fully independent **Recap Dev.app** (`com.gregfoster.recap.dev`) so a prod
install and a dev build can coexist: separate TCC permission grants, separate UserDefaults,
meetings in `~/Recap Dev` instead of `~/Recap`, and its own search index. Sparkle auto-update is
never constructed in dev — a dev build must never update itself into the prod app. It also carries
a distinct orange "DEV" app icon (`AppIcon-Dev` asset, Debug-only via
`ASSETCATALOG_COMPILER_APPICON_NAME`) so the two are tellable apart in the Dock. Release builds
(and `Scripts/release.sh`) are unchanged: `com.gregfoster.recap`, plain `Recap.app`, blue icon.

Install/update it as a normal app (builds signed — unsigned binaries won't launch on Apple
Silicon, and a stable signature keeps the dev app's TCC grants across rebuilds):

```
./Scripts/install-dev.sh    # → /Applications/Recap Dev.app, launchable like any app
```

Reset permissions for a clean slate — only touches the dev app, prod is untouched:
`tccutil reset All com.gregfoster.recap.dev`

## Verification probes

Real hardware/models — the manual-verification layer for capture/transcription/enhancement
changes. Not run in CI.

- `swift run --package-path Packages/RecapAudio capture-probe 5 [--json]` — records mic + system audio for N seconds. Needs mic permission. Flags: `--list-devices`, `--device <uid>`, `--pause-test`.
- `swift run --package-path Packages/RecapAudio call-audio-probe <seconds> [--json]` — observes call-audio process events (CoreAudio process metadata only, no capture, no TCC prompt).
- `swift run --package-path Packages/RecapTranscription transcribe-probe Fixtures/meeting-fixture.m4a tiny [--stream] [--language <code>] [--json]` — downloads the model on first run.
- `swift run --package-path Packages/RecapTranscription diarize-probe Fixtures/two-speaker-fixture.m4a [--json]`
- `swift run --package-path Packages/RecapEnhancement enhance-probe <transcript.json> [notes.md] [--json]` — needs Apple Intelligence; exits 2 when unavailable.
- `swift run --package-path Packages/RecapEnhancement enhance-eval [--runs N] [--json]` — scores `Fixtures/enhance/` cases; run before/after any enhancement prompt change.
- `swift run --package-path Packages/RecapTranscription transcribe-eval [--json] Fixtures/transcribe` — scores `Fixtures/transcribe/` cases by word error rate; run before/after any model default or decoding-option change. Not run in normal CI — runs nightly + on `workflow_dispatch` (see `transcription-eval` job in `.github/workflows/ci.yml`).
- `./Scripts/soak-test.sh` — launches the real app in `-soak` mode (synthetic audio, no hardware, no transcription) and samples CPU/memory for ~30s, failing on a runaway main-thread loop (e.g. the MenuBarExtra re-render freeze). Not run per-PR — runs nightly + on `workflow_dispatch` (see `soak-test` job in `.github/workflows/ci.yml`).
- `swift run --package-path Tools/AXProbe ax-probe <tree|find|click|type|windows|screenshot> --app com.gregfoster.recap.dev [--pid N] [--json]` — drives/inspects a running app instance by accessibility identifier; AXIDs live in `Packages/RecapUI/Sources/RecapUI/*/AXID*.swift`. Prefer `--pid <pid>` over `--app <bundle-id>` when more than one instance of the app may be running (`--app` resolves to an arbitrary matching instance).
- `./Scripts/ui-smoke.sh` — agent-runnable UI smoke test: launches the app with `-fixtures -show-menubar-content`, asserts a fixed list of core AXIDs resolve, screenshots the main window to `build/ui-smoke/main-window.png`, then kills the app. Wired into `./Scripts/check.sh --ui` (opt-in).

See `Fixtures/README.md` for fixture details and expected output.

### `--json` output (all probes and evals)

Human-readable output is unchanged by default. With `--json`, every probe/eval additionally prints
exactly one JSON object as the **last line** of stdout, so agents can parse a result without
scraping prose:

- `capture-probe`: `{"ok":true,"seconds":2,"micFrames":36010,"systemFrames":36010,"chunks":22,"peakAmplitude":0.0228,"fileSeconds":2.25,"systemAudioActive":false,"pauseTest":null}` (`--list-devices --json` instead emits a JSON device array)
- `call-audio-probe`: `{"ok":true,"events":0,"started":0,"stopped":0,"watched":[...]}`
- `transcribe-probe`: `{"ok":true,"mode":"file","utterances":12,"duration":31.2,"text":"…first 200 chars…"}`
- `diarize-probe`: `{"ok":true,"speakers":2,"turns":9}`
- `enhance-probe`: `{"ok":true,"outputChars":1042,"hasSubtitle":true,"seconds":12.1}` (exit 2 still means Apple Intelligence unavailable; JSON is then `{"ok":false,"error":"apple-intelligence-unavailable"}`)
- `enhance-eval`: `{"ok":false,"cases":[{"name":"budget-sync","structure":true,"recall":true,"meta":true,"numbers":false,"subtitle":true}]}`
- `transcribe-eval`: `{"ok":true,"cases":[{"name":"meeting-fixture","wer":0.024,"maxWER":0.25,"passed":true}]}`

Exit codes are unchanged by `--json`: `0` success, `1` failure, `64` usage error (`diarize-probe`
also uses `66` for a missing file, `enhance-probe` uses `2` for Apple Intelligence unavailable,
`enhance-eval` uses `66`/`69` for a missing fixtures dir / unavailable Apple Intelligence,
`transcribe-eval` uses `66` for a missing fixtures dir).

## Observability: unified logging

RecapCore, RecapAudio, and RecapEnhancement log decision points (not per-sample/per-chunk noise)
via `os.Logger`, subsystem `com.gregfoster.recap`. Categories: `ProcessingQueue` (job
start/finish/fail, pause-reason transitions), `LibraryStorage` (save/load failures, error level
only), `MeetingRecorder` (start/pause/resume/stop, write-failure trips, spool salvage),
`Enhancement` (map/merge/reduce pass boundaries, retries). Meeting/transcript content is never
logged — dynamic strings are `.private` unless they're pure counts/durations.

Watch a running app's logs live:

```
log stream --level debug --predicate 'subsystem == "com.gregfoster.recap"'
```

## Conventions

- Swift Testing only (`import Testing`, `@Test`, `#expect`, `@Suite`) — zero XCTest, keep it that way.
- Swift 6 strict concurrency stays clean — no new `@unchecked Sendable` or `nonisolated(unsafe)` without a comment explaining why it's safe.
- Remove temporary debug launch args/flags before committing.
- Pure-logic extraction is the house pattern: factor logic out of framework-coupled types (e.g. `LiveTranscriptState`, `MixBuffer`, `MeetingGrouping`) and unit-test the extracted logic, rather than testing through the framework type.
