import AVFoundation
import Accelerate
import RecapCore

/// Records the default input device to an AAC file while streaming
/// 16 kHz mono chunks (for transcription) and RMS levels (for the
/// recording pill's waveform).
///
/// Lifecycle is main-actor; the tap callback runs on AVAudioEngine's
/// internal capture queue and touches only objects it owns.
@MainActor
public final class MicRecorder {
    public struct Output {
        public let chunks: AsyncStream<AudioChunk>
        public let levels: AsyncStream<Float>
    }

    public enum RecorderError: Error {
        case permissionDenied
        case formatUnsupported
    }

    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var startedAt: Date?

    public init() {}

    public static func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }

    public func start(writingTo url: URL) throws -> Output {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw RecorderError.formatUnsupported }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let file = try AVAudioFile(
            forWriting: url, settings: settings,
            commonFormat: .pcmFormatFloat32, interleaved: false
        )
        self.file = file

        guard
            let whisperFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
            ),
            let converter = AVAudioConverter(from: format, to: whisperFormat)
        else { throw RecorderError.formatUnsupported }

        let (chunks, chunkContinuation) = AsyncStream.makeStream(of: AudioChunk.self)
        let (levels, levelContinuation) = AsyncStream.makeStream(of: Float.self)

        nonisolated(unsafe) var position: TimeInterval = 0  // touched only on the serial tap queue
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            try? file.write(from: buffer)
            levelContinuation.yield(Self.rms(of: buffer))
            if let samples = Self.convert(buffer, using: converter, to: whisperFormat) {
                let chunk = AudioChunk(samples: samples, sampleRate: 16_000, start: position)
                position += chunk.duration
                chunkContinuation.yield(chunk)
            }
        }

        try engine.start()
        startedAt = .now
        return Output(chunks: chunks, levels: levels)
    }

    /// Stops capture, closes the file, and returns the recorded duration.
    @discardableResult
    public func stop() -> TimeInterval {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
        defer { startedAt = nil }
        return startedAt.map { Date.now.timeIntervalSince($0) } ?? 0
    }

    // MARK: DSP helpers (run on the tap queue)

    private nonisolated static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        var value: Float = 0
        vDSP_rmsqv(data[0], 1, &value, vDSP_Length(buffer.frameLength))
        return value
    }

    private nonisolated static func convert(
        _ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to format: AVAudioFormat
    ) -> [Float]? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let data = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }
}
