# Contributing to Recap

Thanks for your interest! Recap is early — issues and PRs are welcome.

## Setup

```sh
brew install xcodegen
./Scripts/bootstrap.sh
```

`Recap.xcodeproj` is generated and gitignored — never commit it. If you add files to the app target (anything under `Recap/`), re-run `xcodegen`. Files inside `Packages/` are picked up automatically.

## Project layout

- `Recap/` — thin app target: `@main`, assets, entitlements. Keep logic out of here.
- `Packages/RecapCore` — domain models, storage, search, processing queue. No UI, no hardware.
- `Packages/RecapAudio` — mic + system-audio capture, mixing.
- `Packages/RecapTranscription` — engine protocol, WhisperKit implementation, model manager.
- `Packages/RecapEnhancement` — on-device note enhancement (FoundationModels).
- `Packages/RecapUI` — all SwiftUI views and design tokens.

## Testing

Each package tests independently:

```sh
cd Packages/RecapCore && swift test
```

Or run every package's suite at once with `./Scripts/test.sh`.

Anything below the UI (storage, queue logic, chunking, download state machines) should be protocol-isolated and unit-tested. Audio-hardware and LLM layers are verified manually with the probes under `Packages/*/Sources/*Probe` (e.g. `capture-probe`, `transcribe-probe`, `diarize-probe`, `enhance-probe`, `enhance-eval` — see `Fixtures/README.md` and `CLAUDE.md` for exact commands) — describe your manual test in the PR.

## Pull requests

- One focused change per PR.
- Swift 6 strict concurrency must stay clean (no `@unchecked Sendable` without a comment explaining why).
- UI changes: match the design tokens in `RecapUI/DesignTokens.swift` and prefer native controls (real `List`, `NavigationSplitView`, `Picker`…) styled to fit, over custom lookalikes.
- Run `swift test` in touched packages before pushing; CI runs them all.
