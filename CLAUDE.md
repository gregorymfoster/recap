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
- `swift run --package-path Packages/RecapTranscription transcribe-probe Fixtures/meeting-fixture.m4a tiny [--stream]` — downloads the model on first run.
- `swift run --package-path Packages/RecapTranscription diarize-probe Fixtures/two-speaker-fixture.m4a`
- `swift run --package-path Packages/RecapEnhancement enhance-probe <transcript.json> [notes.md]` — needs Apple Intelligence; exits 2 when unavailable.
- `swift run --package-path Packages/RecapEnhancement enhance-eval [--runs N]` — scores `Fixtures/enhance/` cases; run before/after any enhancement prompt change.

See `Fixtures/README.md` for fixture details and expected output.

## Conventions

- Swift Testing only (`import Testing`, `@Test`, `#expect`, `@Suite`) — zero XCTest, keep it that way.
- Swift 6 strict concurrency stays clean — no new `@unchecked Sendable` or `nonisolated(unsafe)` without a comment explaining why it's safe.
- Remove temporary debug launch args/flags before committing.
- Pure-logic extraction is the house pattern: factor logic out of framework-coupled types (e.g. `LiveTranscriptState`, `MixBuffer`, `MeetingGrouping`) and unit-test the extracted logic, rather than testing through the framework type.
