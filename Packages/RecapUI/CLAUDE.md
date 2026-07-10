# RecapUI

SwiftUI views, design tokens, and `@Observable` stores — the only package depending on all of
RecapCore, RecapAudio, RecapTranscription, and RecapEnhancement. Keep logic in stores, views thin.

## Key files
- `AppStores.swift` — composition root: app-lifetime store graph, constructed once by the App
  struct; wires per-subsystem coordinators (`RecordingController`, `ImportCoordinator`,
  `AutoRecordCoordinator` — home of the `MeetingEventWatching` seam over `CalendarWatcher` —
  `BackupStatusStore`, `ChangeBusConsumer`) and keeps thin forwarders for their
  pre-decomposition entry points (`startRecording()` etc.).
- `LibraryStore.swift` — meeting list state; owns fixture data for `-fixtures` mode
  (`fixtureTranscripts`/`fixtureNotes`/`fixtureEnhancedNotes` dictionaries, no disk writes).
- `TranscriptPane.swift`, `LibraryView.swift`, `MeetingDetailView.swift` — largest views (each
  400-650 lines); transcript rendering, meeting list, and meeting detail respectively.
- `QueueStore.swift` — UI-facing view over RecapCore's `ProcessingQueue`.
- `MeetingSessionStore.swift` — active recording session state machine.
- `DesignTokens.swift` — `Tokens` enum; dynamic light/dark colors via `NSColor(name:dynamicProvider:)`.
- `FixtureAudio.swift` — synthesizes a short silent `.m4a` for `-fixtures` mode (temp dir, no
  writes to the real library).
- `SettingsStore.swift` — persisted app settings/preferences.

## Test
`swift test --package-path Packages/RecapUI` (largest suite, 26 files). No `--filter` needed
usually; use one for iterating on a single store, e.g. `--filter LibraryStore`.

## Folder map

`Sources/RecapUI/` and `Tests/RecapUITests/` are organized into matching feature folders
(SwiftPM globs `Sources/**`, so this is a pure layout convention, not a module boundary):

- `App/` — app-lifetime store graph, root view + router, first-run onboarding (`FirstRunView`),
  launch configuration/routes, update/completion notifications.
- `Library/` — meeting list (footer, next-meeting banner), meeting detail (summary disclosure),
  transcript pane, notes, search.
- `Queue/` — processing queue store and processor settings snapshot (no views of its own).
- `Recording/` — active recording session, full-window `RecordingView`, `SessionCapsule`,
  floating background capsule, preflight checks.
- `Calendar/` — calendar watching, upcoming meetings, meeting-start nudge.
- `Import/` — audio file import.
- `MenuBar/` — menu bar extra popover content.
- `Export/` — folder-mirror backup status store.
- `Settings/` — settings store, the one-page Settings window, permissions, launch at login.
- `Fixtures/` — fixture scenarios + synthetic audio for `-fixtures` mode.
- `Shared/` — design tokens, toasts, global hotkey, small reusable views.

## Gotchas
- Dynamic `NSColor.resolve(in:)` (used under `Tokens`' dynamic colors) deadlocks off-main —
  any test touching it must be `@MainActor` (see `RecapUITests.swift`, `PermissionsModelTests.swift`).
- Fixture data lives in `LibraryStore`'s fixture section plus `FixtureAudio.swift` — new UI
  surfaces need fixture state wired here or QA/screenshots can't exercise them.
- `-fixtures` launch arg swaps in sample meetings + ephemeral settings, no disk writes, no
  processing queue; `-show-menubar-content` (with `-fixtures`) exposes `MenuBarView`'s popover
  content in a screenshot-able window.
- `-fixtures <scenario>` selects a named graph from `Fixtures/FixtureScenarios.swift`
  (`default`/`empty`/`firstRunWithAgenda`/`noMeetingsToday`/`busy`/`processing`/`error`/
  `recording`/`firstRun`/`backupStuck`/`recovered`/`waitingForSetup`/`nextMeetingSoon`/
  `updateAvailable`; unknown names log a warning and fall back to `default`) —
  `LibraryStore.fixture()` is just
  `FixtureScenario.default.library` kept as the legacy no-arg entry point every preview/test
  already calls. See `Fixtures/README.md` for the scenario list.
