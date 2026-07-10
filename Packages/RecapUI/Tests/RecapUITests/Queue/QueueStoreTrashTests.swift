import Foundation
import RecapCore
import RecapTranscription
import Testing
@testable import RecapUI

/// Covers the trash → cancel-queued-work wiring (`AppStores.moveToTrash`):
/// a meeting moved to Trash must not leave queued work behind that later
/// resurfaces as a user-facing error toast for a meeting that no longer
/// exists, and re-enqueue entry points must refuse to act on a trashed
/// meeting ID.
///
/// These build a real `QueueStore` (every `AppStoresTests` scenario passes
/// `queue: nil`) with a real `ProcessingQueue`/`MeetingProcessor`.
/// `storage.create(_:)` records a meeting with no audio file on disk, so a
/// `.transcribe` job for it fails fast and deterministically at
/// `MeetingProcessor`'s "Recording file missing" guard — without needing a
/// real WhisperKit engine or Apple Intelligence — which is exactly the
/// "job finishes naturally after its meeting was trashed" scenario these
/// tests need.
@MainActor
@Suite(.serialized) struct QueueStoreTrashTests {
    private func makeStorage() -> LibraryStorage {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QueueStoreTrashTests-\(UUID().uuidString)")
        return LibraryStorage(rootURL: root)
    }

    private func makeSettings() -> SettingsStore {
        let suite = UserDefaults(suiteName: "recap.tests.queuestoretrash.\(UUID().uuidString)")!
        suite.removePersistentDomain(forName: suite.dictionaryRepresentation().description)
        return SettingsStore(defaults: suite)
    }

    private func waitUntil(
        timeout: Duration = .seconds(5), _ condition: () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func moveToTrashCancelsPendingJobForThatMeeting() async throws {
        let storage = makeStorage()
        let changeBus = LibraryChangeBus()
        let library = LibraryStore(storage: storage, index: try! SearchIndex(), changeBus: changeBus)
        let settings = makeSettings()

        // No audio file for either meeting, so any `.transcribe` job that
        // actually executes reports `.error("Recording file missing")`.
        let first = try storage.create(Meeting(title: "Occupies the running slot", date: .now, status: .queued))
        let trashed = try storage.create(Meeting(title: "Gets trashed", date: .now, status: .queued))
        library.reload()

        var errors: [String] = []
        let queue = QueueStore(
            library: library, storage: storage, models: WhisperModelManager(),
            changeBus: changeBus, settings: settings,
            backup: BackupStatusStore(settings: settings, library: library, storage: storage),
            onError: { message in errors.append(message) }
        )

        // Enqueue both back-to-back with no yield in between: the queue is a
        // FIFO actor, so `first` claims the running slot and `trashed`'s job
        // is guaranteed to still be sitting in `pending` the instant control
        // returns here.
        queue.enqueueTranscription(for: first.meeting.id)
        queue.enqueueTranscription(for: trashed.meeting.id)

        library.moveToTrash(trashed)
        queue.cancel(meetingID: trashed.meeting.id)

        #expect(library.record(for: trashed.meeting.id) == nil)

        // Let the queue fully drain: `first` legitimately errors (it has no
        // audio file either), and `trashed`'s pending job must never run.
        // Wait on the error toast, not the status write — `onStatus` performs
        // them as two separate MainActor hops (updateStatus first, onError
        // second), so polling on the status alone can observe a moment where
        // the status has landed but the toast hasn't yet.
        await waitUntil {
            !errors.isEmpty
        }

        // No error toast for the trashed meeting: only one error surfaced
        // (`first`'s legitimate "Recording file missing" failure), not two.
        #expect(library.record(for: first.meeting.id)?.meeting.status == .error(message: "Recording file missing"))
        #expect(errors.count == 1)
        #expect(library.record(for: trashed.meeting.id) == nil)
    }

    @Test func staleInFlightJobFinishingForATrashedMeetingDoesNotToast() async throws {
        let storage = makeStorage()
        let changeBus = LibraryChangeBus()
        let library = LibraryStore(storage: storage, index: try! SearchIndex(), changeBus: changeBus)
        let settings = makeSettings()

        let record = try storage.create(Meeting(title: "In flight", date: .now, status: .queued))
        library.reload()

        var errors: [String] = []
        let queue = QueueStore(
            library: library, storage: storage, models: WhisperModelManager(),
            changeBus: changeBus, settings: settings,
            backup: BackupStatusStore(settings: settings, library: library, storage: storage),
            onError: { message in errors.append(message) }
        )

        // Starts running immediately (nothing ahead of it in the queue).
        queue.enqueueTranscription(for: record.meeting.id)

        // Trash it right away — cancel() only prunes PENDING jobs, so this
        // meeting's already-running job is NOT interrupted; it will still
        // run to completion (and fail, since there's no audio file) and
        // report its status back through `onStatus` after the meeting is
        // already gone from the library.
        library.moveToTrash(record)
        queue.cancel(meetingID: record.meeting.id)
        #expect(library.record(for: record.meeting.id) == nil)

        // The meeting is gone from the library, so there's no status to poll
        // on — the job runs its course (file-existence check, no real I/O)
        // well within this window regardless of scheduler contention.
        try await Task.sleep(for: .milliseconds(500))

        // The in-flight job's failure must not have produced a toast for a
        // meeting that no longer exists.
        #expect(errors.isEmpty)
    }

    @Test func retranscribeAfterTrashDoesNotResurrectTheMeeting() async throws {
        let storage = makeStorage()
        let changeBus = LibraryChangeBus()
        let library = LibraryStore(storage: storage, index: try! SearchIndex(), changeBus: changeBus)
        let settings = makeSettings()

        let record = try storage.create(Meeting(title: "Trashed then retried", date: .now, status: .ready))
        library.reload()

        let queue = QueueStore(
            library: library, storage: storage, models: WhisperModelManager(),
            changeBus: changeBus, settings: settings,
            backup: BackupStatusStore(settings: settings, library: library, storage: storage)
        )

        library.moveToTrash(record)
        #expect(library.record(for: record.meeting.id) == nil)

        // A stale context-menu action (e.g. a still-open menu built before
        // the trash) firing "Re-transcribe" for the now-gone meeting must be
        // a no-op, not resurrect a status row for it.
        queue.retranscribe(record, in: library)

        #expect(library.record(for: record.meeting.id) == nil)
    }
}
