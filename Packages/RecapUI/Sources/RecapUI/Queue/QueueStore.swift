import Foundation
import Observation
import RecapAudio
import RecapCore
import RecapEnhancement
import RecapTranscription

/// Owns the background queue: feeds it power state, publishes its snapshot
/// to the sidebar widget, and re-enqueues unfinished work at launch.
@MainActor
@Observable
public final class QueueStore {
    private let queue: ProcessingQueue
    private let monitor = SystemPowerMonitor()
    private var monitorTask: Task<Void, Never>?

    /// - Parameter onError: Fired once per meeting when the processing
    ///   pipeline transitions it to `.error`, so the UI can surface a toast
    ///   in addition to the row chip `updateStatus` already produces.
    /// - Parameter enhancer: Injectable so tests can hand in a fake through
    ///   this public surface; production always uses `FoundationModelEnhancer()`.
    /// - Parameter onMeetingReady: Fired once per meeting transition into
    ///   `.ready` (transcript done, enhancement done/skipped/unavailable —
    ///   all three end here) — the one completion signal, whatever the exact
    ///   path through the pipeline. `CompletionNotifier` hooks this to post
    ///   the "‹meeting› is ready" notification.
    public init(
        library: LibraryStore, storage: LibraryStorage, models: WhisperModelManager,
        changeBus: LibraryChangeBus, settings: SettingsStore,
        enhancer: NoteEnhancer = FoundationModelEnhancer(),
        onError: (@MainActor (String) -> Void)? = nil,
        onMeetingReady: (@MainActor (UUID) -> Void)? = nil
    ) {
        // Two-phase init: the processor's chain closure needs the queue.
        let queueBox = QueueBox()
        let diarizer = SpeakerDiarizer()
        let settingsSnapshot: @Sendable () async -> ProcessorSettings = {
            await MainActor.run { settings.processorSettings }
        }
        let processor = MeetingProcessor(
            storage: storage,
            engineProvider: { @Sendable in
                let language = await settingsSnapshot().transcriptionLanguage
                return await models.activeEngine(language: language)
            },
            diarizerProvider: { @Sendable in
                let enabled = await settingsSnapshot().labelsSpeakers
                return enabled ? diarizer : nil
            },
            enhancer: enhancer,
            settings: settingsSnapshot,
            onStatus: { @Sendable id, status in
                // A trashed meeting is dropped from the library immediately;
                // an in-flight job for it can still land here afterward (its
                // task isn't interrupted, see `ProcessingQueue.cancel`).
                // `updateStatus` already no-ops for an unknown ID, but the
                // toast path needs its own guard — there's no row left for
                // this error to annotate.
                let stillExists = await MainActor.run { library.record(for: id) != nil }
                await library.updateStatus(id, to: status)
                if case .error(let message) = status, stillExists {
                    await onError?(message)
                }
                if status == .ready {
                    await onMeetingReady?(id)
                }
            },
            onDurationRecovered: { @Sendable id, duration in
                await library.updateDuration(id, to: duration)
            },
            onBackedUp: { @Sendable id in
                await library.markBackedUp(id)
            },
            chain: { @Sendable job in
                await queueBox.queue?.enqueue(job)
            },
            changeBus: changeBus,
            onSubtitle: { @Sendable id, subtitle in
                await library.updateSubtitle(subtitle, for: id)
            },
            onProcessingIssue: { @Sendable id, issue, isActive in
                if isActive {
                    await library.addProcessingIssue(issue, for: id)
                } else {
                    await library.clearProcessingIssue(issue, for: id)
                }
            }
        )
        let queue = ProcessingQueue(executor: processor, pausesOnBattery: settings.pausesOnBattery)
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

    /// Re-transcribes a meeting from its saved audio — the library row's
    /// "Re-transcribe" context menu action (retryable after a failed or
    /// unsatisfying pass). Resets status to `.queued` first so the row shows
    /// the same quiet "Queued" state as any other pending job, then reuses
    /// the normal enqueue path. Guards on library membership: a stale menu
    /// action firing after the meeting was just trashed must not resurrect it.
    public func retranscribe(_ record: MeetingRecord, in library: LibraryStore) {
        guard library.record(for: record.meeting.id) != nil else { return }
        library.updateStatus(record.meeting.id, to: .queued)
        enqueueTranscription(for: record.meeting.id)
    }

    /// Re-runs only the enhancement stage for a meeting that already has a
    /// transcript. Its existing issue remains visible until the retry
    /// succeeds, so users never lose the explanation mid-recovery.
    public func retryEnhancement(_ record: MeetingRecord, in library: LibraryStore) {
        guard library.record(for: record.meeting.id) != nil else { return }
        library.updateStatus(record.meeting.id, to: .queued)
        Task { await queue.enqueue(ProcessingJob(kind: .enhance, meetingID: record.meeting.id)) }
    }

    /// Re-runs configured exports without re-transcribing or re-enhancing the
    /// meeting. Export issues are independently cleared only on success.
    public func retryExport(_ record: MeetingRecord, in library: LibraryStore) {
        guard library.record(for: record.meeting.id) != nil else { return }
        Task { await queue.enqueue(ProcessingJob(kind: .export, meetingID: record.meeting.id)) }
    }

    /// Cancels every PENDING job for a meeting that just left the library
    /// (moved to Trash). An in-flight job for it is left to finish/fail on
    /// its own — the `onStatus` callback above guards against acting on a
    /// stale meeting ID, so that natural finish/fail is harmless.
    public func cancel(meetingID: UUID) {
        Task { await queue.cancel(meetingID: meetingID) }
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

    /// Persistence is the caller's responsibility (`SettingsStore.pausesOnBattery`'s
    /// `didSet` already writes UserDefaults) — this only pushes the live value
    /// into the running queue actor.
    public func setPausesOnBattery(_ value: Bool) {
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
