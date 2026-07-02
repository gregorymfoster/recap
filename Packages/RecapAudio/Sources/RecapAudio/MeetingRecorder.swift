import AVFoundation
import Accelerate
import RecapCore

/// Records a meeting: microphone + (when permitted) system audio, mixed to
/// one mono 48 kHz AAC file, while streaming 16 kHz chunks for transcription
/// and RMS levels for the recording pill.
@MainActor
public final class MeetingRecorder {
    public struct Output {
        public let chunks: AsyncStream<AudioChunk>
        public let levels: AsyncStream<Float>
    }

    private let mic = MicSource()
    private var systemTap: SystemAudioTap?
    private var engine: MixerEngine?
    private var pumpTasks: [Task<Void, Never>] = []
    private var startedAt: Date?

    /// False when the system-audio tap couldn't start (permission denied or
    /// hardware trouble) and the recording is mic-only.
    public private(set) var systemAudioActive = false

    public init() {}

    public static func requestMicPermission() async -> Bool {
        await MicSource.requestPermission()
    }

    public func start(writingTo url: URL, includeSystemAudio: Bool = true) throws -> Output {
        // System audio first, so its stream is live before the mic starts
        // filling the mix buffer's other side.
        var systemStream: AsyncStream<[Float]>?
        if includeSystemAudio {
            let tap = SystemAudioTap()
            do {
                systemStream = try tap.start()
                systemTap = tap
                systemAudioActive = true
            } catch {
                // Permission denied or tap failure → mic-only recording.
                systemAudioActive = false
            }
        }

        let (chunks, chunkContinuation) = AsyncStream.makeStream(of: AudioChunk.self)
        let (levels, levelContinuation) = AsyncStream.makeStream(of: Float.self)
        let engine: MixerEngine
        do {
            engine = try MixerEngine(
                url: url, systemActive: systemAudioActive,
                chunks: chunkContinuation, levels: levelContinuation
            )
        } catch {
            systemTap?.stop()
            systemTap = nil
            systemAudioActive = false
            throw error
        }
        self.engine = engine

        if let systemStream {
            pumpTasks.append(Task.detached(priority: .userInitiated) {
                for await samples in systemStream {
                    await engine.pushSystem(samples)
                }
            })
        }

        do {
            let micStream = try mic.start()
            pumpTasks.append(Task.detached(priority: .userInitiated) {
                for await samples in micStream {
                    await engine.pushMic(samples)
                }
            })
        } catch {
            systemTap?.stop()
            systemTap = nil
            systemAudioActive = false
            for task in pumpTasks {
                task.cancel()
            }
            pumpTasks = []
            throw error
        }

        startedAt = .now
        return Output(chunks: chunks, levels: levels)
    }

    @discardableResult
    public func stop() async -> TimeInterval {
        mic.stop()
        systemTap?.stop()
        systemTap = nil
        systemAudioActive = false
        for task in pumpTasks {
            task.cancel()
        }
        pumpTasks = []
        await engine?.finish()
        engine = nil
        defer { startedAt = nil }
        return startedAt.map { Date.now.timeIntervalSince($0) } ?? 0
    }
}

/// Owns the mix buffer and the output file. All mixing, encoding, and
/// downstream fan-out happens on this actor, off the capture queues.
private actor MixerEngine {
    private var buffer = MixBuffer()
    private var file: AVAudioFile?
    private let writeFormat: AVAudioFormat
    private let chunks: AsyncStream<AudioChunk>.Continuation
    private let levels: AsyncStream<Float>.Continuation
    /// 0–2 samples carried between blocks so 3:1 decimation never drops audio.
    private var downsampleCarry: [Float] = []
    private var chunkPosition: TimeInterval = 0

    init(
        url: URL,
        systemActive: Bool,
        chunks: AsyncStream<AudioChunk>.Continuation,
        levels: AsyncStream<Float>.Continuation
    ) throws {
        buffer.systemActive = systemActive
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: AudioPipeline.mixerSampleRate,
                channels: 1, interleaved: false
            )
        else { throw MicSource.MicError.formatUnsupported }
        writeFormat = format
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: AudioPipeline.mixerSampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        file = try AVAudioFile(
            forWriting: url, settings: settings,
            commonFormat: .pcmFormatFloat32, interleaved: false
        )
        self.chunks = chunks
        self.levels = levels
    }

    func pushMic(_ samples: [Float]) {
        emit(buffer.pushMic(samples))
    }

    func pushSystem(_ samples: [Float]) {
        emit(buffer.pushSystem(samples))
    }

    /// Drains the tail, closes the file, and ends the output streams.
    func finish() {
        emit(buffer.flushRemainder())
        file = nil
        chunks.finish()
        levels.finish()
    }

    private func emit(_ mixed: [Float]) {
        guard !mixed.isEmpty else { return }

        if let file, let pcm = pcmBuffer(from: mixed) {
            try? file.write(from: pcm)
        }

        var rms: Float = 0
        vDSP_rmsqv(mixed, 1, &rms, vDSP_Length(mixed.count))
        levels.yield(rms)

        let input = downsampleCarry + mixed
        let usable = input.count - input.count % 3
        downsampleCarry = Array(input[usable...])
        let samples16k = Downsampler3x.downsample(Array(input[..<usable]))
        if !samples16k.isEmpty {
            let chunk = AudioChunk(samples: samples16k, sampleRate: 16_000, start: chunkPosition)
            chunkPosition += chunk.duration
            chunks.yield(chunk)
        }
    }

    private func pcmBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard
            let pcm = AVAudioPCMBuffer(
                pcmFormat: writeFormat, frameCapacity: AVAudioFrameCount(samples.count)
            ),
            let channel = pcm.floatChannelData
        else { return nil }
        pcm.frameLength = AVAudioFrameCount(samples.count)
        channel[0].update(from: samples, count: samples.count)
        return pcm
    }
}
