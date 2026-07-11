import AVFoundation
import Foundation
import RecapCore
import RecapTranscription
import Testing
@testable import RecapUI

/// Fake `TranscriptionEngine` returning a canned transcript, configurable to
/// throw. Drives `progress` at 0.5/1.0 like the real WhisperKit engine does.
private struct FakeEngine: TranscriptionEngine {
    var transcript: Transcript
    var failure: Error?

    func transcribe(stream: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptionUpdate> {
        AsyncStream { $0.finish() }
    }

    func transcribe(file: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript {
        if let failure { throw failure }
        progress(0.5)
        progress(1.0)
        return transcript
    }
}

/// Fake `NoteEnhancer` with configurable availability/result.
private struct FakeEnhancer: NoteEnhancer {
    var isAvailable: Bool
    var result: EnhancementResult = EnhancementResult(notes: "enhanced!")
    var failure: Error?
    /// Captures the composed `rawNotes` input, so tests can assert on
    /// `NotesRendering`'s timed + freeform composition without re-deriving it.
    var onEnhance: (@Sendable (String) -> Void)?

    func enhance(rawNotes: String, transcript: Transcript) async throws -> EnhancementResult {
        onEnhance?(rawNotes)
        if let failure { throw failure }
        return result
    }
}

private struct StubError: Error {}

/// Fails its first call, succeeds every call after — used to prove
/// `ProcessingQueue`'s retry-once path now actually covers engine failures
/// (previously `MeetingProcessor` swallowed the error and wrote `.error`
/// itself, so the queue never saw a failure to retry).
private actor FlakyOnceEngineState {
    private var callCount = 0

    func nextAttempt() -> Int {
        callCount += 1
        return callCount
    }
}

private struct FlakyOnceEngine: TranscriptionEngine {
    let transcript: Transcript
    let state = FlakyOnceEngineState()

    func transcribe(stream: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptionUpdate> {
        AsyncStream { $0.finish() }
    }

    func transcribe(file: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript {
        let attempt = await state.nextAttempt()
        guard attempt > 1 else { throw StubError() }
        progress(1.0)
        return transcript
    }
}

/// Collects `onStatus` transitions off the main actor, from `@Sendable`
/// closures that may run on arbitrary executors.
private actor StatusCollector {
    private(set) var statuses: [(UUID, MeetingStatus)] = []

    func record(_ id: UUID, _ status: MeetingStatus) {
        statuses.append((id, status))
    }

    var all: [MeetingStatus] { statuses.map(\.1) }
}

/// Collects chained follow-up jobs.
private actor ChainCollector {
    private(set) var jobs: [ProcessingJob] = []

    func record(_ job: ProcessingJob) {
        jobs.append(job)
    }
}

/// Collects mirror-backup lifecycle events reported via `onBackupEvent`.
private actor BackupCollector {
    private(set) var events: [(UUID, BackupEvent)] = []

    func record(_ id: UUID, _ event: BackupEvent) {
        events.append((id, event))
    }

    /// Meeting IDs whose mirror succeeded, in order.
    var succeededMeetingIDs: [UUID] {
        events.compactMap { id, event in event == .succeeded ? id : nil }
    }
}

/// Collects subtitles reported by the enhance job's `onSubtitle`.
private actor SubtitleCollector {
    private(set) var subtitles: [(UUID, String)] = []

    func record(_ id: UUID, _ subtitle: String) {
        subtitles.append((id, subtitle))
    }
}

/// Collects persisted, privacy-safe issue transitions from the processor.
private actor IssueCollector {
    private(set) var updates: [(UUID, ProcessingIssue, Bool)] = []

    func record(_ id: UUID, _ issue: ProcessingIssue, _ isActive: Bool) {
        updates.append((id, issue, isActive))
    }
}

@Suite struct MeetingProcessorTests {
    private func makeStorage() -> LibraryStorage {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingProcessorTests-\(UUID().uuidString)")
        return LibraryStorage(rootURL: root)
    }

    /// `MeetingProcessor` only checks `fileExists` before handing the file to
    /// the (fake) engine, so a zero-byte file is enough to stand in for audio.
    private func touchAudioFile(for record: MeetingRecord) throws {
        try Data().write(to: record.audioURL)
    }

    /// Writes a valid, readable CAF spool — mirrors the recorder's crash
    /// spool format (see `RecapAudio`'s `AudioTranscoderTests`), so
    /// `AudioTranscoder.salvageSpool` can successfully transcode it.
    private func writeValidCAFSpool(at url: URL) throws {
        let sampleRate = 48_000.0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        )!
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false
        )
        let frames = AVAudioFrameCount(sampleRate * 0.5)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            buffer.floatChannelData![0][i] = sinf(Float(i) * 2 * .pi * 440 / Float(sampleRate)) * 0.5
        }
        try file.write(from: buffer)
    }

    private func makeTranscript(text: String = "Let's ship it.") -> Transcript {
        Transcript(
            utterances: [Utterance(start: 0, end: 2, text: text)],
            engine: "whisperkit", model: "openai_whisper-tiny", language: "en"
        )
    }

    private func makeProcessor(
        storage: LibraryStorage,
        engine: TranscriptionEngine? = nil,
        diarizer: SpeakerDiarizer? = nil,
        enhancer: NoteEnhancer = FakeEnhancer(isAvailable: false),
        settings: @escaping @Sendable () async -> ProcessorSettings = { ProcessorSettings.disabled },
        statusCollector: StatusCollector,
        chainCollector: ChainCollector,
        backupCollector: BackupCollector? = nil,
        subtitleCollector: SubtitleCollector? = nil,
        issueCollector: IssueCollector? = nil,
        changeBus: LibraryChangeBus = LibraryChangeBus()
    ) -> MeetingProcessor {
        MeetingProcessor(
            storage: storage,
            engineProvider: { @Sendable in engine },
            diarizerProvider: { @Sendable in diarizer },
            enhancer: enhancer,
            settings: settings,
            onStatus: { @Sendable id, status in await statusCollector.record(id, status) },
            onDurationRecovered: { @Sendable _, _ in },
            onBackupEvent: { @Sendable id, event in await backupCollector?.record(id, event) },
            chain: { @Sendable job in await chainCollector.record(job) },
            changeBus: changeBus,
            onSubtitle: { @Sendable id, subtitle in await subtitleCollector?.record(id, subtitle) },
            onProcessingIssue: { @Sendable id, issue, isActive in
                await issueCollector?.record(id, issue, isActive)
            }
        )
    }

    // MARK: 1. Happy transcribe → chain to enhance

    @Test func happyTranscribeChainsToEnhance() async throws {
        let storage = makeStorage()
        let record = try storage.create(Meeting(title: "Standup", date: .now))
        try touchAudioFile(for: record)
        let transcript = makeTranscript()
        let statusCollector = StatusCollector()
        let chainCollector = ChainCollector()
        let processor = makeProcessor(
            storage: storage,
            engine: FakeEngine(transcript: transcript),
            enhancer: FakeEnhancer(isAvailable: true),
            statusCollector: statusCollector,
            chainCollector: chainCollector
        )

        try await processor.execute(
            ProcessingJob(kind: .transcribe, meetingID: record.meeting.id), progress: { _ in }
        )

        let statuses = await statusCollector.all
        #expect(statuses.last == .enhancing)
        let jobs = await chainCollector.jobs
        #expect(jobs == [ProcessingJob(kind: .enhance, meetingID: record.meeting.id)])
        #expect(try storage.loadTranscript(in: record) == transcript)
    }

    // MARK: 2. Enhancer unavailable

    @Test func enhancerUnavailableGoesReadyWithoutChaining() async throws {
        let storage = makeStorage()
        let record = try storage.create(Meeting(title: "Standup", date: .now))
        try touchAudioFile(for: record)
        let transcript = makeTranscript()
        let statusCollector = StatusCollector()
        let chainCollector = ChainCollector()
        let processor = makeProcessor(
            storage: storage,
            engine: FakeEngine(transcript: transcript),
            enhancer: FakeEnhancer(isAvailable: false),
            statusCollector: statusCollector,
            chainCollector: chainCollector
        )

        try await processor.execute(
            ProcessingJob(kind: .transcribe, meetingID: record.meeting.id), progress: { _ in }
        )

        let statuses = await statusCollector.all
        #expect(statuses.last == .ready)
        let jobs = await chainCollector.jobs
        #expect(jobs.isEmpty)
        #expect(try storage.loadTranscript(in: record) == transcript)
    }

    @Test func lateProgressCannotOverwriteReady() async throws {
        let storage = makeStorage()
        let record = try storage.create(Meeting(title: "Standup", date: .now))
        try touchAudioFile(for: record)
        let statusCollector = StatusCollector()
        let chainCollector = ChainCollector()
        let processor = makeProcessor(
            storage: storage,
            engine: FakeEngine(transcript: makeTranscript()),
            enhancer: FakeEnhancer(isAvailable: false),
            statusCollector: statusCollector,
            chainCollector: chainCollector
        )

        try await processor.execute(
            ProcessingJob(kind: .transcribe, meetingID: record.meeting.id), progress: { _ in }
        )
        // Give unstructured progress callbacks a chance to run after the
        // terminal status was delivered; they must be discarded.
        await Task.yield()

        let statuses = await statusCollector.all
        #expect(statuses.last == .ready)
        #expect(!statuses.dropLast().contains(.ready))
    }

    // MARK: 3. No engine

    @Test func noEngineNeedsModel() async throws {
        let storage = makeStorage()
        let record = try storage.create(Meeting(title: "Standup", date: .now))
        try touchAudioFile(for: record)
        let statusCollector = StatusCollector()
        let chainCollector = ChainCollector()
        let processor = makeProcessor(
            storage: storage,
            engine: nil,
            statusCollector: statusCollector,
            chainCollector: chainCollector
        )

        try await processor.execute(
            ProcessingJob(kind: .transcribe, meetingID: record.meeting.id), progress: { _ in }
        )

        let statuses = await statusCollector.all
        #expect(statuses == [.needsModel])
        #expect(try storage.loadTranscript(in: record) == nil)
    }

    // MARK: 4. Missing audio file

    @Test func missingAudioFileErrors() async throws {
        let storage = makeStorage()
        let record = try storage.create(Meeting(title: "Standup", date: .now))
        // Intentionally do not write audio.m4a.
        let statusCollector = StatusCollector()
        let chainCollector = ChainCollector()
        let processor = makeProcessor(
            storage: storage,
            engine: FakeEngine(transcript: makeTranscript()),
            statusCollector: statusCollector,
            chainCollector: chainCollector
        )

        try await processor.execute(
            ProcessingJob(kind: .transcribe, meetingID: record.meeting.id), progress: { _ in }
        )

        let statuses = await statusCollector.all
        #expect(statuses == [.error(message: "Recording file missing")])
    }

    // MARK: 5. Engine throws

    /// Fix: the processor no longer writes `.error` itself on an engine
    /// failure — it rethrows, so `ProcessingQueue`'s retry-once path can
    /// actually fire (previously this catch swallowed the error, so the
    /// queue never saw a failure to retry). `QueueStore.setOnJobFailed`
    /// writes the `.error` status once the queue gives up.
    @Test func engineThrowsRethrowsWithoutWritingErrorStatus() async throws {
        let storage = makeStorage()
        let record = try storage.create(Meeting(title: "Standup", date: .now))
        try touchAudioFile(for: record)
        let statusCollector = StatusCollector()
        let chainCollector = ChainCollector()
        let processor = makeProcessor(
            storage: storage,
            engine: FakeEngine(transcript: makeTranscript(), failure: StubError()),
            statusCollector: statusCollector,
            chainCollector: chainCollector
        )

        await #expect(throws: StubError.self) {
            try await processor.execute(
                ProcessingJob(kind: .transcribe, meetingID: record.meeting.id), progress: { _ in }
            )
        }

        let statuses = await statusCollector.all
        #expect(!statuses.contains { if case .error = $0 { true } else { false } })
        #expect(try storage.loadTranscript(in: record) == nil)
    }

    // MARK: 5a. Crash-spool salvage

    /// A garbage (unreadable) .caf spool with no m4a: `salvageSpool` fails,
    /// but per its contract the spool is never deleted on failure — the raw
    /// audio is still safe. This is a distinct, recoverable issue from
    /// `recordingFileMissing` and must never fall through to it.
    @Test func garbageCAFWithNoM4ASetsSalvageFailedIssue() async throws {
        let storage = makeStorage()
        let record = try storage.create(Meeting(title: "Standup", date: .now))
        let spoolURL = record.audioURL.deletingPathExtension().appendingPathExtension("caf")
        try Data(repeating: 0xAB, count: 256).write(to: spoolURL)
        // Intentionally no audio.m4a.

        let statusCollector = StatusCollector()
        let chainCollector = ChainCollector()
        let issueCollector = IssueCollector()
        let processor = makeProcessor(
            storage: storage,
            engine: FakeEngine(transcript: makeTranscript()),
            statusCollector: statusCollector,
            chainCollector: chainCollector,
            issueCollector: issueCollector
        )

        try await processor.execute(
            ProcessingJob(kind: .transcribe, meetingID: record.meeting.id), progress: { _ in }
        )

        let statuses = await statusCollector.all
        #expect(statuses == [.error(message: "Couldn't restore recording")])
        let issues = await issueCollector.updates
        #expect(issues.count == 1)
        #expect(issues.first?.1 == .recordingSalvageFailed)
        #expect(issues.first?.2 == true)
        // The spool is the only surviving copy — it must not be lost.
        #expect(FileManager.default.fileExists(atPath: spoolURL.path))
        #expect(try storage.loadTranscript(in: record) == nil)
    }

    /// A valid .caf spool: salvage succeeds, clears any prior
    /// `.recordingSalvageFailed` issue, and transcription proceeds normally.
    @Test func validCAFSalvagesSuccessfullyAndClearsIssue() async throws {
        let storage = makeStorage()
        let record = try storage.create(Meeting(title: "Standup", date: .now))
        let spoolURL = record.audioURL.deletingPathExtension().appendingPathExtension("caf")
        try writeValidCAFSpool(at: spoolURL)

        let transcript = makeTranscript()
        let statusCollector = StatusCollector()
        let chainCollector = ChainCollector()
        let issueCollector = IssueCollector()
        let processor = makeProcessor(
            storage: storage,
            engine: FakeEngine(transcript: transcript),
            enhancer: FakeEnhancer(isAvailable: false),
            statusCollector: statusCollector,
            chainCollector: chainCollector,
            issueCollector: issueCollector
        )

        try await processor.execute(
            ProcessingJob(kind: .transcribe, meetingID: record.meeting.id), progress: { _ in }
        )

        let statuses = await statusCollector.all
        #expect(statuses.last == .ready)
        #expect(try storage.loadTranscript(in: record) == transcript)
        let issues = await issueCollector.updates
        #expect(issues.contains { $0.1 == .recordingSalvageFailed && $0.2 == false })
        // Salvage cleans up the spool once the m4a is safe.
        #expect(!FileManager.default.fileExists(atPath: spoolURL.path))
    }

    /// End-to-end: a real `ProcessingQueue` wrapping a `MeetingProcessor`
    /// whose engine fails once then succeeds. Proves the queue's
    /// retry-once path now actually covers engine failures — before the
    /// rethrow fix, `MeetingProcessor` swallowed the error and wrote
    /// `.error` itself, so the queue never even saw a failure to retry.
    @Test func processingQueueRetriesEngineFailureAndMeetingCompletes() async throws {
        let storage = makeStorage()
        let record = try storage.create(Meeting(title: "Standup", date: .now))
        try touchAudioFile(for: record)
        let transcript = makeTranscript()
        let statusCollector = StatusCollector()
        let chainCollector = ChainCollector()
        let processor = makeProcessor(
            storage: storage,
            engine: FlakyOnceEngine(transcript: transcript),
            enhancer: FakeEnhancer(isAvailable: false),
            statusCollector: statusCollector,
            chainCollector: chainCollector
        )

        let queue = ProcessingQueue(executor: processor)
        await queue.enqueue(ProcessingJob(kind: .transcribe, meetingID: record.meeting.id))

        let deadline = ContinuousClock.now + .seconds(3)
        while await queue.snapshot.jobCount != 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(await queue.snapshot.jobCount == 0)
        let statuses = await statusCollector.all
        #expect(statuses.last == .ready)
        #expect(try storage.loadTranscript(in: record) == transcript)
    }

    // MARK: 6. Enhance job happy path

    @Test func enhanceJobHappyPathSavesNotes() async throws {
        let storage = makeStorage()
        let record = try storage.create(Meeting(title: "Standup", date: .now))
        try storage.saveTranscript(makeTranscript(), in: record)
        let statusCollector = StatusCollector()
        let chainCollector = ChainCollector()
        let processor = makeProcessor(
            storage: storage,
            enhancer: FakeEnhancer(isAvailable: true, result: EnhancementResult(notes: "## Notes\nShipped it.")),
            statusCollector: statusCollector,
            chainCollector: chainCollector
        )

        try await processor.execute(
            ProcessingJob(kind: .enhance, meetingID: record.meeting.id), progress: { _ in }
        )

        let statuses = await statusCollector.all
        #expect(statuses.last == .ready)
        #expect(try storage.loadEnhancedNotes(in: record) == "## Notes\nShipped it.")
    }

    // MARK: 6a. Enhance job composes rawNotes from timed + freeform notes

    /// Synchronous capture box for the one `enhance(rawNotes:transcript:)`
    /// call the enhance job makes — safe as `@unchecked Sendable` because the
    /// test only reads it after `await`ing `processor.execute` to completion,
    /// so there is no concurrent access.
    private final class RawNotesCapture: @unchecked Sendable {
        var value: String?
    }

    @Test func enhanceJobComposesRawNotesFromTimedAndFreeformNotes() async throws {
        let storage = makeStorage()
        let record = try storage.create(Meeting(title: "Standup", date: .now))
        try storage.saveTranscript(makeTranscript(), in: record)
        try storage.saveNotes("- action item", in: record)
        try storage.saveTimedNotes([TimedNote(offset: 5, text: "Kickoff")], in: record)

        let statusCollector = StatusCollector()
        let chainCollector = ChainCollector()
        let capture = RawNotesCapture()
        let processor = makeProcessor(
            storage: storage,
            enhancer: FakeEnhancer(isAvailable: true, onEnhance: { rawNotes in capture.value = rawNotes }),
            statusCollector: statusCollector,
            chainCollector: chainCollector
        )

        try await processor.execute(
            ProcessingJob(kind: .enhance, meetingID: record.meeting.id), progress: { _ in }
        )

        #expect(capture.value == "[0:05] Kickoff\n\n- action item")
    }

    // MARK: 6b. Enhance job reports the generated subtitle

    @Test func enhanceJobReportsSubtitle() async throws {
        let storage = makeStorage()
        let record = try storage.create(Meeting(title: "Standup", date: .now))
        try storage.saveTranscript(makeTranscript(), in: record)
        let statusCollector = StatusCollector()
        let chainCollector = ChainCollector()
        let subtitleCollector = SubtitleCollector()
        let processor = makeProcessor(
            storage: storage,
            enhancer: FakeEnhancer(
                isAvailable: true,
                result: EnhancementResult(notes: "## Notes\nShipped it.", subtitle: "Ship decision made, launch set for Friday")
            ),
            statusCollector: statusCollector,
            chainCollector: chainCollector,
            subtitleCollector: subtitleCollector
        )

        try await processor.execute(
            ProcessingJob(kind: .enhance, meetingID: record.meeting.id), progress: { _ in }
        )

        let subtitles = await subtitleCollector.subtitles
        #expect(subtitles.count == 1)
        #expect(subtitles.first?.0 == record.meeting.id)
        #expect(subtitles.first?.1 == "Ship decision made, launch set for Friday")
        #expect(try storage.loadEnhancedNotes(in: record) == "## Notes\nShipped it.")
    }

    @Test func enhanceJobSkipsNilOrEmptySubtitle() async throws {
        for subtitle in [nil, "", "   \n"] as [String?] {
            let storage = makeStorage()
            let record = try storage.create(Meeting(title: "Standup", date: .now))
            try storage.saveTranscript(makeTranscript(), in: record)
            let statusCollector = StatusCollector()
            let chainCollector = ChainCollector()
            let subtitleCollector = SubtitleCollector()
            let processor = makeProcessor(
                storage: storage,
                enhancer: FakeEnhancer(
                    isAvailable: true,
                    result: EnhancementResult(notes: "notes", subtitle: subtitle)
                ),
                statusCollector: statusCollector,
                chainCollector: chainCollector,
                subtitleCollector: subtitleCollector
            )

            try await processor.execute(
                ProcessingJob(kind: .enhance, meetingID: record.meeting.id), progress: { _ in }
            )

            let subtitles = await subtitleCollector.subtitles
            #expect(subtitles.isEmpty)
            let statuses = await statusCollector.all
            #expect(statuses.last == .ready)
        }
    }

    // MARK: 7. Enhance job, enhancer throws

    @Test func enhanceJobEnhancerThrowsStillReady() async throws {
        let storage = makeStorage()
        let record = try storage.create(Meeting(title: "Standup", date: .now))
        try storage.saveTranscript(makeTranscript(), in: record)
        let statusCollector = StatusCollector()
        let chainCollector = ChainCollector()
        let issueCollector = IssueCollector()
        let processor = makeProcessor(
            storage: storage,
            enhancer: FakeEnhancer(isAvailable: true, failure: StubError()),
            statusCollector: statusCollector,
            chainCollector: chainCollector,
            issueCollector: issueCollector
        )

        try await processor.execute(
            ProcessingJob(kind: .enhance, meetingID: record.meeting.id), progress: { _ in }
        )

        let statuses = await statusCollector.all
        #expect(statuses.last == .ready)
        #expect(try storage.loadEnhancedNotes(in: record) == nil)
        let issues = await issueCollector.updates
        #expect(issues.count == 1)
        #expect(issues.first?.0 == record.meeting.id)
        #expect(issues.first?.1 == .enhancementFailed)
        #expect(issues.first?.2 == true)
    }

    // MARK: 8. Enhance job, no transcript on disk

    @Test func enhanceJobNoTranscriptGoesReadyImmediately() async throws {
        let storage = makeStorage()
        let record = try storage.create(Meeting(title: "Standup", date: .now))
        // No transcript saved.
        let statusCollector = StatusCollector()
        let chainCollector = ChainCollector()
        let processor = makeProcessor(
            storage: storage,
            enhancer: FakeEnhancer(isAvailable: true),
            statusCollector: statusCollector,
            chainCollector: chainCollector
        )

        try await processor.execute(
            ProcessingJob(kind: .enhance, meetingID: record.meeting.id), progress: { _ in }
        )

        let statuses = await statusCollector.all
        #expect(statuses == [.ready])
    }

    // MARK: 9. Export destinations

    @Test func exportsToConfiguredDestinationsWhenEnabled() async throws {
        let storage = makeStorage()
        let record = try storage.create(Meeting(title: "Standup", date: .now))
        try storage.saveTranscript(makeTranscript(), in: record)

        let mirrorDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MirrorBackup-\(UUID().uuidString)")
        // The exporter now refuses to invent a missing destination root
        // (that's the `destinationUnreachable` signal) — a real destination
        // is a folder the user already picked, so create it.
        try FileManager.default.createDirectory(at: mirrorDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mirrorDir) }

        let statusCollector = StatusCollector()
        let chainCollector = ChainCollector()
        let backupCollector = BackupCollector()
        let processor = makeProcessor(
            storage: storage,
            enhancer: FakeEnhancer(isAvailable: false),
            settings: {
                ProcessorSettings(mirrorBackupEnabled: true, mirrorFolderPath: mirrorDir.path)
            },
            statusCollector: statusCollector,
            chainCollector: chainCollector,
            backupCollector: backupCollector
        )

        try await processor.execute(
            ProcessingJob(kind: .enhance, meetingID: record.meeting.id), progress: { _ in }
        )

        let statuses = await statusCollector.all
        #expect(statuses.last == .ready)
        let mirrored = try FileManager.default.contentsOfDirectory(atPath: mirrorDir.path)
        #expect(!mirrored.isEmpty)
        // A successful mirror reports .started then .succeeded so the
        // meeting's lastBackupDate gets persisted (and the UI can show
        // "Backed up" / the aggregate footer can show "working").
        let events = await backupCollector.events
        #expect(events.map(\.0) == [record.meeting.id, record.meeting.id])
        #expect(events.map(\.1) == [.started, .succeeded])
    }

    @Test func doesNotExportWhenTogglesAreOff() async throws {
        let storage = makeStorage()
        let record = try storage.create(Meeting(title: "Standup", date: .now))
        try storage.saveTranscript(makeTranscript(), in: record)

        let mirrorDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MirrorBackupOff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: mirrorDir) }

        let statusCollector = StatusCollector()
        let chainCollector = ChainCollector()
        let backupCollector = BackupCollector()
        let processor = makeProcessor(
            storage: storage,
            enhancer: FakeEnhancer(isAvailable: false),
            settings: {
                ProcessorSettings(mirrorBackupEnabled: false, mirrorFolderPath: mirrorDir.path)
            },
            statusCollector: statusCollector,
            chainCollector: chainCollector,
            backupCollector: backupCollector
        )

        try await processor.execute(
            ProcessingJob(kind: .enhance, meetingID: record.meeting.id), progress: { _ in }
        )

        #expect(!FileManager.default.fileExists(atPath: mirrorDir.path))
        let events = await backupCollector.events
        #expect(events.isEmpty)
    }

    @Test func missingAudioReportsPersistentRecoveryIssue() async throws {
        let storage = makeStorage()
        let record = try storage.create(Meeting(title: "Standup", date: .now))
        let statusCollector = StatusCollector()
        let chainCollector = ChainCollector()
        let issueCollector = IssueCollector()
        let processor = makeProcessor(
            storage: storage,
            engine: FakeEngine(transcript: makeTranscript()),
            statusCollector: statusCollector,
            chainCollector: chainCollector,
            issueCollector: issueCollector
        )

        try await processor.execute(
            ProcessingJob(kind: .transcribe, meetingID: record.meeting.id), progress: { _ in }
        )

        let issues = await issueCollector.updates
        #expect(issues.count == 1)
        #expect(issues.first?.0 == record.meeting.id)
        #expect(issues.first?.1 == .recordingFileMissing)
        #expect(issues.first?.2 == true)
    }

    // MARK: 10. Diarizer disabled is best-effort — transcription still completes

    @Test func nilDiarizerStillCompletesTranscription() async throws {
        let storage = makeStorage()
        let record = try storage.create(Meeting(title: "Standup", date: .now))
        try touchAudioFile(for: record)
        let transcript = makeTranscript()
        let statusCollector = StatusCollector()
        let chainCollector = ChainCollector()
        let processor = makeProcessor(
            storage: storage,
            engine: FakeEngine(transcript: transcript),
            diarizer: nil,
            enhancer: FakeEnhancer(isAvailable: false),
            statusCollector: statusCollector,
            chainCollector: chainCollector
        )

        try await processor.execute(
            ProcessingJob(kind: .transcribe, meetingID: record.meeting.id), progress: { _ in }
        )

        let statuses = await statusCollector.all
        #expect(statuses.last == .ready)
        #expect(try storage.loadTranscript(in: record) == transcript)
    }
}

extension ProcessorSettings {
    /// All sync/export toggles off — the default for tests that don't care
    /// about export behavior.
    fileprivate static var disabled: ProcessorSettings {
        ProcessorSettings(mirrorBackupEnabled: false, mirrorFolderPath: "")
    }
}
