import Foundation
import RecapCore
import RecapTranscription
import Testing
@testable import RecapUI

/// Thread-safe capture of `mirrorRecord` invocations — mirrors
/// `BackupStatusStoreTests`' `MirrorLog`, duplicated locally since that one
/// is file-private there.
private final class ExportMirrorLog: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [UUID] = []

    func mirror(_ record: MeetingRecord) throws {
        lock.lock()
        records.append(record.meeting.id)
        lock.unlock()
    }

    var mirrored: [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }
}

/// Covers "recover export jobs at launch" (2d): `QueueStore.init` now calls
/// `BackupStatusStore.backfill()` once, so a meeting that finished `.ready`
/// with mirror backup already enabled but never got exported — e.g. Recap
/// quit between pipeline completion and the debounced change-bus export —
/// gets backed up without any user action, the next time the app launches.
@MainActor
@Suite(.serialized) struct QueueStoreExportRecoveryTests {
    private func makeStorage() -> LibraryStorage {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QueueStoreExportRecoveryTests-\(UUID().uuidString)")
        return LibraryStorage(rootURL: root)
    }

    private func makeSettings(mirrorEnabled: Bool) -> SettingsStore {
        let suite = UserDefaults(suiteName: "recap.tests.queuestoreexportrecovery.\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: suite)
        settings.mirrorBackupEnabled = mirrorEnabled
        settings.mirrorFolderPath = "/tmp/wherever" // fake mirror never touches it
        return settings
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func pendingExportIsMirroredAtLaunch() async throws {
        let storage = makeStorage()
        let changeBus = LibraryChangeBus()
        let library = LibraryStore(storage: storage, index: try! SearchIndex(), changeBus: changeBus)
        let settings = makeSettings(mirrorEnabled: true)
        let record = try storage.create(Meeting(title: "Pending export", date: .now, status: .ready))
        library.reload()

        let log = ExportMirrorLog()
        let backup = BackupStatusStore(
            settings: settings, library: library, storage: storage,
            mirrorRecord: { rec, _ in try log.mirror(rec) }
        )
        _ = QueueStore(
            library: library, storage: storage, models: WhisperModelManager(),
            changeBus: changeBus, settings: settings, backup: backup
        )

        await waitUntil { log.mirrored.contains(record.meeting.id) }
        #expect(log.mirrored.contains(record.meeting.id))
    }

    @Test func alreadyBackedUpMeetingIsNotReMirroredAtLaunch() async throws {
        let storage = makeStorage()
        let changeBus = LibraryChangeBus()
        let library = LibraryStore(storage: storage, index: try! SearchIndex(), changeBus: changeBus)
        let settings = makeSettings(mirrorEnabled: true)
        _ = try storage.create(Meeting(title: "Already backed up", date: .now, status: .ready, lastBackupDate: .now))
        library.reload()

        let log = ExportMirrorLog()
        let backup = BackupStatusStore(
            settings: settings, library: library, storage: storage,
            mirrorRecord: { rec, _ in try log.mirror(rec) }
        )
        _ = QueueStore(
            library: library, storage: storage, models: WhisperModelManager(),
            changeBus: changeBus, settings: settings, backup: backup
        )

        try await Task.sleep(for: .milliseconds(300))
        #expect(log.mirrored.isEmpty)
    }

    @Test func mirrorBackupDisabledSkipsRecoveryAtLaunch() async throws {
        let storage = makeStorage()
        let changeBus = LibraryChangeBus()
        let library = LibraryStore(storage: storage, index: try! SearchIndex(), changeBus: changeBus)
        let settings = makeSettings(mirrorEnabled: false)
        _ = try storage.create(Meeting(title: "Backup disabled", date: .now, status: .ready))
        library.reload()

        let log = ExportMirrorLog()
        let backup = BackupStatusStore(
            settings: settings, library: library, storage: storage,
            mirrorRecord: { rec, _ in try log.mirror(rec) }
        )
        _ = QueueStore(
            library: library, storage: storage, models: WhisperModelManager(),
            changeBus: changeBus, settings: settings, backup: backup
        )

        try await Task.sleep(for: .milliseconds(300))
        #expect(log.mirrored.isEmpty)
    }
}
