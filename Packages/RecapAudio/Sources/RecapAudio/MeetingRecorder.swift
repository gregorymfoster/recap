import AVFoundation
import Accelerate
import RecapCore
import os

private let recorderLog = Logger(subsystem: "com.gregfoster.recap", category: "MeetingRecorder")

/// Outcome of `MeetingRecorder.probeSystemAudio()`.
public enum SystemAudioProbeResult: Sendable, Equatable {
    /// The tap started successfully — permission works.
    case captured
    /// Tap creation failed — almost certainly a TCC denial.
    case denied
    /// Some other failure (aggregate device, IO, or format setup).
    case failed(String)

    /// Maps a thrown error from `SystemAudioTap.start()` to a probe result.
    /// Pure and exhaustive over `SystemAudioTap.TapError`; anything else
    /// (shouldn't happen in practice) falls back to `.failed`.
    init(mappingError error: Error) {
        guard let tapError = error as? SystemAudioTap.TapError else {
            self = .failed(String(describing: error))
            return
        }
        switch tapError {
        case .tapCreationFailed:
            self = .denied
        case .aggregateCreationFailed(let status):
            self = .failed("aggregateCreationFailed(\(status))")
        case .ioSetupFailed(let status):
            self = .failed("ioSetupFailed(\(status))")
        case .formatUnsupported:
            self = .failed("formatUnsupported")
        }
    }
}

/// Mid-recording conditions the UI should know about.
public enum RecorderEvent: Equatable, Sendable {
    /// The mic capture graph was rebuilt (device switch, wake from sleep).
    /// Recording continues; there may be a small gap.
    case inputRebuilt(reason: String)
    /// Audio can no longer be written to disk (disk full, I/O error).
    /// The recording should be stopped and salvaged.
    case writeFailed
    /// System audio started successfully but has gone silent mid-recording
    /// (e.g. an output-device/route change or a sleep cycle breaks the
    /// aggregate device's tap link) — the mic side is still being captured,
    /// but the other call participant(s) are no longer being recorded. By
    /// the time this fires, `MeetingRecorder` has already made up to two
    /// bounded attempts to recover the tap via
    /// `SystemAudioCapturing.rebuild()`; this only reaches the UI once those
    /// attempts didn't bring samples back. Fires at most once per recording.
    /// The recording is NOT stopped; this is a warning, not a failure —
    /// mirrors `.writeFailed`'s one-shot semantics without the auto-stop
    /// behavior.
    case systemAudioStalled
    /// The mic went silent mid-recording (e.g. a USB device unplugged with
    /// no fallback) while system audio (when active) kept flowing — the
    /// mirror image of `.systemAudioStalled`. By the time this fires,
    /// `MeetingRecorder` has already made up to two bounded attempts to
    /// recover the mic via `MicCapturing.forceRebuild()`; this only reaches
    /// the UI once those attempts didn't bring samples back. The recording
    /// is NOT stopped — system audio (if active) keeps being captured.
    case micStalled
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
        /// Neither the mic nor system audio is available (mic denied and
        /// system-audio capture off or unavailable) — nothing to record.
        case noAudioSource
        /// A `start()` call arrived while a previous one was still
        /// suspended (e.g. awaiting the system-audio TCC prompt).
        case alreadyStarting
        /// `stop()` was called while `start()` was still suspended (e.g.
        /// awaiting the system-audio TCC prompt or `mic.start()`). `start()`
        /// noticed the pending stop once it resumed, tore down everything it
        /// had built, and threw this instead of returning a live `Output` —
        /// there is nothing to observe from the cancelled recording.
        case startCancelled
    }

    /// Refuse to start with less than this much free space — a meeting can
    /// easily need a few hundred MB of spool plus models and transcripts.
    private static let minimumFreeBytes: Int64 = 1_000_000_000

    private let mic: MicCapturing
    private let makeSystemTap: @MainActor () -> SystemAudioCapturing
    private var systemTap: SystemAudioCapturing?
    private var engine: MixerEngine?
    private var pumpTasks: [Task<Void, Never>] = []

    /// Test-only seam: when set, `start()` hands these to `MixerEngine`
    /// instead of the default `AVAudioFile`-backed writers, so tests can
    /// prove a writer that throws still trips `.writeFailed` through the
    /// write path's moved failure counters. Never set in production.
    var testFileWriterOverride: (any AudioFileWriting)?
    var testSpoolWriterOverride: (any AudioFileWriting)?

    /// Active-time bookkeeping for the current recording; nil while stopped.
    /// `stop()` returns its elapsed active time, so paused stretches never
    /// count toward the meeting duration.
    public private(set) var clock: RecordingClock?

    public var isPaused: Bool { clock?.isPaused ?? false }

    /// False when the system-audio tap couldn't start (permission denied or
    /// hardware trouble) and the recording is mic-only.
    public private(set) var systemAudioActive = false

    /// False when the mic wasn't captured (access denied) and the recording
    /// is system-audio-only. Mirror image of `systemAudioActive`.
    public private(set) var micActive = false

    /// The mic device actually in use, for display (nil while not recording,
    /// or when it couldn't be determined).
    public var activeInputDeviceName: String? { mic.activeDeviceName }

    /// Independent per-source sample totals, for diagnostics (`capture-probe`)
    /// that need to tell "mic captured, system captured nothing" apart from
    /// "both captured the same mixed total" — the two sides are otherwise
    /// only ever seen already-mixed downstream.
    public struct SampleCounts: Sendable, Equatable {
        public let mic: Int
        public let system: Int
    }

    /// Sample counts as of the last call — live while recording (reads the
    /// mixer actor's running totals) and frozen at their final values after
    /// `stop()` (the engine is gone by then, so the last snapshot is cached).
    private var lastSampleCounts = SampleCounts(mic: 0, system: 0)

    /// Current per-source sample totals. While recording this hops to the
    /// mixer actor for a live read; after `stop()` it returns the final
    /// snapshot captured just before the engine was torn down.
    public func sampleCounts() async -> SampleCounts {
        guard let engine else { return lastSampleCounts }
        let counts = await engine.sampleCounts()
        lastSampleCounts = counts
        return counts
    }

    /// Guards against a second concurrent `start()` call while the first is
    /// still suspended awaiting `tap.start()` (e.g. a user double-triggering
    /// record while the TCC prompt is up). Set for the duration of `start()`.
    private var isStarting = false

    /// Set by `stop()` when it's called while `isStarting` is true — there is
    /// nothing live yet to tear down (the tap/engine are only ever mutated by
    /// `start()` itself, so `stop()` touching them concurrently would race).
    /// `start()` checks this flag once it resumes past its awaits and, if
    /// set, tears down everything it just built instead of returning it.
    private var stopRequestedDuringStart = false

    /// - Parameters:
    ///   - mic: Mic capture source; defaults to the real `MicSource`. Tests
    ///     inject a fake exposing a canned sample stream.
    ///   - makeSystemTap: Factory for the system-audio source, invoked fresh
    ///     each `start()` (mirroring the real tap's per-recording lifecycle);
    ///     defaults to constructing a real `SystemAudioTap`.
    public init(
        mic: MicCapturing? = nil,
        makeSystemTap: (@MainActor () -> SystemAudioCapturing)? = nil
    ) {
        self.mic = mic ?? MicSource()
        self.makeSystemTap = makeSystemTap ?? { SystemAudioTap() }
    }

    public static func requestMicPermission() async -> Bool {
        await MicSource.requestPermission()
    }

    /// Briefly starts a real system-audio tap to verify (or trigger the
    /// macOS prompt for) the System Audio Recording permission, then tears
    /// it down. No samples are read or written anywhere.
    ///
    /// There is no query/request API for this TCC permission — the tap
    /// creation call itself is the only way to learn the status or (when
    /// notDetermined) surface the system prompt. Because that prompt is
    /// asynchronous, a first denial is retried once after a short delay to
    /// give the user a chance to click "Allow".
    public static func probeSystemAudio() async -> SystemAudioProbeResult {
        await probeSystemAudio(
            makeTap: { SystemAudioTap() },
            sleep: { try? await Task.sleep(for: .seconds(2)) }
        )
    }

    /// Testable core of `probeSystemAudio()`: tap construction and the
    /// retry delay are injected so the outcome mapping and one-retry
    /// behavior can be exercised with a fake tap, without touching real
    /// Core Audio or waiting on a real timer.
    static func probeSystemAudio(
        makeTap: @MainActor () -> SystemAudioCapturing,
        sleep: () async -> Void
    ) async -> SystemAudioProbeResult {
        var result = await attemptSystemAudioProbe(makeTap: makeTap)
        if result == .denied {
            await sleep()
            result = await attemptSystemAudioProbe(makeTap: makeTap)
        }
        recorderLog.info("system audio probe: \(String(describing: result), privacy: .public)")
        return result
    }

    /// One attempt: start a fresh tap and immediately stop it, discarding
    /// any stream. Runs on the main actor because `SystemAudioTap` is;
    /// `tap.start()` itself now suspends off the main actor internally so
    /// the TCC prompt it may trigger never blocks the UI.
    @MainActor
    private static func attemptSystemAudioProbe(
        makeTap: @MainActor () -> SystemAudioCapturing
    ) async -> SystemAudioProbeResult {
        let tap = makeTap()
        do {
            _ = try await tap.start()
            tap.stop()
            return .captured
        } catch {
            tap.stop()
            return SystemAudioProbeResult(mappingError: error)
        }
    }

    /// Switches the input device mid-recording (or before starting). Goes
    /// through `MicSource`'s existing debounced rebuild path, so the output
    /// file keeps writing across the switch. `nil` means system default.
    public func setPreferredInputUID(_ uid: String?) {
        mic.preferredInputUID = uid
    }

    public func start(
        writingTo url: URL, includeSystemAudio: Bool = true, includeMic: Bool = true,
        preferredInputUID: String? = nil
    ) async throws -> Output {
        // A second start() while the first is still suspended (e.g. awaiting
        // the system-audio TCC prompt) would race on `systemTap`/`engine`
        // state below — refuse it rather than corrupting that state.
        guard !isStarting else {
            throw RecorderError.alreadyStarting
        }
        isStarting = true
        stopRequestedDuringStart = false
        defer { isStarting = false }

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
            let tap = makeSystemTap()
            do {
                systemStream = try await tap.start()
                systemTap = tap
                systemAudioActive = true
            } catch {
                // Permission denied or tap failure → mic-only recording.
                systemAudioActive = false
            }
        }

        // Nothing to capture — mic is off (denied) and system audio isn't
        // available either. Bail before opening files so the caller can
        // surface the permission problem instead of recording silence.
        guard includeMic || systemAudioActive else {
            systemTap?.stop()
            systemTap = nil
            systemAudioActive = false
            throw RecorderError.noAudioSource
        }

        let (chunks, chunkContinuation) = AsyncStream.makeStream(of: AudioChunk.self)
        let (levels, levelContinuation) = AsyncStream.makeStream(of: Float.self)
        let (events, eventContinuation) = AsyncStream.makeStream(of: RecorderEvent.self)
        let engine: MixerEngine
        do {
            engine = try MixerEngine(
                url: url, systemActive: systemAudioActive, micActive: includeMic,
                chunks: chunkContinuation, levels: levelContinuation, events: eventContinuation,
                attemptMicRecovery: { [weak self] in
                    self?.mic.forceRebuild()
                },
                attemptSystemRecovery: { [weak self] in
                    await self?.systemTap?.rebuild()
                },
                fileWriterOverride: testFileWriterOverride,
                spoolWriterOverride: testSpoolWriterOverride
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

        // Mic access denied → skip capture entirely and record system audio
        // alone. The mixer already passes system samples straight through
        // (micActive == false), so no mic counterpart is ever awaited.
        if includeMic {
            do {
                mic.onRebuild = { reason in
                    eventContinuation.yield(.inputRebuilt(reason: reason))
                }
                let micStream = try mic.start()
                micActive = true
                pumpTasks.append(Task.detached(priority: .userInitiated) {
                    for await samples in micStream {
                        await engine.pushMic(samples)
                    }
                })
            } catch {
                systemTap?.stop()
                systemTap = nil
                systemAudioActive = false
                micActive = false
                for task in pumpTasks {
                    task.cancel()
                }
                pumpTasks = []
                // The engine was already built (and its files opened) before
                // the mic failed to start — finish/nil it too, or the open
                // m4a/CAF handles leak and a zero-byte pair is left on disk.
                await engine.finish()
                self.engine = nil
                throw error
            }
        } else {
            micActive = false
        }

        // A stop() that arrived while we were suspended above (e.g. awaiting
        // the system-audio TCC prompt or `mic.start()`) couldn't tear down a
        // recording that didn't exist yet — do it now, before ever handing
        // back a live `Output` nobody will stop.
        guard !stopRequestedDuringStart else {
            stopRequestedDuringStart = false
            recorderLog.info("start() cancelled: stop() arrived while still starting")
            _ = await teardownActive()
            throw RecorderError.startCancelled
        }

        clock = RecordingClock(startedAt: .now)
        recorderLog.info("started: mic=\(self.micActive, privacy: .public) systemAudio=\(self.systemAudioActive, privacy: .public)")
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
        recorderLog.info("paused")
    }

    public func resume() async {
        guard let engine, var clock, clock.isPaused else { return }
        await engine.setPaused(false)
        clock.resume(at: .now)
        self.clock = clock
        recorderLog.info("resumed")
    }

    @discardableResult
    public func stop() async -> TimeInterval {
        // A start() is still suspended (e.g. awaiting the system-audio TCC
        // prompt or `mic.start()`) — `systemTap`/`engine` may still be nil or
        // only half-built, and start() itself is the only thing safe to
        // mutate them right now. Flag the request; start() checks this once
        // it resumes and tears everything down itself before returning.
        guard !isStarting else {
            stopRequestedDuringStart = true
            recorderLog.info("stop() deferred: a start() is still in flight")
            return 0
        }
        return await teardownActive()
    }

    /// Tears down whatever a (possibly now-cancelled) recording built:
    /// stops the mic/tap, cancels the pump tasks, finishes the mixer engine,
    /// and returns the elapsed active time (0 if nothing was ever recording).
    /// Shared by `stop()` and by `start()`'s own cancellation path.
    private func teardownActive() async -> TimeInterval {
        mic.stop()
        systemTap?.stop()
        systemTap = nil
        systemAudioActive = false
        micActive = false
        for task in pumpTasks {
            task.cancel()
        }
        pumpTasks = []
        if let engine {
            lastSampleCounts = await engine.sampleCounts()
            await engine.finish()
        }
        engine = nil
        defer { clock = nil }
        let duration = clock?.elapsed(at: .now) ?? 0
        recorderLog.info("stopped: duration=\(duration, privacy: .public)")
        return duration
    }
}

/// Owns the mix buffer and the output files. Mixing, RMS, and downsampling
/// happen on this actor; the actual (potentially slow) disk writes run on a
/// single serial background task fed through a small bounded queue, so a
/// stalled disk suspends that task instead of this actor — see
/// `emit(_:)` and `runWriteLoop`.
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

    /// Feeds mixed blocks (raw mono samples, not yet a PCM buffer — building
    /// that happens on the write task itself, since `AVAudioPCMBuffer` isn't
    /// `Sendable`) to the background write task. Bounded to
    /// `writeQueueDepth`; past that, the OLDEST queued block is dropped, same
    /// dropping-newest... dropping-oldest policy as the capture-side streams
    /// (`AudioPipeline.capturedStreamBufferedBlocks`), just much shallower —
    /// this queue is only ever backed up by the disk itself, not a whole
    /// capture pipeline.
    private let writeQueue: AsyncStream<[Float]>.Continuation
    private var writeTask: Task<MixerEngine.WriteOutcome, Never>?
    /// ~700 ms of blocks at the mixer's typical ~85 ms block size.
    private static let writeQueueDepth = 8

    /// Shared between this actor's `emit(_:)` (which observes queue drops)
    /// and the background write task (which observes write duration and
    /// thrown errors) without either side needing to `await` a hop to the
    /// other just to update a strike count.
    private let writeHealth: WriteFailureLatch

    /// 0–2 samples carried between blocks so 3:1 decimation never drops audio.
    private var downsampleCarry: [Float] = []
    private var chunkPosition: TimeInterval = 0
    /// While true, incoming samples are dropped at the gate — nothing reaches
    /// the files, the level stream, or the 16 kHz chunk stream. `chunkPosition`
    /// keeps counting active time only, so live timestamps stay file-aligned.
    private var paused = false

    /// Whether this recording started with system audio active, and whether
    /// the mic was included — only when both sides are expected does the
    /// liveness watchdog below have a heartbeat to measure the other side's
    /// silence against (see `LivenessWatchdog.recordProgress`'s doc comment).
    private let systemActive: Bool
    private let micCaptureActive: Bool
    private var livenessWatchdog = LivenessWatchdog()
    /// Bounded auto-recovery for a stalled side: rebuilds the capture graph
    /// (invoked back on `MeetingRecorder`'s `@MainActor`, since that's where
    /// the sources live) up to `RestartPolicy.attemptsAllowed` times before
    /// giving up and emitting `.micStalled`/`.systemAudioStalled` to the UI.
    private let attemptMicRecovery: @MainActor () async -> Void
    private let attemptSystemRecovery: @MainActor () async -> Void
    private var micRestartPolicy = RestartPolicy()
    private var systemRestartPolicy = RestartPolicy()

    /// A handful of consecutive failures means the disk is genuinely stuck,
    /// not a transient hiccup.
    private static let failureThreshold = 5

    init(
        url: URL,
        systemActive: Bool,
        micActive: Bool,
        chunks: AsyncStream<AudioChunk>.Continuation,
        levels: AsyncStream<Float>.Continuation,
        events: AsyncStream<RecorderEvent>.Continuation,
        attemptMicRecovery: @MainActor @escaping () async -> Void = {},
        attemptSystemRecovery: @MainActor @escaping () async -> Void = {},
        fileWriterOverride: (any AudioFileWriting)? = nil,
        spoolWriterOverride: (any AudioFileWriting)? = nil
    ) throws {
        buffer.systemActive = systemActive
        buffer.micActive = micActive
        self.systemActive = systemActive
        self.micCaptureActive = micActive
        self.attemptMicRecovery = attemptMicRecovery
        self.attemptSystemRecovery = attemptSystemRecovery
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
        let file = try AVAudioFile(
            forWriting: url, settings: aacSettings,
            commonFormat: .pcmFormatFloat32, interleaved: false
        )
        self.file = file
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
        let spool = try? AVAudioFile(
            forWriting: spoolURL, settings: spoolSettings,
            commonFormat: .pcmFormatFloat32, interleaved: false
        )
        self.spool = spool
        self.chunks = chunks
        self.levels = levels
        self.events = events

        let fileWriter = fileWriterOverride ?? AVAudioFileWriter(file: file)
        let spoolWriter = spoolWriterOverride ?? spool.map { AVAudioFileWriter(file: $0) }
        let (writeStream, writeContinuation) = AsyncStream.makeStream(
            of: [Float].self, bufferingPolicy: .bufferingNewest(Self.writeQueueDepth)
        )
        self.writeQueue = writeContinuation
        let writeHealth = WriteFailureLatch()
        self.writeHealth = writeHealth
        self.writeTask = Task.detached(priority: .utility) {
            await Self.runWriteLoop(
                queue: writeStream, format: format,
                fileWriter: fileWriter, spoolWriter: spoolWriter,
                events: events, health: writeHealth
            )
        }
    }

    /// Independent mic/system sample totals seen so far — see
    /// `MeetingRecorder.SampleCounts`.
    func sampleCounts() -> MeetingRecorder.SampleCounts {
        MeetingRecorder.SampleCounts(mic: buffer.totalMicSamples, system: buffer.totalSystemSamples)
    }

    func pushMic(_ samples: [Float]) {
        guard !paused else { return }
        emit(buffer.pushMic(samples))
        checkLiveness()
    }

    func pushSystem(_ samples: [Float]) {
        guard !paused else { return }
        emit(buffer.pushSystem(samples))
        checkLiveness()
    }

    /// Feeds the current running totals to `LivenessWatchdog` and reacts to
    /// whatever it reports. Both sides get the same bounded auto-recovery,
    /// tracked by one `RestartPolicy` each: up to
    /// `RestartPolicy.attemptsAllowed` rebuild calls
    /// (`MicCapturing.forceRebuild()` / `SystemAudioCapturing.rebuild()`,
    /// hopped back to `MeetingRecorder`'s `@MainActor`, where the sources
    /// live) before `.micStalled`/`.systemAudioStalled` reaches the UI.
    /// `LivenessWatchdog` reports `.resumed` once real progress resumes,
    /// which resets that side's policy so a later, independent stall gets
    /// its own fresh attempts.
    private func checkLiveness() {
        guard
            let event = livenessWatchdog.recordProgress(
                micTotal: buffer.totalMicSamples, systemTotal: buffer.totalSystemSamples,
                systemExpected: systemActive, micExpected: micCaptureActive
            )
        else { return }

        switch event {
        case .stalled(.system):
            if systemRestartPolicy.shouldAttempt() {
                recorderLog.error("system audio stalled: attempting tap rebuild")
                let recover = attemptSystemRecovery
                Task { await recover() }
            } else if systemRestartPolicy.shouldReport() {
                recorderLog.error("system audio stalled: recovery attempts exhausted, reporting to UI")
                events.yield(.systemAudioStalled)
            }
        case .stalled(.mic):
            if micRestartPolicy.shouldAttempt() {
                recorderLog.error("mic stalled: attempting recovery")
                let recover = attemptMicRecovery
                Task { await recover() }
            } else if micRestartPolicy.shouldReport() {
                recorderLog.error("mic stalled: recovery attempts exhausted, reporting to UI")
                events.yield(.micStalled)
            }
        case .resumed(.mic):
            micRestartPolicy.recordResumed()
        case .resumed(.system):
            systemRestartPolicy.recordResumed()
        }
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

    /// Drains the tail, stops accepting new write-queue blocks, awaits the
    /// background write task's queued tail so nothing is lost, then closes
    /// the files and ends the output streams. If the m4a writer had failed,
    /// the spool is transcoded to replace it; otherwise the spool is deleted.
    func finish() async {
        emit(buffer.flushRemainder())
        writeQueue.finish()
        let outcome = await writeTask?.value ?? WriteOutcome()
        file = nil
        spool = nil
        if outcome.fileWriteFailures >= Self.failureThreshold || (try? AVAudioFile(forReading: fileURL)) == nil {
            recorderLog.info("salvaging spool: m4a unreadable or write failures reached threshold")
            AudioTranscoder.salvageSpool(caf: spoolURL, m4a: fileURL)
        } else {
            try? FileManager.default.removeItem(at: spoolURL)
        }
        chunks.finish()
        levels.finish()
        events.finish()
    }

    /// Mixing/RMS/downsample stay here on the actor; the raw samples are
    /// handed to the bounded write queue instead of being written inline —
    /// the actual disk write is what a slow disk stalls on, and this actor
    /// must keep draining `pushMic`/`pushSystem` regardless. If the write
    /// queue is full (the background write task has fallen behind), the
    /// oldest queued block is dropped — see `writeQueue`'s doc comment — and
    /// that drop counts as a write-health strike.
    private func emit(_ mixed: [Float]) {
        guard !mixed.isEmpty else { return }

        if case .dropped = writeQueue.yield(mixed), writeHealth.recordDropped() {
            recorderLog.error("write queue dropped a block: disk write path unhealthy")
            events.yield(.writeFailed)
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

    /// Final thrown-error counts from the background write task, read by
    /// `finish()` once the task has drained — same numbers `emit()` used to
    /// keep as instance state before the writes moved off the actor.
    struct WriteOutcome: Sendable {
        var fileWriteFailures = 0
        var spoolWriteFailures = 0
    }

    /// Runs on its own detached task, never on this actor — the whole point
    /// of moving writes here is that a stalled disk suspends this loop, not
    /// `pushMic`/`pushSystem`. A single consumer means writes land in the
    /// order `emit()` queued them, by construction, with no interleaving to
    /// reason about.
    ///
    /// Builds the `AVAudioPCMBuffer` here (not on the actor) since
    /// `AVAudioPCMBuffer` isn't `Sendable` — only the raw `[Float]` samples
    /// cross from `emit()` through `writeQueue`.
    private static func runWriteLoop(
        queue: AsyncStream<[Float]>,
        format: AVAudioFormat,
        fileWriter: any AudioFileWriting,
        spoolWriter initialSpoolWriter: (any AudioFileWriting)?,
        events: AsyncStream<RecorderEvent>.Continuation,
        health: WriteFailureLatch
    ) async -> WriteOutcome {
        var outcome = WriteOutcome()
        var spoolWriter = initialSpoolWriter
        let clock = ContinuousClock()

        for await samples in queue {
            guard let pcm = pcmBuffer(from: samples, format: format) else { continue }

            let started = clock.now
            health.recordWriteStarted(at: started)

            do {
                try fileWriter.write(pcm)
                outcome.fileWriteFailures = 0
            } catch {
                outcome.fileWriteFailures += 1
            }
            if let writer = spoolWriter {
                do {
                    try writer.write(pcm)
                    outcome.spoolWriteFailures = 0
                } catch {
                    outcome.spoolWriteFailures += 1
                    if outcome.spoolWriteFailures >= Self.failureThreshold {
                        // Give up on the spool; the m4a may still be healthy.
                        spoolWriter = nil
                    }
                }
            }

            if health.recordWriteCompleted(at: clock.now) {
                recorderLog.error("write duration exceeded threshold repeatedly: disk write path unhealthy")
                events.yield(.writeFailed)
            }

            // Only unrecoverable when both writers are failing — mirrors the
            // pre-move logic exactly, just relocated to where the writes now
            // happen. Shares `health`'s one-shot latch with the drop/slow-
            // write path above so a disk that trips both only reports once.
            if outcome.fileWriteFailures >= Self.failureThreshold,
               spoolWriter == nil || outcome.spoolWriteFailures >= Self.failureThreshold,
               health.recordThrownErrorThresholdTripped() {
                recorderLog.error("write-failure threshold tripped: fileFailures=\(outcome.fileWriteFailures, privacy: .public) spoolFailures=\(outcome.spoolWriteFailures, privacy: .public)")
                events.yield(.writeFailed)
            }
        }
        return outcome
    }

    private static func pcmBuffer(from samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard
            let pcm = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)
            ),
            let channel = pcm.floatChannelData
        else { return nil }
        pcm.frameLength = AVAudioFrameCount(samples.count)
        channel[0].update(from: samples, count: samples.count)
        return pcm
    }
}
