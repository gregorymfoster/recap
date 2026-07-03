import Foundation
import Observation
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
    /// The folder-mirror backup succeeded for this meeting — persist the
    /// timestamp so the UI can truthfully show "Backed up".
    let onBackedUp: @Sendable (UUID) async -> Void
    /// Enqueues a follow-up job (transcribe → enhance chaining).
    let chain: @Sendable (ProcessingJob) async -> Void
    /// Announces a meeting is about to be exported, so other subscribers
    /// (folder mirror, future CloudKit sync) see the same completion signal.
    let changeBus: LibraryChangeBus

    func execute(_ job: ProcessingJob, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let record = try storage.loadAll().first(where: { $0.meeting.id == job.meetingID })
        else { return }

        switch job.kind {
        case .transcribe:
            // A leftover CAF spool means the recording died mid-write (crash,
            // power loss, disk full): rebuild the m4a from it before
            // transcribing, so the meeting is never lost.
            let spoolURL = record.audioURL.deletingPathExtension().appendingPathExtension("caf")
            if FileManager.default.fileExists(atPath: spoolURL.path) {
                if AudioTranscoder.salvageSpool(caf: spoolURL, m4a: record.audioURL),
                   record.meeting.duration == 0,
                   let duration = AudioTranscoder.duration(of: record.audioURL) {
                    await onDurationRecovered(job.meetingID, duration)
                }
            }
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
                let diarizer = await diarizerProvider()
                // Diarization gets the tail of the progress bar when enabled.
                let transcribeShare = diarizer == nil ? 1.0 : 0.85
                var transcript = try await engine.transcribe(file: record.audioURL) { fraction in
                    let overall = fraction * transcribeShare
                    progress(overall)
                    Task { await onStatus(job.meetingID, .transcribing(progress: overall)) }
                }
                if let diarizer {
                    do {
                        let turns = try await diarizer.speakerTurns(in: record.audioURL) { fraction in
                            let overall = transcribeShare + fraction * (1 - transcribeShare)
                            progress(overall)
                            Task { await onStatus(job.meetingID, .transcribing(progress: overall)) }
                        }
                        transcript.utterances = SpeakerAssignment.label(transcript.utterances, with: turns)
                    } catch {
                        // Best-effort: a first run without network (models not
                        // yet downloaded) must not cost the transcript.
                        processorLog.error("Diarization skipped: \(error, privacy: .public)")
                    }
                }
                try storage.saveTranscript(transcript, in: record)
                if enhancer.isAvailable {
                    await onStatus(job.meetingID, .enhancing)
                    await chain(ProcessingJob(kind: .enhance, meetingID: job.meetingID))
                } else {
                    // Apple Intelligence off → meeting completes transcript-only.
                    await onStatus(job.meetingID, .ready)
                    await exportToConfiguredDestinations(record)
                }
            } catch {
                processorLog.error("Transcription failed: \(error, privacy: .public)")
                await onStatus(job.meetingID, .error(message: "Transcription failed"))
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
            let notes = (try? storage.loadNotes(in: record)) ?? ""
            do {
                let enhanced = try await enhancer.enhance(rawNotes: notes, transcript: transcript)
                try storage.saveEnhancedNotes(enhanced, in: record)
            } catch {
                // Refused or failed twice — the meeting is still complete with
                // its transcript; enhancement can be retried from the editor.
            }
            await onStatus(job.meetingID, .ready)
            await exportToConfiguredDestinations(record)
        }
    }

    /// Mirrors a finished meeting to the configured sync destinations
    /// (Obsidian vault, folder-mirror backup, webhook). Best-effort: a failed
    /// export never affects the meeting itself.
    private func exportToConfiguredDestinations(_ record: MeetingRecord) async {
        changeBus.post(.meetingChanged(record.meeting.id))

        let s = await settings()
        let notes = try? storage.loadNotes(in: record)
        let enhanced = (try? storage.loadEnhancedNotes(in: record)) ?? nil
        let transcript = try? storage.loadTranscript(in: record)

        if s.syncsToObsidian, !s.obsidianVaultPath.isEmpty {
            let exporter = ObsidianExporter(vaultFolderURL: URL(fileURLWithPath: s.obsidianVaultPath))
            do {
                try exporter.export(record, notes: notes, enhanced: enhanced, transcript: transcript)
            } catch {
                processorLog.error("Obsidian export failed: \(error, privacy: .public)")
            }
        }

        if s.mirrorBackupEnabled, !s.mirrorFolderPath.isEmpty {
            let mirror = FolderMirrorExporter(destinationRootURL: URL(fileURLWithPath: s.mirrorFolderPath))
            do {
                try mirror.mirror(record)
                await onBackedUp(record.meeting.id)
            } catch {
                processorLog.error("Folder-mirror backup failed: \(error, privacy: .public)")
            }
        }

        if !s.webhookURL.isEmpty,
           let url = URL(string: s.webhookURL), url.scheme?.hasPrefix("http") == true {
            let exporter = WebhookExporter(endpoint: url)
            let meeting = record.meeting
            Task {
                do {
                    try await exporter.send(
                        meeting, notes: notes, enhanced: enhanced, transcript: transcript
                    )
                } catch {
                    processorLog.error("Webhook delivery failed: \(error, privacy: .public)")
                }
            }
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

    /// - Parameter onError: Fired once per meeting when the processing
    ///   pipeline transitions it to `.error`, so the UI can surface a toast
    ///   in addition to the row chip `updateStatus` already produces.
    /// - Parameter enhancer: Injectable so tests can hand in a fake through
    ///   this public surface; production always uses `FoundationModelEnhancer()`.
    public init(
        library: LibraryStore, storage: LibraryStorage, models: WhisperModelManager,
        changeBus: LibraryChangeBus, settings: SettingsStore,
        enhancer: NoteEnhancer = FoundationModelEnhancer(),
        onError: (@MainActor (String) -> Void)? = nil
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
                await library.updateStatus(id, to: status)
                if case .error(let message) = status {
                    await onError?(message)
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
            changeBus: changeBus
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
