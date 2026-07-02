import Foundation
import Observation
import RecapCore
import RecapEnhancement
import RecapTranscription

/// Executes queue jobs: loads the meeting, runs the active engine, saves
/// results, and reports status transitions back to the main actor.
struct MeetingProcessor: JobExecutor {
    let storage: LibraryStorage
    let engineProvider: @Sendable () async -> TranscriptionEngine?
    let enhancer: NoteEnhancer
    let onStatus: @Sendable (UUID, MeetingStatus) async -> Void
    /// Enqueues a follow-up job (transcribe → enhance chaining).
    let chain: @Sendable (ProcessingJob) async -> Void

    func execute(_ job: ProcessingJob, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let record = try storage.loadAll().first(where: { $0.meeting.id == job.meetingID })
        else { return }

        switch job.kind {
        case .transcribe:
            guard FileManager.default.fileExists(atPath: record.audioURL.path) else {
                await onStatus(job.meetingID, .error(message: "Recording file missing"))
                return
            }
            guard let engine = await engineProvider() else {
                await onStatus(job.meetingID, .needsModel)
                return
            }
            await onStatus(job.meetingID, .transcribing(progress: 0))
            do {
                let transcript = try await engine.transcribe(file: record.audioURL) { fraction in
                    progress(fraction)
                    Task { await onStatus(job.meetingID, .transcribing(progress: fraction)) }
                }
                try storage.saveTranscript(transcript, in: record)
                if enhancer.isAvailable {
                    await onStatus(job.meetingID, .enhancing)
                    await chain(ProcessingJob(kind: .enhance, meetingID: job.meetingID))
                } else {
                    // Apple Intelligence off → meeting completes transcript-only.
                    await onStatus(job.meetingID, .ready)
                }
            } catch {
                await onStatus(job.meetingID, .error(message: "Transcription failed"))
            }

        case .enhance:
            guard
                enhancer.isAvailable,
                let transcript = try storage.loadTranscript(in: record),
                !transcript.utterances.isEmpty
            else {
                await onStatus(job.meetingID, .ready)
                return
            }
            await onStatus(job.meetingID, .enhancing)
            let notes = (try? storage.loadNotes(in: record)) ?? ""
            do {
                let enhanced = try await enhancer.enhance(rawNotes: notes, transcript: transcript)
                try storage.saveEnhancedNotes(enhanced, in: record)
            } catch {
                // Refused or failed twice — the meeting is still complete with
                // its transcript; enhancement can be retried from the editor.
            }
            await onStatus(job.meetingID, .ready)
        }
    }
}

/// Owns the background queue: feeds it power state, publishes its snapshot
/// to the sidebar widget, and re-enqueues unfinished work at launch.
@MainActor
@Observable
public final class QueueStore {
    private let queue: ProcessingQueue
    private let monitor = SystemPowerMonitor()
    private var monitorTask: Task<Void, Never>?

    public init(library: LibraryStore, storage: LibraryStorage, models: WhisperModelManager) {
        // Two-phase init: the processor's chain closure needs the queue.
        let queueBox = QueueBox()
        let processor = MeetingProcessor(
            storage: storage,
            engineProvider: { @Sendable in await models.activeEngine() },
            enhancer: FoundationModelEnhancer(),
            onStatus: { @Sendable id, status in
                await library.updateStatus(id, to: status)
            },
            chain: { @Sendable job in
                await queueBox.queue?.enqueue(job)
            }
        )
        let pausesOnBattery = UserDefaults.standard.object(forKey: "pauseOnBattery") as? Bool ?? true
        let queue = ProcessingQueue(executor: processor, pausesOnBattery: pausesOnBattery)
        self.queue = queue
        Task { await queueBox.set(queue) }

        Task {
            await queue.setObserver { snapshot in
                Task { @MainActor in
                    library.queueSummary = snapshot.jobCount == 0
                        ? nil
                        : QueueSummary(
                            jobCount: snapshot.jobCount,
                            progress: snapshot.runningProgress,
                            pauseReason: snapshot.pauseReason
                        )
                }
            }
        }
        monitorTask = Task { [monitor] in
            for await state in monitor.updates() {
                await queue.powerStateChanged(state)
            }
        }
        recoverUnfinishedWork(in: library)
    }

    public func enqueueTranscription(for meetingID: UUID) {
        Task { await queue.enqueue(ProcessingJob(kind: .transcribe, meetingID: meetingID)) }
    }

    /// Re-runs transcription for every meeting parked in `.needsModel`. Called
    /// when a speech model becomes active (freshly installed, or restored at
    /// launch) so parked recordings finish without the user re-recording.
    public func retryMeetingsAwaitingModel(in library: LibraryStore) {
        for record in library.meetings where record.meeting.status == .needsModel {
            library.updateStatus(record.meeting.id, to: .queued)
            enqueueTranscription(for: record.meeting.id)
        }
    }

    public func setPausesOnBattery(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: "pauseOnBattery")
        Task { await queue.setPausesOnBattery(value) }
    }

    /// Meetings that died mid-pipeline (app quit or crash) resume from where
    /// their files left off: with a transcript on disk only enhancement is
    /// missing; otherwise transcription restarts.
    private func recoverUnfinishedWork(in library: LibraryStore) {
        for record in library.meetings {
            switch record.meeting.status {
            case .queued, .transcribing, .recording:
                library.updateStatus(record.meeting.id, to: .queued)
                enqueueTranscription(for: record.meeting.id)
            case .enhancing:
                library.updateStatus(record.meeting.id, to: .queued)
                Task { await queue.enqueue(ProcessingJob(kind: .enhance, meetingID: record.meeting.id)) }
            case .error("No speech model installed"):
                // Migrate meetings saved before `.needsModel` existed so they
                // become retryable instead of a permanent dead end.
                library.updateStatus(record.meeting.id, to: .needsModel)
            case .needsModel, .ready, .error:
                // `.needsModel` is retried by `retryMeetingsAwaitingModel` once a
                // model is active; genuine errors stay put.
                break
            }
        }
    }
}

/// Breaks the processor ↔ queue construction cycle.
private actor QueueBox {
    private(set) var queue: ProcessingQueue?

    func set(_ queue: ProcessingQueue) {
        self.queue = queue
    }
}
