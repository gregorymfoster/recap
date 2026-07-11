import Foundation
import OSLog
import RecapAudio
import RecapCore
import RecapEnhancement
import RecapTranscription

private let processorLog = Logger(subsystem: "com.gregfoster.recap", category: "MeetingProcessor")

/// Executes queue jobs: loads the meeting, runs the active engine, saves
/// results, and reports status transitions back to the main actor.
struct MeetingProcessor: JobExecutor {
    let storage: LibraryStorage
    /// Resolves a meeting's folder from the in-memory library (MainActor hop) —
    /// nil when the meeting was trashed after the job was enqueued.
    let recordFolder: @Sendable (UUID) async -> URL?
    let engineProvider: @Sendable () async -> TranscriptionEngine?
    /// nil when speaker labeling is disabled in settings.
    let diarizerProvider: @Sendable () async -> SpeakerDiarizer?
    let enhancer: NoteEnhancer
    /// Fresh settings snapshot per use — settings can change while a job is
    /// queued, and reading a @MainActor SettingsStore requires hopping actors.
    let settings: @Sendable () async -> ProcessorSettings
    let onStatus: @Sendable (UUID, MeetingStatus) async -> Void
    /// Crash salvage recovered the audio; the file length is the duration.
    let onDurationRecovered: @Sendable (UUID, TimeInterval) async -> Void
    /// The folder-mirror backup's lifecycle for this meeting — `.started`
    /// before mirroring, then `.succeeded` or `.failed(classified)`. The
    /// caller (`QueueStore`) persists `lastBackupDate` on `.succeeded` and
    /// forwards every event to `BackupStatusStore` so the aggregate status
    /// stays accurate.
    let onBackupEvent: @Sendable (UUID, BackupEvent) async -> Void
    /// Enqueues a follow-up job (transcribe → enhance chaining).
    let chain: @Sendable (ProcessingJob) async -> Void
    /// Announces a meeting is about to be exported, so other subscribers
    /// (folder mirror, future CloudKit sync) see the same completion signal.
    let changeBus: LibraryChangeBus
    /// A one-line subtitle was generated for the meeting during enhancement;
    /// nil subtitles from a failed/skipped generation never call this.
    let onSubtitle: @Sendable (UUID, String) async -> Void
    /// Persists/clears a recoverable issue without storing raw error details.
    let onProcessingIssue: @Sendable (UUID, ProcessingIssue, Bool) async -> Void

    func execute(_ job: ProcessingJob, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let folderURL = await recordFolder(job.meetingID),
              let record = storage.loadRecord(inFolder: folderURL)
        else { return }

        switch job.kind {
        case .transcribe:
            let reporter = ProcessingStatusCoordinator(meetingID: job.meetingID, deliver: onStatus)
            // A leftover CAF spool means the recording died mid-write (crash,
            // power loss, disk full): rebuild the m4a from it before
            // transcribing, so the meeting is never lost.
            let spoolURL = record.audioURL.deletingPathExtension().appendingPathExtension("caf")
            if FileManager.default.fileExists(atPath: spoolURL.path) {
                if AudioTranscoder.salvageSpool(caf: spoolURL, m4a: record.audioURL) {
                    await onProcessingIssue(job.meetingID, .recordingSalvageFailed, false)
                    if record.meeting.duration == 0, let duration = AudioTranscoder.duration(of: record.audioURL) {
                        await onDurationRecovered(job.meetingID, duration)
                    }
                } else if !FileManager.default.fileExists(atPath: record.audioURL.path) {
                    // Salvage failed, but the raw audio is still safe — the
                    // CAF spool is never deleted on a failed salvage. Distinct
                    // from `recordingFileMissing` below (nothing left at all)
                    // and must never fall through to it.
                    await onProcessingIssue(job.meetingID, .recordingSalvageFailed, true)
                    await reporter.finish(.error(message: RecoveryMessages.salvageFailed))
                    return
                }
            }
            guard FileManager.default.fileExists(atPath: record.audioURL.path) else {
                await onProcessingIssue(job.meetingID, .recordingFileMissing, true)
                await reporter.finish(.error(message: "Recording file missing"))
                return
            }
            guard let engine = await engineProvider() else {
                await reporter.finish(.needsModel)
                return
            }
            await reporter.publish(.transcribing(progress: 0))
            do {
                let diarizer = await diarizerProvider()
                // Diarization gets the tail of the progress bar when enabled.
                let transcribeShare = diarizer == nil ? 1.0 : 0.85
                var transcript = try await engine.transcribe(file: record.audioURL) { fraction in
                    let overall = fraction * transcribeShare
                    progress(overall)
                    Task { await reporter.publish(.transcribing(progress: overall)) }
                }
                if let diarizer {
                    do {
                        let turns = try await diarizer.speakerTurns(in: record.audioURL) { fraction in
                            let overall = transcribeShare + fraction * (1 - transcribeShare)
                            progress(overall)
                            Task { await reporter.publish(.transcribing(progress: overall)) }
                        }
                        transcript.utterances = SpeakerAssignment.label(transcript.utterances, with: turns)
                    } catch {
                        // Best-effort: a first run without network (models not
                        // yet downloaded) must not cost the transcript.
                        processorLog.error("Diarization skipped: \(String(describing: error), privacy: .private)")
                    }
                }
                try storage.saveTranscript(transcript, in: record)
                await onProcessingIssue(job.meetingID, .transcriptionFailed, false)
                await onProcessingIssue(job.meetingID, .recordingFileMissing, false)
                await onProcessingIssue(job.meetingID, .recordingSalvageFailed, false)
                if enhancer.isAvailable {
                    await reporter.finish(.enhancing)
                    await chain(ProcessingJob(kind: .enhance, meetingID: job.meetingID))
                } else {
                    // Apple Intelligence off → meeting completes transcript-only.
                    await reporter.finish(.ready)
                    await exportToConfiguredDestinations(record)
                }
            } catch is CancellationError {
                // Clean stop (cancel or a queue-level timeout): close the
                // reporter (no terminal status write) and rethrow so
                // `ProcessingQueue` treats it as a cancellation, not a
                // failure — it isn't retried and doesn't invoke `onJobFailed`.
                await reporter.close()
                throw CancellationError()
            } catch {
                // Rethrow instead of writing `.error` in-band:
                // swallowing the error made every engine failure look like a
                // success to `ProcessingQueue`, so its retry-once path never
                // fired. `close()` (not `finish()`) drops any late progress
                // update without appending a terminal status of its own —
                // `QueueStore.setOnJobFailed` writes the actual `.error`
                // status (and `.transcriptionFailed` issue) once the queue
                // has exhausted its retry.
                processorLog.error("Transcription failed: \(String(describing: error), privacy: .private)")
                await reporter.close()
                throw error
            }

        case .enhance:
            guard
                enhancer.isAvailable,
                let transcript = try storage.loadTranscript(in: record),
                !transcript.utterances.isEmpty
            else {
                await onStatus(job.meetingID, .ready)
                await exportToConfiguredDestinations(record)
                return
            }
            await onStatus(job.meetingID, .enhancing)
            let freeformNotes = (try? storage.loadNotes(in: record)) ?? ""
            let timedNotes = (try? storage.loadTimedNotes(in: record)) ?? []
            let rawNotes = NotesRendering.rawNotes(timed: timedNotes, freeform: freeformNotes)
            do {
                let result = try await enhancer.enhance(rawNotes: rawNotes, transcript: transcript)
                try storage.saveEnhancedNotes(result.notes, in: record)
                await onProcessingIssue(job.meetingID, .enhancementFailed, false)
                // Defensive: other NoteEnhancer implementations might hand
                // back an empty string; never persist one.
                let subtitle = result.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let subtitle, !subtitle.isEmpty {
                    await onSubtitle(job.meetingID, subtitle)
                }
            } catch {
                // Refused or failed twice — the meeting is still complete with
                // its transcript; the persisted issue exposes a retry from
                // the editor without treating the recording as lost.
                processorLog.error("Enhancement failed: \(String(describing: error), privacy: .private)")
                await onProcessingIssue(job.meetingID, .enhancementFailed, true)
            }
            await onStatus(job.meetingID, .ready)
            await exportToConfiguredDestinations(record)

        case .export:
            await exportToConfiguredDestinations(record)
        }
    }

    /// Mirrors a finished meeting to the configured folder-mirror backup.
    /// Best-effort: a failed export never affects the meeting itself.
    private func exportToConfiguredDestinations(_ record: MeetingRecord) async {
        changeBus.post(.meetingChanged(record.meeting.id))

        let s = await settings()

        if s.mirrorBackupEnabled, !s.mirrorFolderPath.isEmpty {
            await onBackupEvent(record.meeting.id, .started)
            let mirror = FolderMirrorExporter(destinationRootURL: URL(fileURLWithPath: s.mirrorFolderPath))
            do {
                try mirror.mirror(record)
                await onProcessingIssue(record.meeting.id, .mirrorBackupFailed, false)
                await onBackupEvent(record.meeting.id, .succeeded)
            } catch {
                let classified = MirrorError.classify(error)
                processorLog.error("Folder-mirror backup failed: \(String(describing: error), privacy: .private)")
                await onProcessingIssue(record.meeting.id, .mirrorBackupFailed, true)
                await onBackupEvent(record.meeting.id, .failed(classified))
            }
        }
    }
}

/// Serializes UI status delivery from synchronous engine progress callbacks.
/// The callbacks can only create unstructured tasks, so this actor closes the
/// stream before a terminal update and appends every already-accepted update
/// to one ordered tail. A late progress task therefore cannot regress a
/// meeting from `.ready`/`.enhancing` back to `.transcribing`.
private actor ProcessingStatusCoordinator {
    private let meetingID: UUID
    private let deliver: @Sendable (UUID, MeetingStatus) async -> Void
    private var closed = false
    private var tail: Task<Void, Never>?

    init(meetingID: UUID, deliver: @escaping @Sendable (UUID, MeetingStatus) async -> Void) {
        self.meetingID = meetingID
        self.deliver = deliver
    }

    func publish(_ status: MeetingStatus) {
        guard !closed else { return }
        append(status)
    }

    func finish(_ status: MeetingStatus) async {
        guard !closed else { return }
        closed = true
        append(status)
        await tail?.value
    }

    /// Like `finish`, but appends no terminal status of its own — used when
    /// the caller is about to rethrow an error instead (see the `.transcribe`
    /// catch blocks above) so a late progress task can't repaint after the
    /// throw, without this coordinator writing a status the caller isn't
    /// choosing.
    func close() async {
        guard !closed else { return }
        closed = true
        await tail?.value
    }

    private func append(_ status: MeetingStatus) {
        let previous = tail
        let meetingID = meetingID
        let deliver = deliver
        tail = Task {
            await previous?.value
            await deliver(meetingID, status)
        }
    }
}
