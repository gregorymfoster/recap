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
    var result: String = "enhanced!"
    var failure: Error?

    func enhance(rawNotes: String, transcript: Transcript) async throws -> String {
        if let failure { throw failure }
        return result
    }
}

private struct StubError: Error {}

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
            chain: { @Sendable job in await chainCollector.record(job) },
            changeBus: changeBus
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

    @Test func engineThrowsErrorsTranscription() async throws {
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

        try await processor.execute(
            ProcessingJob(kind: .transcribe, meetingID: record.meeting.id), progress: { _ in }
        )

        let statuses = await statusCollector.all
        #expect(statuses.last == .error(message: "Transcription failed"))
        #expect(try storage.loadTranscript(in: record) == nil)
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
            enhancer: FakeEnhancer(isAvailable: true, result: "## Notes\nShipped it."),
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

    // MARK: 7. Enhance job, enhancer throws

    @Test func enhanceJobEnhancerThrowsStillReady() async throws {
        let storage = makeStorage()
        let record = try storage.create(Meeting(title: "Standup", date: .now))
        try storage.saveTranscript(makeTranscript(), in: record)
        let statusCollector = StatusCollector()
        let chainCollector = ChainCollector()
        let processor = makeProcessor(
            storage: storage,
            enhancer: FakeEnhancer(isAvailable: true, failure: StubError()),
            statusCollector: statusCollector,
            chainCollector: chainCollector
        )

        try await processor.execute(
            ProcessingJob(kind: .enhance, meetingID: record.meeting.id), progress: { _ in }
        )

        let statuses = await statusCollector.all
        #expect(statuses.last == .ready)
        #expect(try storage.loadEnhancedNotes(in: record) == nil)
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

        let vaultDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObsidianVault-\(UUID().uuidString)")
        let mirrorDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MirrorBackup-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: vaultDir)
            try? FileManager.default.removeItem(at: mirrorDir)
        }

        let statusCollector = StatusCollector()
        let chainCollector = ChainCollector()
        let processor = makeProcessor(
            storage: storage,
            enhancer: FakeEnhancer(isAvailable: false),
            settings: {
                ProcessorSettings(
                    transcriptionLanguage: nil,
                    labelsSpeakers: true,
                    syncsToObsidian: true,
                    obsidianVaultPath: vaultDir.path,
                    mirrorBackupEnabled: true,
                    mirrorFolderPath: mirrorDir.path,
                    webhookURL: ""
                )
            },
            statusCollector: statusCollector,
            chainCollector: chainCollector
        )

        try await processor.execute(
            ProcessingJob(kind: .enhance, meetingID: record.meeting.id), progress: { _ in }
        )

        let statuses = await statusCollector.all
        #expect(statuses.last == .ready)
        let exportedMarkdown = try FileManager.default.contentsOfDirectory(atPath: vaultDir.path)
        #expect(!exportedMarkdown.isEmpty)
        let mirrored = try FileManager.default.contentsOfDirectory(atPath: mirrorDir.path)
        #expect(!mirrored.isEmpty)
    }

    @Test func doesNotExportWhenTogglesAreOff() async throws {
        let storage = makeStorage()
        let record = try storage.create(Meeting(title: "Standup", date: .now))
        try storage.saveTranscript(makeTranscript(), in: record)

        let vaultDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObsidianVaultOff-\(UUID().uuidString)")
        let mirrorDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MirrorBackupOff-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: vaultDir)
            try? FileManager.default.removeItem(at: mirrorDir)
        }

        let statusCollector = StatusCollector()
        let chainCollector = ChainCollector()
        let processor = makeProcessor(
            storage: storage,
            enhancer: FakeEnhancer(isAvailable: false),
            settings: {
                ProcessorSettings(
                    transcriptionLanguage: nil,
                    labelsSpeakers: true,
                    syncsToObsidian: false,
                    obsidianVaultPath: vaultDir.path,
                    mirrorBackupEnabled: false,
                    mirrorFolderPath: mirrorDir.path,
                    webhookURL: ""
                )
            },
            statusCollector: statusCollector,
            chainCollector: chainCollector
        )

        try await processor.execute(
            ProcessingJob(kind: .enhance, meetingID: record.meeting.id), progress: { _ in }
        )

        #expect(!FileManager.default.fileExists(atPath: vaultDir.path))
        #expect(!FileManager.default.fileExists(atPath: mirrorDir.path))
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
        ProcessorSettings(
            transcriptionLanguage: nil,
            labelsSpeakers: true,
            syncsToObsidian: false,
            obsidianVaultPath: "",
            mirrorBackupEnabled: false,
            mirrorFolderPath: "",
            webhookURL: ""
        )
    }
}
