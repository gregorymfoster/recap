import AVFoundation
import Accelerate
import RecapCore

/// Mid-recording conditions the UI should know about.
public enum RecorderEvent: Equatable, Sendable {
    /// The mic capture graph was rebuilt (device switch, wake from sleep).
    /// Recording continues; there may be a small gap.
    case inputRebuilt(reason: String)
    /// Audio can no longer be written to disk (disk full, I/O error).
    /// The recording should be stopped and salvaged.
    case writeFailed
}

/// Records a meeting: microphone + (when permitted) system audio, mixed to
/// one mono 48 kHz stream, while streaming 16 kHz chunks for transcription
/// and RMS levels for the recording pill.
///
/// Two files are written in parallel: the canonical AAC m4a, and an LPCM CAF
/// spool that stays readable even if the process dies mid-write (an m4a
/// without its closing moov atom is unrecoverable). A clean stop deletes the
/// spool; a crash leaves it for `AudioTranscoder.salvageSpool` at relaunch.
@MainActor
public final class MeetingRecorder {
    public struct Output {
        public let chunks: AsyncStream<AudioChunk>
        public let levels: AsyncStream<Float>
        public let events: AsyncStream<RecorderEvent>
    }

    public enum RecorderError: Error {
        case diskFull
    }

    /// Refuse to start with less than this much free space — a meeting can
    /// easily need a few hundred MB of spool plus models and transcripts.
    private static let minimumFreeBytes: Int64 = 1_000_000_000

    private let mic = MicSource()
    private var systemTap: SystemAudioTap?
    private var engine: MixerEngine?
    private var pumpTasks: [Task<Void, Never>] = []

    /// Active-time bookkeeping for the current recording; nil while stopped.
    /// `stop()` returns its elapsed active time, so paused stretches never
    /// count toward the meeting duration.
    public private(set) var clock: RecordingClock?

    public var isPaused: Bool { clock?.isPaused ?? false }

    /// False when the system-audio tap couldn't start (permission denied or
    /// hardware trouble) and the recording is mic-only.
    public private(set) var systemAudioActive = false

    /// The mic device actually in use, for display (nil while not recording,
    /// or when it couldn't be determined).
    public var activeInputDeviceName: String? { mic.activeDeviceName }

    public init() {}

    public static func requestMicPermission() async -> Bool {
        await MicSource.requestPermission()
    }

    /// Switches the input device mid-recording (or before starting). Goes
    /// through `MicSource`'s existing debounced rebuild path, so the output
    /// file keeps writing across the switch. `nil` means system default.
    public func setPreferredInputUID(_ uid: String?) {
        mic.preferredInputUID = uid
    }

    public func start(
        writingTo url: URL, includeSystemAudio: Bool = true, preferredInputUID: String? = nil
    ) throws -> Output {
        let folder = url.deletingLastPathComponent()
        if let free = try? folder.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage, free < Self.minimumFreeBytes {
            throw RecorderError.diskFull
        }
        mic.preferredInputUID = preferredInputUID

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
        let (events, eventContinuation) = AsyncStream.makeStream(of: RecorderEvent.self)
        let engine: MixerEngine
        do {
            engine = try MixerEngine(
                url: url, systemActive: systemAudioActive,
                chunks: chunkContinuation, levels: levelContinuation, events: eventContinuation
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
            mic.onRebuild = { reason in
                eventContinuation.yield(.inputRebuilt(reason: reason))
            }
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

        clock = RecordingClock(startedAt: .now)
        return Output(chunks: chunks, levels: levels, events: events)
    }

    /// Gates capture at the mixer — both engines keep running (tearing them
    /// down would re-enter the tap-permission and mic-rebuild paths), but no
    /// samples reach the files or the streaming pass, so paused seconds
    /// simply don't exist in the output. Awaits the mixer hop so the UI's
    /// paused state and the sample gate can never disagree.
    public func pause() async {
        guard let engine, var clock, !clock.isPaused else { return }
        await engine.setPaused(true)
        clock.pause(at: .now)
        self.clock = clock
    }

    public func resume() async {
        guard let engine, var clock, clock.isPaused else { return }
        await engine.setPaused(false)
        clock.resume(at: .now)
        self.clock = clock
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
        defer { clock = nil }
        return clock?.elapsed(at: .now) ?? 0
    }
}

/// Owns the mix buffer and the output files. All mixing, encoding, and
/// downstream fan-out happens on this actor, off the capture queues.
private actor MixerEngine {
    private var buffer = MixBuffer()
    private var file: AVAudioFile?
    private var spool: AVAudioFile?
    private let fileURL: URL
    private let spoolURL: URL
    private let writeFormat: AVAudioFormat
    private let chunks: AsyncStream<AudioChunk>.Continuation
    private let levels: AsyncStream<Float>.Continuation
    private let events: AsyncStream<RecorderEvent>.Continuation
    private var fileWriteFailures = 0
    private var spoolWriteFailures = 0
    private var reportedWriteFailure = false
    /// 0–2 samples carried between blocks so 3:1 decimation never drops audio.
    private var downsampleCarry: [Float] = []
    private var chunkPosition: TimeInterval = 0
    /// While true, incoming samples are dropped at the gate — nothing reaches
    /// the files, the level stream, or the 16 kHz chunk stream. `chunkPosition`
    /// keeps counting active time only, so live timestamps stay file-aligned.
    private var paused = false

    /// A handful of consecutive failures means the disk is genuinely stuck,
    /// not a transient hiccup.
    private static let failureThreshold = 5

    init(
        url: URL,
        systemActive: Bool,
        chunks: AsyncStream<AudioChunk>.Continuation,
        levels: AsyncStream<Float>.Continuation,
        events: AsyncStream<RecorderEvent>.Continuation
    ) throws {
        buffer.systemActive = systemActive
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: AudioPipeline.mixerSampleRate,
                channels: 1, interleaved: false
            )
        else { throw MicSource.MicError.formatUnsupported }
        writeFormat = format
        fileURL = url
        spoolURL = url.deletingPathExtension().appendingPathExtension("caf")
        let aacSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: AudioPipeline.mixerSampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        file = try AVAudioFile(
            forWriting: url, settings: aacSettings,
            commonFormat: .pcmFormatFloat32, interleaved: false
        )
        // Int16 LPCM: half the size of Float32, still lossless for speech.
        let spoolSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioPipeline.mixerSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        // The spool is best-effort: if it can't be created the recording
        // still runs, just without crash protection.
        spool = try? AVAudioFile(
            forWriting: spoolURL, settings: spoolSettings,
            commonFormat: .pcmFormatFloat32, interleaved: false
        )
        self.chunks = chunks
        self.levels = levels
        self.events = events
    }

    func pushMic(_ samples: [Float]) {
        guard !paused else { return }
        emit(buffer.pushMic(samples))
    }

    func pushSystem(_ samples: [Float]) {
        guard !paused else { return }
        emit(buffer.pushSystem(samples))
    }

    /// Opens/closes the sample gate. On pausing, the unpaired mic/system tail
    /// is written first (mirroring `finish()`) rather than stitched across
    /// the gap, and the decimation carry is reset so the pause boundary is
    /// clean. `finish()` while paused stays legal — the buffer is empty, so
    /// its flush is a no-op.
    func setPaused(_ value: Bool) {
        guard value != paused else { return }
        if value {
            emit(buffer.flushRemainder())
            downsampleCarry = []
        }
        paused = value
    }

    /// Drains the tail, closes the files, and ends the output streams.
    /// If the m4a writer had failed, the spool is transcoded to replace it;
    /// otherwise the spool is deleted.
    func finish() {
        emit(buffer.flushRemainder())
        file = nil
        spool = nil
        if fileWriteFailures >= Self.failureThreshold || (try? AVAudioFile(forReading: fileURL)) == nil {
            AudioTranscoder.salvageSpool(caf: spoolURL, m4a: fileURL)
        } else {
            try? FileManager.default.removeItem(at: spoolURL)
        }
        chunks.finish()
        levels.finish()
        events.finish()
    }

    private func emit(_ mixed: [Float]) {
        guard !mixed.isEmpty else { return }

        if let pcm = pcmBuffer(from: mixed) {
            if let file {
                do {
                    try file.write(from: pcm)
                    fileWriteFailures = 0
                } catch {
                    fileWriteFailures += 1
                }
            }
            if let spool {
                do {
                    try spool.write(from: pcm)
                    spoolWriteFailures = 0
                } catch {
                    spoolWriteFailures += 1
                    if spoolWriteFailures >= Self.failureThreshold {
                        // Give up on the spool; the m4a may still be healthy.
                        self.spool = nil
                    }
                }
            }
            // Only unrecoverable when both writers are failing.
            if !reportedWriteFailure,
               fileWriteFailures >= Self.failureThreshold,
               spool == nil || spoolWriteFailures >= Self.failureThreshold {
                reportedWriteFailure = true
                events.yield(.writeFailed)
            }
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
