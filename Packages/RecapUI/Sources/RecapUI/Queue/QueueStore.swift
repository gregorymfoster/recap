import Foundation
import Observation
import os
import RecapAudio
import RecapCore
import RecapEnhancement
import RecapTranscription

private let queueStoreLog = Logger(subsystem: "com.gregfoster.recap", category: "QueueStore")

/// Owns the background queue: feeds it power state and re-enqueues unfinished
/// work at launch.
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
    /// - Parameter executorOverride: Test seam only — when non-nil, this
    ///   `JobExecutor` runs jobs instead of the production `MeetingProcessor`,
    ///   so tests can force a job to fail deterministically (no WhisperKit/
    ///   Apple Intelligence needed) and assert on the `setOnJobFailed` wiring
    ///   below. Always nil in every real graph.
    public init(
        library: LibraryStore, storage: LibraryStorage, models: WhisperModelManager,
        changeBus: LibraryChangeBus, settings: SettingsStore, backup: BackupStatusStore,
        enhancer: NoteEnhancer = FoundationModelEnhancer(),
        onError: (@MainActor (String) -> Void)? = nil,
        onMeetingReady: (@MainActor (UUID) -> Void)? = nil,
        executorOverride: JobExecutor? = nil
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
                await models.activeEngine()
            },
            diarizerProvider: { @Sendable in
                diarizer
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
            onBackupEvent: { @Sendable id, event in
                if case .succeeded = event {
                    await library.markBackedUp(id)
                }
                await backup.noteMirrorEvent(meetingID: id, event)
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
        let queue = ProcessingQueue(
            executor: executorOverride ?? processor,
            timeoutLimit: { @Sendable job in
                let audioSeconds = await MainActor.run { () -> TimeInterval? in
                    guard let duration = library.record(for: job.meetingID)?.meeting.duration, duration > 0
                    else { return nil }
                    return duration
                }
                return JobTimeoutPolicy.limit(kind: job.kind, audioSeconds: audioSeconds)
            }
        )
        self.queue = queue
        Task { await queueBox.set(queue) }

        monitorTask = Task { [monitor] in
            for await state in monitor.updates() {
                await queue.powerStateChanged(state)
            }
        }

        // A job that fails twice (initial attempt + one automatic retry) is
        // dropped by `ProcessingQueue` and left in whichever status the
        // failed stage started in — without this, that meeting is stuck
        // silently at `.transcribing`/`.enhancing` forever. Surface it the
        // same way the library already knows how to show a failure: a
        // `.transcribe` failure becomes a plain `.error` status (the
        // existing "Transcription failed · Retry" row), matching the
        // `errorLibrary()` fixture scenario exactly. A `.enhance` failure
        // must not blank out an already-finished transcript, so the meeting
        // still completes as `.ready` with `.enhancementFailed` recorded as
        // a `ProcessingIssue` — the same recoverable-issue path a normal
        // in-band enhancement failure already takes in `MeetingProcessor`.
        // `.export` failures are logged only; export retries are already
        // covered by `.mirrorBackupFailed`.
        Task {
            await queue.setOnJobFailed { job, error in
                Task { @MainActor in
                    switch job.kind {
                    case .transcribe:
                        queueStoreLog.error(
                            "transcription job failed after retry: meetingID=\(job.meetingID.uuidString, privacy: .private) error=\(String(describing: error), privacy: .private)"
                        )
                        if error is JobTimedOut {
                            library.updateStatus(job.meetingID, to: .error(message: "Transcription timed out"))
                        } else {
                            library.updateStatus(job.meetingID, to: .error(message: "Transcription failed"))
                            // Parity with the in-band failure path in
                            // `MeetingProcessor`, which used to write this
                            // issue itself before it started rethrowing
                            // engine errors so the queue's retry can fire.
                            library.addProcessingIssue(.transcriptionFailed, for: job.meetingID)
                        }
                    case .enhance:
                        queueStoreLog.error(
                            "enhancement job failed after retry: meetingID=\(job.meetingID.uuidString, privacy: .private) error=\(String(describing: error), privacy: .private)"
                        )
                        library.updateStatus(job.meetingID, to: .ready)
                        library.addProcessingIssue(.enhancementFailed, for: job.meetingID)
                    case .export:
                        queueStoreLog.error(
                            "export job failed after retry: meetingID=\(job.meetingID.uuidString, privacy: .private) error=\(String(describing: error), privacy: .private)"
                        )
                    }
                }
            }
        }
        recoverUnfinishedWork(in: library, storage: storage)

        // A meeting can finish `.ready` with mirror backup already enabled
        // but never get exported — Recap quit between the pipeline
        // completing and `ChangeBusConsumer`'s debounced export firing, or
        // backup was turned on while the app wasn't running. `backfill()`
        // already knows how to find and mirror every meeting still pending
        // per `LaunchRecovery.needsExportRecovery` (the same scan the
        // Settings toggle's "back up existing meetings now" action runs),
        // and no-ops instantly when backup is disabled, no folder is
        // configured, or nothing is pending — safe to call unconditionally
        // here, once, at construction. Calling it again later (the Settings
        // toggle, a stuck-backup retry) is also safe: `backfill()` itself
        // cancels/replaces any run already in flight rather than stacking a
        // second one, so there's no double-export to guard against.
        backup.backfill()
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

    /// Starts transcription for a `.recovered` meeting (crash-salvaged audio
    /// that stayed parked at launch instead of auto-requeuing) — the user's
    /// explicit "Transcribe" action. Same shape as `retranscribe`: guards on
    /// library membership so a stale action can't resurrect a trashed
    /// meeting, resets status to `.queued`, then enqueues.
    public func transcribeRecovered(_ record: MeetingRecord, in library: LibraryStore) {
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

    /// Meetings that died mid-pipeline (app quit or crash) resume from where
    /// their files left off: with a transcript on disk only enhancement is
    /// missing; otherwise transcription restarts. A meeting still
    /// `.recording` at launch (Recap crashed mid-recording) or already
    /// `.recovered` is the one exception — it's parked/kept as `.recovered`
    /// until the user explicitly presses Transcribe (`transcribeRecovered`),
    /// rather than silently auto-requeuing. Decision logic lives in the pure
    /// `LaunchRecovery.action(for:hasTranscript:)`.
    private func recoverUnfinishedWork(in library: LibraryStore, storage: LibraryStorage) {
        for record in library.meetings {
            // Only `.queued` consults hasTranscript — don't pay a transcript
            // decode for every meeting in the library at launch.
            let hasTranscript = record.meeting.status == .queued
                && (try? storage.loadTranscript(in: record)) != nil
            switch LaunchRecovery.action(for: record.meeting.status, hasTranscript: hasTranscript) {
            case .requeueTranscribe:
                library.updateStatus(record.meeting.id, to: .queued)
                enqueueTranscription(for: record.meeting.id)
            case .requeueEnhance:
                library.updateStatus(record.meeting.id, to: .queued)
                Task { await queue.enqueue(ProcessingJob(kind: .enhance, meetingID: record.meeting.id)) }
            case .markRecovered:
                // A meeting still `.recording` at launch means Recap crashed
                // mid-recording; park the salvaged audio as `.recovered`
                // instead of auto-requeuing (no-op if it's already
                // `.recovered`). Never enqueued — the user explicitly presses
                // Transcribe (`transcribeRecovered`) to pick it back up.
                library.updateStatus(record.meeting.id, to: .recovered)
            case .migrateToNeedsModel:
                // Migrate meetings saved before `.needsModel` existed so they
                // become retryable instead of a permanent dead end.
                library.updateStatus(record.meeting.id, to: .needsModel)
            case .none:
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
