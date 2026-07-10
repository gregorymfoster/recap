import Foundation

/// A chunk of mono Float32 audio ready for transcription, with its position in the recording.
public struct AudioChunk: Sendable {
    public var samples: [Float]
    public var sampleRate: Double
    public var start: TimeInterval

    public init(samples: [Float], sampleRate: Double, start: TimeInterval) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.start = start
    }

    public var duration: TimeInterval {
        Double(samples.count) / sampleRate
    }
}

public enum TranscriptionUpdate: Sendable {
    /// In-progress tail — provisional, may be revised (rendered at reduced opacity).
    case partial(Utterance)
    /// Confirmed utterance — will appear in the final transcript.
    case confirmed(Utterance)
    case progress(Double)
    /// Pipeline health of the live streaming pass.
    case status(LiveState)
}

/// State of the live (streaming) transcription pipeline, yielded by
/// `TranscriptionEngine.transcribe(stream:)` implementations (e.g.
/// `WhisperKitEngine.runStreaming`). Exercised today by
/// `transcribe-probe --stream`; no UI currently consumes live transcription
/// during an active recording.
public enum LiveState: Equatable, Sendable {
    /// No streaming-capable model is installed at all — the caller never
    /// started a streaming task.
    case noModelInstalled
    /// The streaming WhisperKit instance is loading from disk.
    case loadingModel
    /// Loaded and producing (or ready to produce) live text.
    case live
    /// The streaming pipeline couldn't start or hit a fatal error. The
    /// post-stop file pass is unaffected and will still produce a transcript.
    case failed(reason: String)
}

/// A speech-to-text engine. Implementations: WhisperKit (v1); Parakeet / Apple SpeechAnalyzer later.
public protocol TranscriptionEngine: Sendable {
    /// Live transcription during recording. Provisional quality; the file pass is canonical.
    func transcribe(stream: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptionUpdate>
    /// Canonical post-hoc transcription of a completed recording.
    func transcribe(file: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript
}

/// Result of an enhancement pass: the enhanced notes plus an optional
/// one-line meeting subtitle.
public struct EnhancementResult: Sendable, Equatable {
    /// Enhanced notes markdown.
    public let notes: String
    /// One-line meeting subtitle, nil when generation failed or was skipped.
    public let subtitle: String?
    public init(notes: String, subtitle: String? = nil) {
        self.notes = notes
        self.subtitle = subtitle
    }
}

/// Merges the user's rough notes with the transcript into enhanced notes.
/// Implementations: Apple FoundationModels (v1); local llama.cpp/MLX backends later.
public protocol NoteEnhancer: Sendable {
    var isAvailable: Bool { get }
    func enhance(rawNotes: String, transcript: Transcript) async throws -> EnhancementResult
}
