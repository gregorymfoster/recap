import Foundation
import RecapCore
import RecapTranscription
import Testing
@testable import RecapUI

/// Covers `QueueStore.recoverUnfinishedWork`'s handling of a meeting still
/// `.recording` at launch — Recap crashed mid-recording, and the salvaged
/// audio must be parked as `.recovered` rather than silently auto-requeued
/// for transcription (that's `LaunchRecovery.action(for:)`'s decision;
/// this proves the store actually carries it out end to end, including
/// persistence and the queue).
@MainActor
@Suite(.serialized) struct QueueStoreLaunchRecoveryTests {
    private func makeStorage() -> LibraryStorage {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QueueStoreLaunchRecoveryTests-\(UUID().uuidString)")
        return LibraryStorage(rootURL: root)
    }

    private func makeSettings() -> SettingsStore {
        let suite = UserDefaults(suiteName: "recap.tests.queuestorelaunchrecovery.\(UUID().uuidString)")!
        suite.removePersistentDomain(forName: suite.dictionaryRepresentation().description)
        return SettingsStore(defaults: suite)
    }

    @Test func recordingAtLaunchEndsRecoveredAndIsNeverEnqueued() async throws {
        let storage = makeStorage()
        let changeBus = LibraryChangeBus()
        let library = LibraryStore(storage: storage, index: try! SearchIndex(), changeBus: changeBus)
        let settings = makeSettings()

        // Crash-salvaged: audio.m4a would normally exist on disk from the
        // spool, but no audio file is needed here — the point is the status
        // transition and that no job ever runs for it, not that a
        // `.transcribe` job would fail/succeed.
        let crashed = try storage.create(Meeting(title: "Still recording at crash", date: .now, status: .recording))
        library.reload()

        var enqueuedIDs: [UUID] = []
        _ = QueueStore(
            library: library, storage: storage, models: WhisperModelManager(),
            changeBus: changeBus, settings: settings,
            backup: BackupStatusStore(settings: settings, library: library, storage: storage),
            onMeetingReady: { id in enqueuedIDs.append(id) }
        )

        // The status flip to `.recovered` happens synchronously inside
        // `QueueStore.init` (`recoverUnfinishedWork`), so no polling needed.
        #expect(library.record(for: crashed.meeting.id)?.meeting.status == .recovered)

        // Persisted to disk too, not just the in-memory record.
        let reloaded = try storage.loadAll().first { $0.meeting.id == crashed.meeting.id }
        #expect(reloaded?.meeting.status == .recovered)

        // Give any wrongly-enqueued job a window to run and report back —
        // there must be none.
        try await Task.sleep(for: .milliseconds(300))
        #expect(library.record(for: crashed.meeting.id)?.meeting.status == .recovered)
        #expect(enqueuedIDs.isEmpty)
    }

    @Test func alreadyRecoveredAtLaunchStaysRecoveredAndIsNeverEnqueued() async throws {
        let storage = makeStorage()
        let changeBus = LibraryChangeBus()
        let library = LibraryStore(storage: storage, index: try! SearchIndex(), changeBus: changeBus)
        let settings = makeSettings()

        let parked = try storage.create(Meeting(title: "Already recovered", date: .now, status: .recovered))
        library.reload()

        var enqueuedIDs: [UUID] = []
        let queue = QueueStore(
            library: library, storage: storage, models: WhisperModelManager(),
            changeBus: changeBus, settings: settings,
            backup: BackupStatusStore(settings: settings, library: library, storage: storage),
            onMeetingReady: { id in enqueuedIDs.append(id) }
        )
        _ = queue

        try await Task.sleep(for: .milliseconds(300))
        #expect(library.record(for: parked.meeting.id)?.meeting.status == .recovered)
        #expect(enqueuedIDs.isEmpty)
    }

    /// A `.queued` meeting that crashed between transcription finishing and
    /// enhancement starting already has a transcript on disk — it should
    /// resume at `.requeueEnhance`, not re-transcribe from scratch. This
    /// exercises `QueueStore.recoverUnfinishedWork`'s `hasTranscript` wiring
    /// end to end (not just the pure `LaunchRecovery.action(for:hasTranscript:)`
    /// decision, already covered exhaustively in `RecapCoreTests`).
    @Test func queuedWithTranscriptOnDiskRequeuesEnhanceOnly() async throws {
        let storage = makeStorage()
        let changeBus = LibraryChangeBus()
        let library = LibraryStore(storage: storage, index: try! SearchIndex(), changeBus: changeBus)
        let settings = makeSettings()

        let record = try storage.create(Meeting(title: "Crashed after transcript", date: .now, status: .queued))
        try storage.saveTranscript(
            Transcript(
                utterances: [Utterance(start: 0, end: 1, text: "hi")],
                engine: "whisperkit", model: "tiny", language: "en"
            ),
            in: record
        )
        library.reload()

        let recorder = RecordedJobKinds()
        _ = QueueStore(
            library: library, storage: storage, models: WhisperModelManager(),
            changeBus: changeBus, settings: settings,
            backup: BackupStatusStore(settings: settings, library: library, storage: storage),
            executorOverride: RecordingExecutor(recorder: recorder)
        )

        try await Task.sleep(for: .milliseconds(300))
        let kinds = await recorder.kinds
        #expect(kinds == [.enhance])
    }
}

/// Records the `ProcessingJob.Kind` of every job handed to it, without
/// actually doing any work — lets a test assert *which* job kind
/// `QueueStore.recoverUnfinishedWork` enqueued.
private actor RecordedJobKinds {
    private(set) var kinds: [ProcessingJob.Kind] = []

    func record(_ kind: ProcessingJob.Kind) {
        kinds.append(kind)
    }
}

private struct RecordingExecutor: JobExecutor {
    let recorder: RecordedJobKinds

    func execute(_ job: ProcessingJob, progress: @escaping @Sendable (Double) -> Void) async throws {
        await recorder.record(job.kind)
    }
}
