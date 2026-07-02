import FluidAudio
import Foundation

/// Labels who spoke when in a finished recording, using FluidAudio's offline
/// CoreML pipeline (pyannote segmentation → WeSpeaker embeddings → VBx
/// clustering) on the mixed mono file.
///
/// Two model bundles (~50 MB total) are fetched from Hugging Face on first
/// use and cached under the app's models directory, so labeling silently
/// starts working once the Mac has been online at least once. Callers should
/// treat failures as "no labels", never as a failed transcript.
public actor SpeakerDiarizer {
    // Confined to this actor; the manager itself is not Sendable (it holds
    // CoreML models that are read-only after initialization).
    nonisolated(unsafe) private let manager = OfflineDiarizerManager()
    private let modelsDirectory: URL
    private var prepared = false

    public static var defaultModelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recap/Models/Diarization")
    }

    public init(modelsDirectory: URL = SpeakerDiarizer.defaultModelsDirectory) {
        self.modelsDirectory = modelsDirectory
    }

    /// Diarizes the audio file and returns speaker turns ordered by start
    /// time. Progress covers diarization only (0...1).
    public func speakerTurns(
        in file: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [SpeakerTurn] {
        if !prepared {
            try await manager.prepareModels(directory: modelsDirectory)
            prepared = true
        }
        let result = try await manager.process(file) { done, total in
            guard total > 0 else { return }
            progress?(Double(done) / Double(total))
        }
        return result.segments
            .map {
                SpeakerTurn(
                    speakerID: $0.speakerId,
                    start: TimeInterval($0.startTimeSeconds),
                    end: TimeInterval($0.endTimeSeconds)
                )
            }
            .sorted { $0.start < $1.start }
    }
}
