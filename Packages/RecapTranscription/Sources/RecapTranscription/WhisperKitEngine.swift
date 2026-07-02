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

    /// Live transcription during recording: rolling-buffer passes every ~4 s,
    /// confirming all but the trailing segment (see `StreamingPass`). Results
    /// are provisional UX — the file pass after stop is canonical.
    public func transcribe(stream: AsyncStream<RecapCore.AudioChunk>) -> AsyncStream<TranscriptionUpdate> {
        let (updates, continuation) = AsyncStream.makeStream(of: TranscriptionUpdate.self)
        let engine = self
        let task = Task(priority: .utility) {
            await engine.runStreaming(stream: stream, into: continuation)
            continuation.finish()
        }
        continuation.onTermination = { @Sendable _ in
            task.cancel()
        }
        return updates
    }

    private func runStreaming(
        stream: AsyncStream<RecapCore.AudioChunk>,
        into continuation: AsyncStream<TranscriptionUpdate>.Continuation
    ) async {
        let sampleRate = 16_000.0
        let passStride = Int(4 * sampleRate)  // new audio between passes
        let maxBuffer = Int(30 * sampleRate)  // Whisper's window
        let silenceRMS: Float = 0.005

        continuation.yield(.status(.loadingModel))
        let config = WhisperKitConfig(
            modelFolder: modelFolder.path, verbose: false, load: true, download: false
        )
        let pipe: WhisperKit
        do {
            pipe = try await WhisperKit(config)
        } catch {
            continuation.yield(.status(.failed(reason: "Couldn't load \(modelName)")))
            return
        }
        guard !Task.isCancelled else { return }
        continuation.yield(.status(.live))

        var buffer: [Float] = []
        var bufferStart: TimeInterval = 0
        var newSamples = 0

        func runPass(final: Bool) async {
            // Skip silent windows entirely (VAD gate).
            let rms = sqrt(buffer.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(1, buffer.count)))
            guard rms >= silenceRMS else {
                if buffer.count > maxBuffer {
                    let drop = buffer.count - maxBuffer
                    buffer.removeFirst(drop)
                    bufferStart += Double(drop) / sampleRate
                }
                return
            }
            var options = DecodingOptions()
            options.task = .transcribe
            options.skipSpecialTokens = true
            guard let results = try? await pipe.transcribe(audioArray: buffer, decodeOptions: options)
            else { return }
            let segments = results.flatMap(\.segments).map {
                StreamingPass.Segment(
                    start: TimeInterval($0.start), end: TimeInterval($0.end), text: $0.text
                )
            }
            let outcome = StreamingPass.process(
                segments: segments,
                bufferStart: bufferStart,
                bufferSampleCount: buffer.count,
                sampleRate: sampleRate
            )
            for utterance in outcome.confirmed {
                continuation.yield(.confirmed(utterance))
            }
            if let partial = outcome.partial {
                if final {
                    continuation.yield(.confirmed(partial))
                    buffer = []
                } else {
                    continuation.yield(.partial(partial))
                    buffer.removeFirst(outcome.trimSamples)
                    bufferStart += Double(outcome.trimSamples) / sampleRate
                }
            }
        }

        for await chunk in stream {
            guard !Task.isCancelled else { return }
            buffer.append(contentsOf: chunk.samples)
            newSamples += chunk.samples.count
            guard newSamples >= passStride else { continue }
            newSamples = 0
            await runPass(final: false)
        }
        await runPass(final: true)
    }
}
