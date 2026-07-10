# RecapCore

Domain models, on-disk storage, search, and the processing queue. No UI (SwiftUI/AppKit),
no hardware access (mic/audio/ML) — those live in RecapAudio/RecapTranscription/RecapEnhancement.
This is the package every other package depends on; engine/store protocols consumed
elsewhere are defined here.

## Key files
- `LibraryStorage.swift` — reads/writes the on-disk meeting library (`~/Recap`, one folder
  per meeting: audio.m4a, notes.md, enhanced.md, transcript.json, meeting.json, speakers.json).
  Folder tree is the source of truth.
- `Meeting.swift` — the core `Meeting` model.
- `ProcessingQueue.swift` — serial transcribe/enhance job queue (`ProcessingJob`, one job kind at a time).
- `LibraryChangeBus.swift` — fan-out `AsyncStream` bus; `LibraryStore` posts here after every
  persisted change so mirror/sync consumers (folder mirror, future CloudKit) subscribe once.
- `Protocols.swift` — cross-package contracts: `AudioChunk`, `TranscriptionUpdate`, engine protocols
  implemented by RecapTranscription/RecapEnhancement.
- `SearchIndex.swift` — GRDB-backed full-text search (`SearchHit`).
- `MeetingDetectionRules.swift` / `MeetingEventDetection.swift` — calendar/call-app meeting detection logic.
- `FolderMirrorExporter.swift` — `LibraryChangeBus` consumer.

## Test
`swift test --package-path Packages/RecapCore` (or `./Scripts/test.sh --filter LibraryStorage`
for a subset). GRDB dependency; no simulator/hardware needed, runs in seconds.

## Gotchas
- Only package with an external SPM dependency (GRDB.swift) — keep it that way; hardware/ML
  deps belong in their own packages.
- Adding a new source file here can break sibling packages' incremental builds ("cannot find
  type in scope"). Fix is `swift package --package-path Packages/<failing-pkg> clean`, not a code change.
- `LibraryChange.meetingDeleted` is defined but not posted anywhere yet (no delete affordance).
