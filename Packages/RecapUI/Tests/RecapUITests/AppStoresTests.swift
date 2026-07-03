import Foundation
import RecapCore
import RecapTranscription
import Testing
@testable import RecapUI

/// Fake `MeetingEventWatching`: `start()` returns a configurable grant
/// result and never touches EventKit; `fire(_:)` lets tests simulate a
/// meeting-shaped event starting.
@MainActor
private final class FakeCalendarWatcher: MeetingEventWatching {
    var grantsAccess = true
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private let onMeetingStarting: (CalendarEventSnapshot) -> Void

    init(onMeetingStarting: @escaping (CalendarEventSnapshot) -> Void) {
        self.onMeetingStarting = onMeetingStarting
    }

    func start() async -> Bool {
        startCallCount += 1
        return grantsAccess
    }

    func stop() {
        stopCallCount += 1
    }

    func fire(_ event: CalendarEventSnapshot) {
        onMeetingStarting(event)
    }
}

/// Fake `RecordPrompting`: records every event it's asked to prompt for.
@MainActor
private final class FakeRecordPrompter: RecordPrompting {
    private(set) var promptedEvents: [CalendarEventSnapshot] = []

    func promptToRecord(_ event: CalendarEventSnapshot) {
        promptedEvents.append(event)
    }
}

@MainActor
@Suite struct AppStoresTests {
    private func makeStorage() -> LibraryStorage {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStoresTests-\(UUID().uuidString)")
        return LibraryStorage(rootURL: root)
    }

    private func makeSettings() -> SettingsStore {
        let suite = UserDefaults(suiteName: "recap.tests.appstores.\(UUID().uuidString)")!
        suite.removePersistentDomain(forName: suite.dictionaryRepresentation().description)
        return SettingsStore(defaults: suite)
    }

    private func makeIndex() -> SearchIndex {
        try! SearchIndex()
    }

    /// Full graph with real disk-backed storage, matching what `AppStoresTests`
    /// scenarios need (export/backfill behavior requires `storage != nil`).
    private func makeStores(
        settings: SettingsStore? = nil,
        storage: LibraryStorage? = nil,
        exportDebounce: Duration = .milliseconds(50),
        makeCalendarWatcher: ((@escaping @MainActor (CalendarEventSnapshot) -> Void) -> MeetingEventWatching)? = nil,
        makeRecordPrompter: ((@escaping @MainActor (CalendarEventSnapshot) -> Void) -> RecordPrompting)? = nil
    ) -> (AppStores, LibraryStorage, SettingsStore, LibraryChangeBus) {
        let settings = settings ?? makeSettings()
        let storage = storage ?? makeStorage()
        let changeBus = LibraryChangeBus()
        let index = makeIndex()
        let library = LibraryStore(storage: storage, index: index, changeBus: changeBus)

        let stores: AppStores
        if let makeCalendarWatcher, let makeRecordPrompter {
            stores = AppStores(
                settings: settings, storage: storage, library: library,
                models: WhisperModelManager(), session: MeetingSessionStore(), queue: nil,
                changeBus: changeBus, exportDebounce: exportDebounce,
                makeCalendarWatcher: makeCalendarWatcher, makeRecordPrompter: makeRecordPrompter
            )
        } else {
            stores = AppStores(
                settings: settings, storage: storage, library: library,
                models: WhisperModelManager(), session: MeetingSessionStore(), queue: nil,
                changeBus: changeBus, exportDebounce: exportDebounce
            )
        }
        return (stores, storage, settings, changeBus)
    }

    private func makeReadyMeeting(in storage: LibraryStorage, title: String = "Standup") throws -> MeetingRecord {
        try storage.create(Meeting(title: title, date: .now, status: .ready))
    }

    /// Polls for a directory to appear with at least one entry, up to
    /// `timeout`. Exports run on detached background tasks after the
    /// debounce window, so a single fixed sleep is prone to flaking under
    /// parallel test load — poll instead of guessing one wait long enough.
    private func waitForNonEmptyDirectory(
        at url: URL, timeout: Duration = .milliseconds(1_000)
    ) async throws -> [String] {
        try await waitForDirectory(at: url, timeout: timeout) { !$0.isEmpty }
    }

    private func waitForDirectory(
        at url: URL, timeout: Duration = .milliseconds(1_000),
        until predicate: ([String]) -> Bool
    ) async throws -> [String] {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: url.path), predicate(entries) {
                return entries
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
    }

    // MARK: 1. Change-bus debounced export

    @Test func changeBusPostDebouncesThenExportsToObsidian() async throws {
        let vaultDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObsidianVault-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: vaultDir) }

        let (stores, storage, settings, changeBus) = makeStores()
        settings.syncsToObsidian = true
        settings.obsidianVaultPath = vaultDir.path

        let record = try makeReadyMeeting(in: storage)
        _ = stores // keep the consumer task alive via the strong reference below

        // The change-bus consumer subscribes from a freshly spawned Task in
        // `init`; give it a beat to register before posting, since
        // `LibraryChangeBus.post` doesn't buffer for late subscribers.
        try await Task.sleep(for: .milliseconds(20))
        changeBus.post(.meetingChanged(record.meeting.id))

        let exported = try await waitForNonEmptyDirectory(at: vaultDir)
        #expect(!exported.isEmpty)
    }

    @Test func rapidChangeBusPostsCoalesceIntoOneExportWindow() async throws {
        let vaultDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObsidianVault-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: vaultDir) }

        let (stores, storage, settings, changeBus) = makeStores(exportDebounce: .milliseconds(150))
        settings.syncsToObsidian = true
        settings.obsidianVaultPath = vaultDir.path

        let record = try makeReadyMeeting(in: storage)
        _ = stores // keep the consumer task alive via the strong reference

        // See changeBusPostDebouncesThenExportsToObsidian: give the consumer
        // Task a beat to subscribe before the first post.
        try await Task.sleep(for: .milliseconds(20))
        changeBus.post(.meetingChanged(record.meeting.id))
        // Posted again inside the debounce window: this should cancel and
        // restart the sleep, so nothing has exported yet at +80ms.
        try await Task.sleep(for: .milliseconds(80))
        changeBus.post(.meetingChanged(record.meeting.id))

        try await Task.sleep(for: .milliseconds(90))
        #expect(!FileManager.default.fileExists(atPath: vaultDir.path))

        let exported = try await waitForNonEmptyDirectory(at: vaultDir)
        #expect(exported.count == 1)
    }

    // MARK: 2. exportAllReadyMeetingsToObsidian backfill

    @Test func exportAllReadyMeetingsToObsidianExportsOnlyReadyOnes() async throws {
        let vaultDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObsidianVault-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: vaultDir) }

        let (stores, storage, settings, _) = makeStores()
        settings.syncsToObsidian = true
        settings.obsidianVaultPath = vaultDir.path

        _ = try storage.create(Meeting(title: "Ready one", date: .now, status: .ready))
        _ = try storage.create(Meeting(title: "Ready two", date: .now, status: .ready))
        _ = try storage.create(Meeting(title: "Still recording", date: .now, status: .recording))
        stores.library.reload()

        stores.exportAllReadyMeetingsToObsidian()

        let exported = try await waitForDirectory(at: vaultDir) { $0.count == 2 }
        #expect(exported.count == 2)
    }

    @Test func exportAllReadyMeetingsToObsidianNoOpWhenDisabledOrPathEmpty() async throws {
        let (stores, storage, settings, _) = makeStores()
        settings.syncsToObsidian = false
        settings.obsidianVaultPath = ""
        _ = try storage.create(Meeting(title: "Ready one", date: .now, status: .ready))
        stores.library.reload()

        // Should not crash and should not attempt any export (no vault path
        // to check — absence of a crash and immediate return is the contract).
        stores.exportAllReadyMeetingsToObsidian()
        try await Task.sleep(for: .milliseconds(100))
    }

    // MARK: 3. backfillMirrorBackup

    @Test func backfillMirrorBackupMirrorsReadyMeetings() async throws {
        let mirrorDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MirrorBackup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: mirrorDir) }

        let (stores, storage, settings, _) = makeStores()
        settings.mirrorBackupEnabled = true
        settings.mirrorFolderPath = mirrorDir.path

        _ = try storage.create(Meeting(title: "Ready one", date: .now, status: .ready))
        stores.library.reload()

        stores.backfillMirrorBackup()

        let mirrored = try await waitForNonEmptyDirectory(at: mirrorDir)
        #expect(!mirrored.isEmpty)
    }

    // MARK: 4. Calendar auto-record modes

    @Test func promptModeCallsPrompterWhenEventStarts() throws {
        var fakeWatcher: FakeCalendarWatcher?
        var fakePrompter: FakeRecordPrompter?
        let (stores, _, settings, _) = makeStores(
            makeCalendarWatcher: { onStarting in
                let watcher = FakeCalendarWatcher(onMeetingStarting: onStarting)
                fakeWatcher = watcher
                return watcher
            },
            makeRecordPrompter: { _ in
                let prompter = FakeRecordPrompter()
                fakePrompter = prompter
                return prompter
            }
        )
        settings.calendarAutoRecord = .prompt
        stores.applyCalendarAutoRecordSetting()
        _ = fakeWatcher

        let event = CalendarEventSnapshot(id: "1", title: "Standup", start: .now, end: .now.addingTimeInterval(1_800))
        stores.meetingEventStarting(event)

        #expect(fakePrompter?.promptedEvents == [event])
    }

    @Test func autoModeCreatesLibraryMeetingWithEventTitle() throws {
        let (stores, _, settings, _) = makeStores(
            makeCalendarWatcher: { onStarting in FakeCalendarWatcher(onMeetingStarting: onStarting) },
            makeRecordPrompter: { _ in FakeRecordPrompter() }
        )
        settings.calendarAutoRecord = .auto
        stores.applyCalendarAutoRecordSetting()

        let event = CalendarEventSnapshot(
            id: "2", title: "Roadmap review", start: .now, end: .now.addingTimeInterval(1_800),
            otherAttendees: ["Maya"]
        )
        stores.meetingEventStarting(event)

        #expect(stores.library.meetings.contains { $0.meeting.title == "Roadmap review" })
    }

    @Test func offModeIgnoresStartingEvents() throws {
        var fakePrompter: FakeRecordPrompter?
        let (stores, _, settings, _) = makeStores(
            makeCalendarWatcher: { onStarting in FakeCalendarWatcher(onMeetingStarting: onStarting) },
            makeRecordPrompter: { _ in
                let prompter = FakeRecordPrompter()
                fakePrompter = prompter
                return prompter
            }
        )
        settings.calendarAutoRecord = .off

        let meetingCountBefore = stores.library.meetings.count
        let event = CalendarEventSnapshot(id: "3", title: "Ignored", start: .now, end: .now.addingTimeInterval(1_800))
        stores.meetingEventStarting(event)

        #expect(fakePrompter?.promptedEvents.isEmpty != false)
        #expect(stores.library.meetings.count == meetingCountBefore)
    }

    @Test func alreadyRecordingIgnoresStartingEvents() async throws {
        var fakePrompter: FakeRecordPrompter?
        let (stores, _, settings, _) = makeStores(
            makeCalendarWatcher: { onStarting in FakeCalendarWatcher(onMeetingStarting: onStarting) },
            makeRecordPrompter: { _ in
                let prompter = FakeRecordPrompter()
                fakePrompter = prompter
                return prompter
            }
        )
        settings.calendarAutoRecord = .prompt
        stores.applyCalendarAutoRecordSetting()

        stores.startRecording(title: "In progress")
        // startRecording kicks off an async Task to actually start capture;
        // isRecording flips synchronously via session.start's guard check —
        // give it a brief moment to settle.
        try await Task.sleep(for: .milliseconds(100))

        let event = CalendarEventSnapshot(id: "4", title: "Should be ignored", start: .now, end: .now.addingTimeInterval(1_800))
        stores.meetingEventStarting(event)

        #expect(fakePrompter?.promptedEvents.isEmpty != false)
    }

    @Test func applyCalendarAutoRecordSettingSurfacesAccessDenied() async throws {
        let (stores, _, settings, _) = makeStores(
            makeCalendarWatcher: { onStarting in
                let watcher = FakeCalendarWatcher(onMeetingStarting: onStarting)
                watcher.grantsAccess = false
                return watcher
            },
            makeRecordPrompter: { _ in FakeRecordPrompter() }
        )
        settings.calendarAutoRecord = .prompt
        stores.applyCalendarAutoRecordSetting()

        try await Task.sleep(for: .milliseconds(100))
        #expect(stores.calendarAccessDenied == true)

        settings.calendarAutoRecord = .off
        stores.applyCalendarAutoRecordSetting()
        #expect(stores.calendarAccessDenied == false)
    }

    // MARK: 5. showMeeting

    @Test func showMeetingRoutesSectionAndSelection() throws {
        let (stores, _, _, _) = makeStores()
        let id = UUID()
        stores.showMeeting(id)
        #expect(stores.router.section == .library)
        #expect(stores.library.selectedMeetingID == id)
    }

    // MARK: 6. importAudioFiles no-op in fixture graph

    @Test func importAudioFilesNoOpWithNilStorageOrQueue() throws {
        let library = LibraryStore.fixture()
        let stores = AppStores(library: library)
        let before = stores.library.meetings.count

        stores.importAudioFiles([URL(fileURLWithPath: "/dev/null/does-not-exist.m4a")])

        #expect(stores.library.meetings.count == before)
    }

    // Note: startRecording/stopRecording orchestration is not tested here —
    // it requires the MeetingSessionStore -> MeetingRecorder seam.
    // covered after recorder seam
}
