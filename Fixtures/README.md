# Test fixtures

## Real-storage state injection (`-seed-dir <path>`)

`-seed-dir <path>` is a normal-mode (not `-fixtures`/`-soak`) launch argument for reproducing a
real-library bug deterministically. `<path>` must be a library folder in `LibraryStorage`'s on-disk
layout (one subfolder per meeting, e.g. `2026-01-01 Standup/meeting.json`, `notes.md`, ...). At
launch, the app copies that folder into a throwaway temp directory and runs the real storage stack
(`LibraryStorage`, search index, processing queue — nothing simulated) rooted at the copy. The
source directory is never modified, so the same seed dir can be reused for as many launches as
needed and always starts from the same state:

```sh
open <path>/Recap.app --args -seed-dir /path/to/problem-library
```

If the source is missing or unreadable, the app logs an error (`SeedLibrary` category) and falls
back to normal storage rather than failing to launch.

## Scenarios (`-fixtures <scenario>`)

The app's `-fixtures` launch argument takes an optional scenario name, resolved by
`FixtureScenario` in `Packages/RecapUI/Sources/RecapUI/Fixtures/FixtureScenarios.swift`. All
scenarios share the same zero-disk-write, no-processing-queue contract as plain `-fixtures`.
An unknown scenario name logs a warning and falls back to `default`.

```sh
open <path>/Recap.app --args -fixtures busy
```

- `default` (bare `-fixtures`) — today's small sample library: a handful of meetings spanning
  every status, one ready meeting with playable audio, a canned transcript, and notes. Also
  seeds `UpcomingStore` with the standard fixture calendar events (one ~19 minutes out), so
  both `NextMeetingBanner` and the menu bar popover's "Up next · Calendar" row
  (`-show-menubar-content`, AXID `menu-bar-up-next-record-button`) render.
- `empty` — first-run/empty library: no meetings, no queue activity, calendar not connected
  (`UpcomingStore.isAvailable` is `false`, so `NextMeetingBanner` never renders).
- `firstRunWithAgenda` — first-run/empty library, but calendar access IS granted with events
  today (the standard fixture events, one ~19 minutes out) — exercises `UpcomingStore` above an
  otherwise-empty library.
- `noMeetingsToday` — the `default` library, but calendar access is granted with zero events
  today — `UpcomingStore` authorized-but-empty, distinct from `empty`'s unauthorized state.
- `busy` — 20+ meetings spread across many weeks with every status represented, several with
  canned transcripts/notes — exercises list grouping and scroll performance.
- `processing` — several meetings actively transcribing/queued/enhancing, so the list's
  per-row progress states render real in-flight work.
- `error` — failed and recoverable job states: meetings with `.error` statuses, one
  `.needsModel`, and a paused queue summary with a pause reason.
- `recording` — a recording mid-flight: `router.screen == .recording`, so the app boots straight
  into the full-window `RecordingView` with the docked `SessionCapsule` (synthetic zero-hardware
  recorder, canned waveform levels, a couple of timed notes already saved).
- `firstRun` — onboarding not yet completed: the `FirstRunView` sheet renders over an empty
  library, with `TranscriptionSetupStore.phase` forced to a mid-download state so the
  "setting up transcription" card has something to show.
- `backupStuck` — the `error` library, with `BackupStatusStore.state` overridden to `.stuck` so
  the Library footer renders its amber "Backup paused" + "Fix…" treatment.
- `recovered` — a meeting parked at `.recovered` (crash-salvaged audio) sorted to the top of
  Today, alongside a couple of ordinary ready meetings — exercises the row's "Recap quit
  unexpectedly" layout and the ghost "Transcribe" action.
- `waitingForSetup` — meetings parked at `.needsModel` with `TranscriptionSetupStore.phase`
  overridden to `.downloading` — exercises the row's "Waiting for setup · N%" copy.
- `nextMeetingSoon` — the `default` library with the standard fixture calendar events (one
  ~19 minutes out), so `NextMeetingBanner` renders above the list (and, like `default`, the
  menu bar popover's "Up next · Calendar" row).
- `updateAvailable` — library update banner + menu-bar install row, no Sparkle.

Unit tests for each scenario's invariants live in
`Packages/RecapUI/Tests/RecapUITests/Fixtures/FixtureScenariosTests.swift`.

- `meeting-fixture.m4a` — 31s synthetic meeting speech (macOS `say`), used for
  repeatable manual verification of transcription without a real meeting:

  ```sh
  swift run --package-path Packages/RecapTranscription transcribe-probe Fixtures/meeting-fixture.m4a tiny
  swift run --package-path Packages/RecapTranscription transcribe-probe Fixtures/meeting-fixture.m4a tiny --stream
  ```

- `two-speaker-fixture.m4a` — 47s synthetic two-person meeting (macOS `say`,
  Samantha and Daniel alternating turns with 400 ms gaps), used to verify
  speaker diarization end to end. Expected: alternating turns, two speakers
  (an occasional spurious extra cluster on the final tail is a known
  diarization artifact):

  ```sh
  swift run --package-path Packages/RecapTranscription diarize-probe Fixtures/two-speaker-fixture.m4a
  ```

- `enhance/` — (transcript, notes, expectations) triples for the enhancement
  quality scorecard. Run after any prompt change:

  ```sh
  swift run --package-path Packages/RecapEnhancement enhance-eval --runs 2
  ```

  Metrics: structure (one bullet per note line), recall (expected specifics
  present), meta (no narration), numbers (no digits absent from the source —
  hallucination proxy), dupes ("Also discussed" restating a note bullet).

  To enhance a single transcript/notes pair manually (e.g. one of the
  `enhance/` cases) and inspect the raw output, use `enhance-probe` instead —
  needs Apple Intelligence enabled on this Mac (exits 2 if unavailable):

  ```sh
  swift run --package-path Packages/RecapEnhancement enhance-probe <transcript.json> [notes.md]
  ```

- `transcribe/` — (reference transcript, expectations) cases for the
  transcription quality scorecard, scored by word error rate (WER). Run after
  any model default or decoding-option change:

  ```sh
  swift run --package-path Packages/RecapTranscription transcribe-eval Fixtures/transcribe
  ```

  Each case dir has `reference.txt` (ground-truth transcript) and
  `expectations.json` (`{"maxWER": 0.25, "model": "tiny"}`). Case audio comes
  from an explicit `expectations.json` `"audio"` path, a case-local
  `audio.m4a`, or — for `meeting-fixture`, which has neither — the shared
  `Fixtures/meeting-fixture.m4a` above, so the binary isn't duplicated.
  `meeting-fixture/reference.txt` was drafted from a `base`-model transcription
  and lightly hand-corrected; **treat it as a first draft and verify it against
  the actual `say`-spoken script before trusting eval failures.** Exits
  nonzero if any case exceeds its `maxWER`. Not run in normal (push/PR) CI —
  see the `transcription-eval` job in `.github/workflows/ci.yml`, which runs
  nightly and on `workflow_dispatch`.
