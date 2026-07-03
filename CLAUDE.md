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

- All packages: `./Scripts/test.sh` (~30s total; extra args pass through, e.g. `./Scripts/test.sh --filter LibraryStorage`).
- One package: `swift test --package-path Packages/RecapCore`.
- App build: `xcodegen && xcodebuild build -project Recap.xcodeproj -scheme Recap -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`.

## Run the app with fixture data

Build, then launch with the `-fixtures` arg: `open <path>/Recap.app --args -fixtures`, or run the
`Recap (Fixtures)` scheme in Xcode. Swaps in sample meetings and ephemeral settings — no disk
writes, no processing queue. Use for UI work and screenshots.

## Verification probes

Real hardware/models — the manual-verification layer for capture/transcription/enhancement
changes. Not run in CI.

- `swift run --package-path Packages/RecapAudio capture-probe 5` — records mic + system audio for N seconds. Needs mic permission. Flags: `--list-devices`, `--device <uid>`, `--pause-test`.
- `swift run --package-path Packages/RecapTranscription transcribe-probe Fixtures/meeting-fixture.m4a tiny [--stream] [--language <code>] [--json]` — downloads the model on first run.
- `swift run --package-path Packages/RecapTranscription diarize-probe Fixtures/two-speaker-fixture.m4a [--json]`
- `swift run --package-path Packages/RecapEnhancement enhance-probe <transcript.json> [notes.md]` — needs Apple Intelligence; exits 2 when unavailable.
- `swift run --package-path Packages/RecapEnhancement enhance-eval [--runs N] [--json]` — scores `Fixtures/enhance/` cases; run before/after any enhancement prompt change.
- `swift run --package-path Packages/RecapTranscription transcribe-eval [--json] Fixtures/transcribe` — scores `Fixtures/transcribe/` cases by word error rate; run before/after any model default or decoding-option change. Not run in normal CI — runs nightly + on `workflow_dispatch` (see `transcription-eval` job in `.github/workflows/ci.yml`).

See `Fixtures/README.md` for fixture details and expected output.

### `--json` output (transcribe-probe, diarize-probe, enhance-eval, transcribe-eval)

Human-readable output is unchanged by default. With `--json`, each probe additionally prints
exactly one JSON object as the **last line** of stdout, so agents can parse a result without
scraping prose:

- `transcribe-probe`: `{"ok":true,"mode":"file","utterances":12,"duration":31.2,"text":"…first 200 chars…"}`
- `diarize-probe`: `{"ok":true,"speakers":2,"turns":9}`
- `enhance-eval`: `{"ok":false,"cases":[{"name":"budget-sync","structure":true,"recall":true,"meta":true,"numbers":false}]}`
- `transcribe-eval`: `{"ok":true,"cases":[{"name":"meeting-fixture","wer":0.024,"maxWER":0.25,"passed":true}]}`

Exit codes are unchanged by `--json`: `0` success, `1` failure, `64` usage error (`diarize-probe`
also uses `66` for a missing file, `enhance-eval` uses `66`/`69` for a missing fixtures dir /
unavailable Apple Intelligence, `transcribe-eval` uses `66` for a missing fixtures dir).

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
