import Foundation

/// Synthetic capture sources that drive `MeetingRecorder` with silence
/// instead of real hardware — no microphone, no `SystemAudioTap`, no TCC
/// prompts. These exist ONLY to power the `-soak` launch-argument soak test
/// (see `Scripts/soak-test.sh`), which needs the real recording pipeline
/// running (mixer, writer, clock, menu bar) without touching hardware or a
/// transcription engine. Never used in normal operation.
private let syntheticBufferSampleCount = 480
private let syntheticBufferInterval: Duration = .milliseconds(20)

/// Synthetic `MicCapturing` conformer: yields zero-filled buffers on a timer
/// until stopped.
@MainActor
public final class SyntheticMicSource: MicCapturing {
    public var preferredInputUID: String?
    public var onRebuild: (@MainActor (String) -> Void)?
    public var activeDeviceName: String? { "Synthetic (soak)" }

    private var pumpTask: Task<Void, Never>?
    private var continuation: AsyncStream<[Float]>.Continuation?

    public init() {}

    public func start() throws -> AsyncStream<[Float]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [Float].self)
        self.continuation = continuation
        pumpTask = Task { [continuation] in
            let silence = [Float](repeating: 0, count: syntheticBufferSampleCount)
            while !Task.isCancelled {
                continuation.yield(silence)
                try? await Task.sleep(for: syntheticBufferInterval)
            }
            continuation.finish()
        }
        return stream
    }

    public func stop() {
        pumpTask?.cancel()
        pumpTask = nil
        continuation?.finish()
        continuation = nil
    }

    /// No-op: the synthetic soak source never actually goes silent (it's a
    /// timer pumping zero-filled buffers), so there's nothing to recover.
    public func forceRebuild() {}
}

/// Synthetic `SystemAudioCapturing` conformer: yields zero-filled buffers on
/// a timer until stopped.
@MainActor
public final class SyntheticSystemAudioSource: SystemAudioCapturing {
    private var pumpTask: Task<Void, Never>?
    private var continuation: AsyncStream<[Float]>.Continuation?

    public init() {}

    public func start() async throws -> AsyncStream<[Float]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [Float].self)
        self.continuation = continuation
        pumpTask = Task { [continuation] in
            let silence = [Float](repeating: 0, count: syntheticBufferSampleCount)
            while !Task.isCancelled {
                continuation.yield(silence)
                try? await Task.sleep(for: syntheticBufferInterval)
            }
            continuation.finish()
        }
        return stream
    }

    public func stop() {
        pumpTask?.cancel()
        pumpTask = nil
        continuation?.finish()
        continuation = nil
    }

    /// No-op: the synthetic soak source's timer pump never dies, so there is
    /// no graph to rebuild.
    public func rebuild() async {}
}
