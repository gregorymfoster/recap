import Foundation
import RecapCore
import Testing
@testable import RecapUI

/// Thread-safe capture of `mirrorRecord` invocations from the store's
/// detached mirror tasks. `@unchecked Sendable` is safe: every access to
/// `records` goes through `lock`.
private final class MirrorLog: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [UUID] = []
    /// Meeting IDs that should fail, with the error to throw. Set before
    /// the store is exercised; reads race-free under `lock` too.
    private var failures: [UUID: MirrorError] = [:]
    private var failAll: MirrorError?

    func failEverything(with error: MirrorError?) {
        lock.lock()
        defer { lock.unlock() }
        failAll = error
    }

    func fail(_ id: UUID, with error: MirrorError) {
        lock.lock()
        defer { lock.unlock() }
        failures[id] = error
    }

    func mirror(_ record: MeetingRecord) throws {
        lock.lock()
        let failure = failures[record.meeting.id] ?? failAll
        if failure == nil { records.append(record.meeting.id) }
        lock.unlock()
        if let failure { throw failure }
    }

    var mirrored: [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }
}

@MainActor
@Suite(.serialized) struct BackupStatusStoreTests {
    private func makeSettings() -> SettingsStore {
        let suite = UserDefaults(suiteName: "recap.tests.backupstatus.settings.\(UUID().uuidString)")!
        return SettingsStore(defaults: suite)
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "recap.tests.backupstatus.\(UUID().uuidString)")!
    }

    private func makeStorage() -> LibraryStorage {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupStatusStoreTests-\(UUID().uuidString)")
        return LibraryStorage(rootURL: root)
    }

    private func makeLibrary(storage: LibraryStorage) -> LibraryStore {
        LibraryStore(storage: storage, index: try! SearchIndex(), changeBus: LibraryChangeBus())
    }

    private func makeStore(
        settings: SettingsStore, library: LibraryStore, storage: LibraryStorage?,
        defaults: UserDefaults, log: MirrorLog
    ) -> BackupStatusStore {
        BackupStatusStore(
            settings: settings, library: library, storage: storage, defaults: defaults,
            mirrorRecord: { record, _ in try log.mirror(record) }
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(10), _ condition: () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func isOK(_ state: BackupState) -> Bool {
        if case .ok = state { return true }
        return false
    }

    private func isStuck(_ state: BackupState) -> Bool {
        if case .stuck = state { return true }
        return false
    }

    // MARK: Disabled

    @Test func disabledWhenToggleIsOff() throws {
        let settings = makeSettings()
        settings.mirrorBackupEnabled = false
        let storage = makeStorage()
        let store = makeStore(
            settings: settings, library: makeLibrary(storage: storage), storage: storage,
            defaults: makeDefaults(), log: MirrorLog()
        )
        #expect(store.state == .disabled)
        // backfill is a no-op while disabled — still .disabled afterward.
        store.backfill()
        #expect(store.state == .disabled)
    }

    // MARK: Backfill

    @Test func backfillMirrorsPendingReadyMeetingsAndEndsOK() async throws {
        let settings = makeSettings()
        settings.mirrorBackupEnabled = true
        settings.mirrorFolderPath = "/tmp/wherever" // fake mirror never touches it
        let storage = makeStorage()
        let library = makeLibrary(storage: storage)
        let alreadyBackedUpDate = Date(timeIntervalSince1970: 2_000)
        _ = try storage.create(Meeting(title: "Needs backup A", date: .now, status: .ready))
        _ = try storage.create(Meeting(title: "Needs backup B", date: .now, status: .ready))
        _ = try storage.create(Meeting(title: "Still recording", date: .now, status: .recording))
        let done = try storage.create(
            Meeting(title: "Already backed up", date: .now, status: .ready, lastBackupDate: alreadyBackedUpDate)
        )
        library.reload()

        let log = MirrorLog()
        let store = makeStore(settings: settings, library: library, storage: storage, defaults: makeDefaults(), log: log)

        store.backfill()
        await waitUntil { self.isOK(store.state) }

        // Only the two pending ready meetings were mirrored — not the
        // recording one, not the already-backed-up one.
        #expect(log.mirrored.count == 2)
        #expect(!log.mirrored.contains(done.meeting.id))

        // Every mirrored meeting got its lastBackupDate persisted...
        let backedUp = library.meetings.filter { $0.meeting.lastBackupDate != nil }
        #expect(backedUp.count == 3)

        // ...and the aggregate state is ok(latest of them).
        guard case .ok(let lastBackupAt) = store.state else {
            Issue.record("expected .ok, got \(store.state)")
            return
        }
        let latest = library.meetings.compactMap(\.meeting.lastBackupDate).max()
        #expect(lastBackupAt == latest)
        #expect(lastBackupAt != alreadyBackedUpDate) // fresh backups are newer
    }

    @Test func okWithNilDateWhenNothingEverBackedUp() throws {
        let settings = makeSettings()
        settings.mirrorBackupEnabled = true
        settings.mirrorFolderPath = "/tmp/wherever"
        let storage = makeStorage()
        let library = makeLibrary(storage: storage)
        let store = makeStore(
            settings: settings, library: library, storage: storage, defaults: makeDefaults(), log: MirrorLog()
        )
        #expect(store.state == .ok(lastBackupAt: nil))
    }

    // MARK: Stuck

    @Test func failedBackfillSetsStuckOnceAndPersistsSince() async throws {
        let settings = makeSettings()
        settings.mirrorBackupEnabled = true
        settings.mirrorFolderPath = "/tmp/wherever"
        let storage = makeStorage()
        let library = makeLibrary(storage: storage)
        _ = try storage.create(Meeting(title: "Will fail", date: .now, status: .ready))
        library.reload()

        let log = MirrorLog()
        log.failEverything(with: .destinationUnreachable)
        let defaults = makeDefaults()
        let store = makeStore(settings: settings, library: library, storage: storage, defaults: defaults, log: log)

        store.backfill()
        await waitUntil { self.isStuck(store.state) }

        guard case .stuck(let reason, let since) = store.state else {
            Issue.record("expected .stuck, got \(store.state)")
            return
        }
        #expect(reason == .folderUnreachable)

        // A second failure must NOT move `since` — it's "stuck since the
        // first failure", not "since the latest retry".
        store.retry()
        try await Task.sleep(for: .milliseconds(200))
        guard case .stuck(_, let sinceAfterRetry) = store.state else {
            Issue.record("expected still .stuck, got \(store.state)")
            return
        }
        #expect(sinceAfterRetry == since)

        // And it survives a relaunch: a fresh store over the same defaults
        // suite reads the same stuck reason + date back.
        let relaunched = makeStore(settings: settings, library: library, storage: storage, defaults: defaults, log: log)
        #expect(relaunched.state == .stuck(reason: .folderUnreachable, since: since))
    }

    @Test func retryAfterFixingClearsStuck() async throws {
        let settings = makeSettings()
        settings.mirrorBackupEnabled = true
        settings.mirrorFolderPath = "/tmp/wherever"
        let storage = makeStorage()
        let library = makeLibrary(storage: storage)
        _ = try storage.create(Meeting(title: "Flaky", date: .now, status: .ready))
        library.reload()

        let log = MirrorLog()
        log.failEverything(with: .diskFull)
        let defaults = makeDefaults()
        let store = makeStore(settings: settings, library: library, storage: storage, defaults: defaults, log: log)

        store.backfill()
        await waitUntil { self.isStuck(store.state) }
        #expect(isStuck(store.state))

        // "Free some space", then retry: the stuck state clears, the
        // meeting gets backed up, and the persisted since-date is gone.
        log.failEverything(with: nil)
        store.retry()
        await waitUntil { self.isOK(store.state) }

        #expect(isOK(store.state))
        #expect(log.mirrored.count == 1)
        #expect(defaults.object(forKey: "backupStuckSince") == nil)
    }

    // MARK: Queue-driven mirror events

    @Test func noteMirrorEventRendersWorkingThenOK() throws {
        let settings = makeSettings()
        settings.mirrorBackupEnabled = true
        settings.mirrorFolderPath = "/tmp/wherever"
        let storage = makeStorage()
        let library = makeLibrary(storage: storage)
        let record = try storage.create(Meeting(title: "Processing", date: .now, status: .ready))
        library.reload()
        let store = makeStore(
            settings: settings, library: library, storage: storage, defaults: makeDefaults(), log: MirrorLog()
        )

        store.noteMirrorEvent(meetingID: record.meeting.id, .started)
        #expect(store.state == .working(completed: 0, total: 1))

        library.markBackedUp(record.meeting.id) // what QueueStore does on .succeeded
        store.noteMirrorEvent(meetingID: record.meeting.id, .succeeded)
        guard case .ok(let lastBackupAt) = store.state else {
            Issue.record("expected .ok, got \(store.state)")
            return
        }
        #expect(lastBackupAt != nil)
    }

    @Test func noteMirrorEventFailureSetsStuckAndSuccessClearsIt() throws {
        let settings = makeSettings()
        settings.mirrorBackupEnabled = true
        settings.mirrorFolderPath = "/tmp/wherever"
        let storage = makeStorage()
        let library = makeLibrary(storage: storage)
        let record = try storage.create(Meeting(title: "Flaky mirror", date: .now, status: .ready))
        library.reload()
        let store = makeStore(
            settings: settings, library: library, storage: storage, defaults: makeDefaults(), log: MirrorLog()
        )

        store.noteMirrorEvent(meetingID: record.meeting.id, .started)
        store.noteMirrorEvent(meetingID: record.meeting.id, .failed(.copyFailed))
        guard case .stuck(let reason, _) = store.state else {
            Issue.record("expected .stuck, got \(store.state)")
            return
        }
        #expect(reason == .copyFailed)

        // The next successful mirror (retried export) clears it.
        store.noteMirrorEvent(meetingID: record.meeting.id, .started)
        store.noteMirrorEvent(meetingID: record.meeting.id, .succeeded)
        #expect(isOK(store.state))
    }

    // MARK: Per-meeting status

    @Test func backupStatusForMeetingReflectsLastBackupDate() throws {
        let settings = makeSettings()
        let storage = makeStorage()
        let library = makeLibrary(storage: storage)
        let date = Date(timeIntervalSince1970: 5_000)
        let backedUp = try storage.create(
            Meeting(title: "Backed up", date: .now, status: .ready, lastBackupDate: date)
        )
        let pending = try storage.create(Meeting(title: "Pending", date: .now, status: .ready))
        library.reload()
        let store = makeStore(
            settings: settings, library: library, storage: storage, defaults: makeDefaults(), log: MirrorLog()
        )

        #expect(store.backupStatus(for: backedUp.meeting.id) == .backedUp(date))
        #expect(store.backupStatus(for: pending.meeting.id) == .pending)
        #expect(store.backupStatus(for: UUID()) == .pending)
    }

    // MARK: Figures

    @Test func figuresCountBackedUpMeetingsAndTheirBytes() async throws {
        let settings = makeSettings()
        let storage = makeStorage()
        let library = makeLibrary(storage: storage)
        let backedUp = try storage.create(
            Meeting(title: "Backed up", date: .now, status: .ready, lastBackupDate: .now)
        )
        // 100 bytes of "audio" in the backed-up meeting's folder.
        try Data(repeating: 0, count: 100).write(to: backedUp.audioURL)
        // A never-backed-up meeting must not count toward the figures.
        let pending = try storage.create(Meeting(title: "Pending", date: .now, status: .ready))
        try Data(repeating: 0, count: 900).write(to: pending.audioURL)
        library.reload()

        let store = makeStore(
            settings: settings, library: library, storage: storage, defaults: makeDefaults(), log: MirrorLog()
        )

        await waitUntil { store.figures != nil }
        let figures = try #require(store.figures)
        #expect(figures.meetingCount == 1)
        // The folder also holds meeting.json + empty notes.md; total must
        // include the 100 audio bytes but none of pending's 900.
        #expect(figures.totalBytes >= 100)
        #expect(figures.totalBytes < 900)
    }

    @Test func figuresStayNilWithoutStorage() async throws {
        let settings = makeSettings()
        let library = LibraryStore(fixtures: [])
        let store = makeStore(settings: settings, library: library, storage: nil, defaults: makeDefaults(), log: MirrorLog())
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.figures == nil)
    }

    // MARK: Change-bus re-export path

    @Test func mirrorMeetingReportsEventsAndMarksBackedUp() async throws {
        let settings = makeSettings()
        settings.mirrorBackupEnabled = true
        settings.mirrorFolderPath = "/tmp/wherever"
        let storage = makeStorage()
        let library = makeLibrary(storage: storage)
        let record = try storage.create(Meeting(title: "Edited later", date: .now, status: .ready))
        library.reload()

        let log = MirrorLog()
        let store = makeStore(settings: settings, library: library, storage: storage, defaults: makeDefaults(), log: log)

        store.mirrorMeeting(record)
        await waitUntil { library.record(for: record.meeting.id)?.meeting.lastBackupDate != nil }

        #expect(log.mirrored == [record.meeting.id])
        #expect(library.record(for: record.meeting.id)?.meeting.lastBackupDate != nil)
        await waitUntil { self.isOK(store.state) }
        #expect(isOK(store.state))
    }

    @Test func mirrorMeetingNoOpsWhenDisabled() async throws {
        let settings = makeSettings()
        settings.mirrorBackupEnabled = false
        let storage = makeStorage()
        let library = makeLibrary(storage: storage)
        let record = try storage.create(Meeting(title: "Not mirrored", date: .now, status: .ready))
        library.reload()

        let log = MirrorLog()
        let store = makeStore(settings: settings, library: library, storage: storage, defaults: makeDefaults(), log: log)
        store.mirrorMeeting(record)
        try await Task.sleep(for: .milliseconds(100))
        #expect(log.mirrored.isEmpty)
        #expect(store.state == .disabled)
    }
}
