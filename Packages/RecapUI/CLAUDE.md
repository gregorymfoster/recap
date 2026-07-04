# RecapUI

SwiftUI views, design tokens, and `@Observable` stores — the only package depending on all of
RecapCore, RecapAudio, RecapTranscription, and RecapEnhancement. Keep logic in stores, views thin.

## Key files
- `AppStores.swift` (663 lines, largest) — app-lifetime store graph, constructed once by the
  App struct; wires real services together (e.g. `MeetingEventWatching` seam over
  `CalendarWatcher` for testable calendar injection).
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

- `App/` — app-lifetime store graph, root view, onboarding, update/completion notifications.
- `Library/` — meeting list, meeting detail, transcript pane, notes, search, playback.
- `Queue/` — processing queue UI and processor settings snapshot.
- `Recording/` — active recording session, pill, floating capsule, preflight checks.
- `Calendar/` — calendar watching, upcoming meetings, meeting-start nudge.
- `Import/` — audio file import.
- `MenuBar/` — menu bar extra popover content.
- `Settings/` — settings store, all Settings tabs, permissions, model manager, onboarding helpers.
- `Fixtures/` — synthetic audio for `-fixtures` mode.
- `Shared/` — design tokens, toasts, global hotkey, small reusable views.

## Gotchas
- Dynamic `NSColor.resolve(in:)` (used under `Tokens`' dynamic colors) deadlocks off-main —
  any test touching it must be `@MainActor` (see `RecapUITests.swift`, `PermissionsModelTests.swift`).
- Fixture data lives in `LibraryStore`'s fixture section plus `FixtureAudio.swift` — new UI
  surfaces need fixture state wired here or QA/screenshots can't exercise them.
- `-fixtures` launch arg swaps in sample meetings + ephemeral settings, no disk writes, no
  processing queue; `-show-menubar-content` (with `-fixtures`) exposes `MenuBarView`'s popover
  content in a screenshot-able window.
