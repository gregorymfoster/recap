import AVFoundation
import RecapCore

/// Shared buffer→[Float] conversion used by both capture sources.
/// Runs on capture queues; touches only objects owned by its caller.
enum BufferConversion {
    static func convert(
        _ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to format: AVAudioFormat
    ) -> [Float]? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var fed = false
        // The converter's @Sendable input block runs synchronously inside
        // convert(to:) on this thread; the buffer never actually crosses.
        nonisolated(unsafe) let input = buffer
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, out.frameLength > 0, let data = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }
}

/// Microphone capture: AVAudioEngine input tap converted to 48 kHz mono
/// Float32 blocks for the mixer.
@MainActor
public final class MicSource {
    public enum MicError: Error {
        case permissionDenied
        case formatUnsupported
    }

    private let engine = AVAudioEngine()

    public init() {}

    public static func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }

    public func start() throws -> AsyncStream<[Float]> {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard
            format.sampleRate > 0,
            let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: AudioPipeline.mixerSampleRate,
                channels: 1, interleaved: false
            ),
            let converter = AVAudioConverter(from: format, to: monoFormat)
        else { throw MicError.formatUnsupported }

        let (stream, continuation) = AsyncStream.makeStream(of: [Float].self)
        // @Sendable keeps the tap block nonisolated — it runs on the engine's
        // capture queue, never the main actor. The converter is used only on
        // that one serial queue.
        nonisolated(unsafe) let tapConverter = converter
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { @Sendable buffer, _ in
            if let samples = BufferConversion.convert(buffer, using: tapConverter, to: monoFormat) {
                continuation.yield(samples)
            }
        }
        try engine.start()
        return stream
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
