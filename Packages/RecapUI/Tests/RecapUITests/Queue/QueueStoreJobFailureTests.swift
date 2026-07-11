import Foundation
import RecapCore
import RecapTranscription
import Testing
@testable import RecapUI

/// Covers `ProcessingQueue.setOnJobFailed`'s wiring in `QueueStore`: a job
/// that fails twice (initial attempt + one automatic retry) is dropped by the
/// queue and would otherwise leave its meeting stuck silently at whatever
/// status the failed stage started in. These use `executorOverride` (a test
/// seam) to force every job to fail deterministically, without needing a
/// real WhisperKit engine or Apple Intelligence.
@MainActor
@Suite(.serialized) struct QueueStoreJobFailureTests {
    private struct AlwaysFailingExecutor: JobExecutor {
        struct Failure: Error {}
        func execute(_ job: ProcessingJob, progress: @escaping @Sendable (Double) -> Void) async throws {
            throw Failure()
        }
    }

    /// Throws `JobTimedOut` directly — `ProcessingQueue.runJob` catches it by
    /// type regardless of whether it came from the actual timeout race or
    /// (as here) straight from the executor, so this exercises
    /// `QueueStore.setOnJobFailed`'s timeout-specific branch end to end.
    private struct AlwaysTimingOutExecutor: JobExecutor {
        func execute(_ job: ProcessingJob, progress: @escaping @Sendable (Double) -> Void) async throws {
            throw JobTimedOut(job: job, limit: .seconds(600))
        }
    }

    private func makeStorage() -> LibraryStorage {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QueueStoreJobFailureTests-\(UUID().uuidString)")
        return LibraryStorage(rootURL: root)
    }

    private func makeSettings() -> SettingsStore {
        let suite = UserDefaults(suiteName: "recap.tests.queuestorejobfailure.\(UUID().uuidString)")!
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

    @Test func transcribeJobFailureMarksMeetingError() async throws {
        let storage = makeStorage()
        let changeBus = LibraryChangeBus()
        let library = LibraryStore(storage: storage, index: try! SearchIndex(), changeBus: changeBus)
        let settings = makeSettings()

        let record = try storage.create(Meeting(title: "Flaky transcription", date: .now, status: .queued))
        library.reload()

        let queue = QueueStore(
            library: library, storage: storage, models: WhisperModelManager(),
            changeBus: changeBus, settings: settings,
            backup: BackupStatusStore(settings: settings, library: library, storage: storage),
            executorOverride: AlwaysFailingExecutor()
        )
        queue.enqueueTranscription(for: record.meeting.id)

        await waitUntil {
            library.record(for: record.meeting.id)?.meeting.status == .error(message: "Transcription failed")
        }

        #expect(library.record(for: record.meeting.id)?.meeting.status == .error(message: "Transcription failed"))
        // Parity with the in-band failure path `MeetingProcessor` used to
        // take before it started rethrowing engine errors (so the queue's
        // retry can fire): the recoverable issue is still persisted here.
        #expect(library.record(for: record.meeting.id)?.meeting.processingIssues == [.transcriptionFailed])
        // A permanently failed meeting must not be requeued at the next
        // launch — `LaunchRecovery.action(for:)` treats a generic `.error`
        // as terminal.
        #expect(LaunchRecovery.action(for: .error(message: "Transcription failed")) == .none)
    }

    /// A job timeout (`JobTimedOut`) gets its own status message, distinct
    /// from a plain engine failure, and is never retried — a hang isn't
    /// transient.
    @Test func transcribeJobTimeoutMarksMeetingWithTimeoutMessage() async throws {
        let storage = makeStorage()
        let changeBus = LibraryChangeBus()
        let library = LibraryStore(storage: storage, index: try! SearchIndex(), changeBus: changeBus)
        let settings = makeSettings()

        let record = try storage.create(Meeting(title: "Wedged transcription", date: .now, status: .queued))
        library.reload()

        let queue = QueueStore(
            library: library, storage: storage, models: WhisperModelManager(),
            changeBus: changeBus, settings: settings,
            backup: BackupStatusStore(settings: settings, library: library, storage: storage),
            executorOverride: AlwaysTimingOutExecutor()
        )
        queue.enqueueTranscription(for: record.meeting.id)

        await waitUntil {
            library.record(for: record.meeting.id)?.meeting.status == .error(message: "Transcription timed out")
        }

        #expect(
            library.record(for: record.meeting.id)?.meeting.status == .error(message: "Transcription timed out")
        )
    }

    @Test func enhanceJobFailureKeepsMeetingReadyWithIssue() async throws {
        let storage = makeStorage()
        let changeBus = LibraryChangeBus()
        let library = LibraryStore(storage: storage, index: try! SearchIndex(), changeBus: changeBus)
        let settings = makeSettings()

        // `.ready` (not `.queued`) so `QueueStore.recoverUnfinishedWork`
        // treats it as a no-op at construction — a `.queued` meeting would
        // race an automatic transcribe attempt (via the same
        // `AlwaysFailingExecutor`) against this test's explicit
        // `retryEnhancement` call, which — now that a failed transcribe job
        // also persists `.transcriptionFailed` — would pollute
        // `processingIssues` with an issue this test isn't exercising.
        let record = try storage.create(Meeting(title: "Flaky enhancement", date: .now, status: .ready))
        library.reload()

        let queue = QueueStore(
            library: library, storage: storage, models: WhisperModelManager(),
            changeBus: changeBus, settings: settings,
            backup: BackupStatusStore(settings: settings, library: library, storage: storage),
            executorOverride: AlwaysFailingExecutor()
        )
        queue.retryEnhancement(record, in: library)

        await waitUntil {
            library.record(for: record.meeting.id)?.meeting.status == .ready
        }

        #expect(library.record(for: record.meeting.id)?.meeting.status == .ready)
        #expect(library.record(for: record.meeting.id)?.meeting.processingIssues == [.enhancementFailed])
    }
}
