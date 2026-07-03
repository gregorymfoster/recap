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
        at url: URL, timeout: Duration = .seconds(3)
    ) async throws -> [String] {
        try await waitForDirectory(at: url, timeout: timeout) { !$0.isEmpty }
    }

    private func waitForDirectory(
        at url: URL, timeout: Duration = .seconds(3),
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

    /// Posts `change` on `changeBus`, then keeps re-posting it (spaced
    /// `retryInterval` apart, which must be longer than the store's
    /// `exportDebounce` or every retry would cancel the previous post's
    /// still-pending debounce Task before it can fire) until `vaultDir`
    /// gets an entry or `timeout` elapses. Guards against the very first
    /// post landing before the change-bus consumer's `Task` has actually
    /// been scheduled and subscribed — `LibraryChangeBus.post` silently
    /// drops changes with no live subscriber, and under CI-runner
    /// contention a freshly spawned `Task` can take well over a few tens of
    /// milliseconds to run its first iteration.
    private func withRetriedPost(
        _ changeBus: LibraryChangeBus, _ change: LibraryChange, until vaultDir: URL,
        retryInterval: Duration = .seconds(1), timeout: Duration = .seconds(10)
    ) async throws -> [String] {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            changeBus.post(change)
            let entries = try await waitForDirectory(at: vaultDir, timeout: retryInterval) { !$0.isEmpty }
            if !entries.isEmpty {
                return entries
            }
        }
        return (try? FileManager.default.contentsOfDirectory(atPath: vaultDir.path)) ?? []
    }

    /// Blocks until `stores`'s change-bus consumer `Task` (spawned in
    /// `init`) has demonstrably subscribed, by posting a throwaway change
    /// for an unrelated meeting and waiting for its mirror-backup export to
    /// land in a scratch directory — then cleans up. Deliberately uses the
    /// *mirror* toggle rather than Obsidian so it never shares mutable
    /// settings state with a caller that's mid-way through asserting
    /// Obsidian export timing: `runEnabledExporters` reads `settings` live
    /// at fire time, so flipping a shared `obsidianVaultPath` back and forth
    /// while a canary debounce Task might still be in flight is itself a
    /// race. Tests that assert timing around a real post (e.g. "no export
    /// before the debounce window elapses") need the consumer warmed up
    /// first without the warm-up racing the assertion; a fixed sleep isn't
    /// reliable under CI-runner contention where the consumer's Task may not
    /// run its first loop iteration for a while.
    private func waitForConsumerSubscribed(
        stores: AppStores, changeBus: LibraryChangeBus, storage: LibraryStorage, settings: SettingsStore
    ) async throws {
        let canaryDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Canary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: canaryDir) }
        precondition(!settings.mirrorBackupEnabled, "warm-up uses the mirror toggle; caller must not also use it")
        settings.mirrorBackupEnabled = true
        settings.mirrorFolderPath = canaryDir.path
        let canary = try makeReadyMeeting(in: storage, title: "Canary")
        _ = try await withRetriedPost(changeBus, .meetingChanged(canary.meeting.id), until: canaryDir)
        settings.mirrorBackupEnabled = false
        settings.mirrorFolderPath = ""
        // Give any debounce Task that was mid-flight when the last
        // successful poll observed the export a moment to actually finish
        // and get removed from exportDebounceTasks, so it can't race a
        // later post for a different meeting ID (each meeting has its own
        // debounce entry, so this is a belt-and-suspenders margin, not a
        // strict requirement).
        try await Task.sleep(for: .milliseconds(50))
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
        // `init`, and `LibraryChangeBus.post` doesn't buffer for late
        // subscribers — a post before the consumer's `for await` loop has
        // actually started running is silently dropped. A fixed sleep
        // before the first post isn't reliable on a loaded CI runner (the
        // Task may not get scheduled for a while), so re-post on an interval
        // shorter than the export debounce until the export lands or we
        // time out; once the consumer is subscribed, one of these posts is
        // guaranteed to be seen.
        let exported = try await withRetriedPost(
            changeBus, .meetingChanged(record.meeting.id), until: vaultDir
        )
        #expect(!exported.isEmpty)
    }

    @Test func rapidChangeBusPostsCoalesceIntoOneExportWindow() async throws {
        let vaultDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObsidianVault-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: vaultDir) }

        // A generous debounce (vs. the 50ms used elsewhere) gives wide
        // margins around the mid-sequence checks below, so CPU contention
        // under parallel test execution can't shrink the gap between "second
        // post lands" and "debounce would have elapsed" into noise.
        let debounce = Duration.milliseconds(500)
        let (stores, storage, settings, changeBus) = makeStores(exportDebounce: debounce)
        let record = try makeReadyMeeting(in: storage)
        _ = stores // keep the consumer task alive via the strong reference

        // Warm up the consumer against a throwaway mirror destination first
        // — before turning on Obsidian sync at vaultDir below — so the
        // timed sequence isn't itself racing the consumer's Task getting
        // scheduled, and so the warm-up's own export can't land in vaultDir
        // (see waitForConsumerSubscribed).
        try await waitForConsumerSubscribed(stores: stores, changeBus: changeBus, storage: storage, settings: settings)

        settings.syncsToObsidian = true
        settings.obsidianVaultPath = vaultDir.path

        changeBus.post(.meetingChanged(record.meeting.id))
        // Posted again well inside the debounce window: this should cancel
        // and restart the sleep, so nothing has exported yet shortly after.
        try await Task.sleep(for: debounce / 4)
        changeBus.post(.meetingChanged(record.meeting.id))

        // Checked at roughly half the (restarted) window — comfortably
        // before it can have elapsed even under heavy scheduling jitter.
        try await Task.sleep(for: debounce / 2)
        #expect(!FileManager.default.fileExists(atPath: vaultDir.path))

        let exported = try await waitForNonEmptyDirectory(at: vaultDir, timeout: .seconds(5))
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
