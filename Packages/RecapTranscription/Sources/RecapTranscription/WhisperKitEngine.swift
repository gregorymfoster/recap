import Foundation
import RecapCore
import WhisperKit

/// WhisperKit-backed implementation of `TranscriptionEngine`.
///
/// The file path is the canonical one: the saved recording is re-transcribed
/// in full after the meeting ends. A pipeline instance is created per call —
/// the processing queue runs one job at a time, and keeping the model
/// unloaded between jobs keeps idle memory near zero.
public struct WhisperKitEngine: TranscriptionEngine {
    public let modelFolder: URL
    public let modelName: String

    public init(modelFolder: URL, modelName: String) {
        self.modelFolder = modelFolder
        self.modelName = modelName
    }

    public func transcribe(
        file: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Transcript {
        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            verbose: false,
            load: true,
            download: false
        )
        let pipe = try await WhisperKit(config)

        // Progress is thread-safe (NSProgress); polled off the transcribe task.
        let pipeProgress = pipe.progress
        let poller = Task {
            while !Task.isCancelled {
                progress(pipeProgress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        defer {
            poller.cancel()
            progress(1)
        }

        var options = DecodingOptions()
        options.task = .transcribe
        options.skipSpecialTokens = true
        let results = try await pipe.transcribe(audioPath: file.path, decodeOptions: options)

        let utterances = results
            .flatMap(\.segments)
            .map { segment in
                Utterance(
                    start: TimeInterval(segment.start),
                    end: TimeInterval(segment.end),
                    text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            .filter { !$0.text.isEmpty }
        return Transcript(
            utterances: utterances,
            engine: "whisperkit",
            model: modelName,
            language: results.first?.language ?? "en"
        )
    }

    /// Live streaming transcription lands in M7; the live pane is provisional
    /// UX only, so until then recordings simply transcribe after stop.
    public func transcribe(stream: AsyncStream<RecapCore.AudioChunk>) -> AsyncStream<TranscriptionUpdate> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}
