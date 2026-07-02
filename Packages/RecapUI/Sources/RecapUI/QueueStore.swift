import Foundation
import Observation
import RecapCore
import RecapTranscription

/// Executes queue jobs: loads the meeting, runs the active engine, saves
/// results, and reports status transitions back to the main actor.
struct MeetingProcessor: JobExecutor {
    let storage: LibraryStorage
    let engineProvider: @Sendable () async -> TranscriptionEngine?
    let onStatus: @Sendable (UUID, MeetingStatus) async -> Void

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
                await onStatus(job.meetingID, .error(message: "No speech model installed"))
                return
            }
            await onStatus(job.meetingID, .transcribing(progress: 0))
            do {
                let transcript = try await engine.transcribe(file: record.audioURL) { fraction in
                    progress(fraction)
                    Task { await onStatus(job.meetingID, .transcribing(progress: fraction)) }
                }
                try storage.saveTranscript(transcript, in: record)
                // M8 inserts an enhance job here; until then transcription completes the meeting.
                await onStatus(job.meetingID, .ready)
            } catch {
                await onStatus(job.meetingID, .error(message: "Transcription failed"))
            }

        case .enhance:
            // Arrives with M8 (FoundationModels note enhancement).
            break
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
        let processor = MeetingProcessor(
            storage: storage,
            engineProvider: { @Sendable in await models.activeEngine() },
            onStatus: { @Sendable id, status in
                await library.updateStatus(id, to: status)
            }
        )
        let pausesOnBattery = UserDefaults.standard.object(forKey: "pauseOnBattery") as? Bool ?? true
        let queue = ProcessingQueue(executor: processor, pausesOnBattery: pausesOnBattery)
        self.queue = queue

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

    public func setPausesOnBattery(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: "pauseOnBattery")
        Task { await queue.setPausesOnBattery(value) }
    }

    /// Meetings that died mid-pipeline (app quit or crash) restart from the top.
    private func recoverUnfinishedWork(in library: LibraryStore) {
        for record in library.meetings {
            switch record.meeting.status {
            case .queued, .transcribing, .enhancing, .recording:
                library.updateStatus(record.meeting.id, to: .queued)
                enqueueTranscription(for: record.meeting.id)
            case .ready, .error:
                break
            }
        }
    }
}
