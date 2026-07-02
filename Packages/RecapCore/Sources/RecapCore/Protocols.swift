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
}

/// A speech-to-text engine. Implementations: WhisperKit (v1); Parakeet / Apple SpeechAnalyzer later.
public protocol TranscriptionEngine: Sendable {
    /// Live transcription during recording. Provisional quality; the file pass is canonical.
    func transcribe(stream: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptionUpdate>
    /// Canonical post-hoc transcription of a completed recording.
    func transcribe(file: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript
}

/// Merges the user's rough notes with the transcript into enhanced notes.
/// Implementations: Apple FoundationModels (v1); local llama.cpp/MLX backends later.
public protocol NoteEnhancer: Sendable {
    var isAvailable: Bool { get }
    func enhance(rawNotes: String, transcript: Transcript) async throws -> String
}
