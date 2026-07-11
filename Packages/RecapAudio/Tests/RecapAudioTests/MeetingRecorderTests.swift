import AVFoundation
import Foundation
import RecapCore
import Testing
@testable import RecapAudio

/// Fake mic source: exposes the stream's continuation so tests can push
/// sample blocks directly, bypassing AVAudioEngine entirely.
@MainActor
private final class FakeMicSource: MicCapturing {
    var preferredInputUID: String?
    var onRebuild: (@MainActor (String) -> Void)?
    var activeDeviceName: String? = "Fake Mic"

    /// When set, `start()` throws this instead of returning a stream.
    var startError: Error?
    private(set) var stopCalled = false
    private(set) var continuation: AsyncStream<[Float]>.Continuation?

    /// Counts calls to `forceRebuild()` — the liveness watchdog's bounded
    /// mic auto-recovery. Tests set `onForceRebuild` to simulate a
    /// successful (or permanently failed) recovery attempt.
    private(set) var forceRebuildCallCount = 0
    var onForceRebuild: (() -> Void)?

    func start() throws -> AsyncStream<[Float]> {
        if let startError { throw startError }
        let (stream, continuation) = AsyncStream.makeStream(of: [Float].self)
        self.continuation = continuation
        return stream
    }

    func stop() {
        stopCalled = true
        continuation?.finish()
        continuation = nil
    }

    func forceRebuild() {
        forceRebuildCallCount += 1
        onForceRebuild?()
    }
}

/// Fake system-audio source, same shape as `FakeMicSource`.
@MainActor
private final class FakeSystemAudioSource: SystemAudioCapturing {
    var startError: Error?
    private(set) var stopCalled = false
    private(set) var continuation: AsyncStream<[Float]>.Continuation?

    /// When set, `start()` awaits this before returning/throwing — lets
    /// tests hold the call suspended to exercise the re-entrancy guard.
    var suspendUntil: (() async -> Void)?

    /// Counts calls to `rebuild()` — the liveness watchdog's bounded
    /// system-side auto-recovery. Tests set `onRebuildRequested` to simulate
    /// a successful (or permanently failed) recovery attempt.
    private(set) var rebuildCallCount = 0
    var onRebuildRequested: (() -> Void)?

    func start() async throws -> AsyncStream<[Float]> {
        if let suspendUntil {
            await suspendUntil()
        }
        if let startError { throw startError }
        let (stream, continuation) = AsyncStream.makeStream(of: [Float].self)
        self.continuation = continuation
        return stream
    }

    func stop() {
        stopCalled = true
        continuation?.finish()
        continuation = nil
    }

    func rebuild() async {
        rebuildCallCount += 1
        onRebuildRequested?()
    }
}

private struct FakeError: Error {}

/// Thread-safe call counter for closures invoked from detached tasks (the
/// heartbeat/low-disk watchdogs run their polling loops off the main actor).
/// `@unchecked Sendable`: all mutable state is guarded by `lock`.
private final class TickCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }

    /// Returns the count as of just before this call, then increments it —
    /// lets a fake closure answer differently on its Nth invocation.
    func snapshotAndIncrement() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let before = value
        value += 1
        return before
    }
}

/// Lets a test drive a watchdog's tick-driven loop one step at a time
/// instead of an unbounded instant tick (which would spin the loop far
/// faster than real sample delivery and spuriously trip stall detection
/// during test setup). `advance()` unblocks one pending `wait()` call, or —
/// if nothing is waiting yet — queues so the next `wait()` returns
/// immediately, so a test can call `advance()` any number of times up front
/// without racing the loop's own scheduling.
private actor TickGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var pending = 0
    /// Number of `wait()` calls that have returned so far — lets a test poll
    /// until the watchdog's loop has actually consumed every `advance()`
    /// instead of guessing a fixed sleep duration (the loop runs on a
    /// `.utility`-priority detached task, which can lag behind a busy test
    /// runner by more than a few milliseconds).
    private(set) var completed = 0

    func wait() async {
        if pending > 0 {
            pending -= 1
        } else {
            await withCheckedContinuation { continuation = $0 }
        }
        completed += 1
    }

    func advance() {
        if let continuation {
            continuation.resume()
            self.continuation = nil
        } else {
            pending += 1
        }
    }
}

/// Always-throwing `AudioFileWriting` double — proves the write-failure
/// counters (moved off the actor onto `MixerEngine`'s background write task)
/// still trip `.writeFailed` at the same threshold as before the move.
private final class ThrowingFileWriter: AudioFileWriting {
    func write(_ buffer: AVAudioPCMBuffer) throws {
        throw FakeError()
    }
}

@MainActor
@Suite struct MeetingRecorderTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recorder-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A block of `seconds` worth of 440 Hz sine samples at the mixer rate,
    /// so pushed audio has nonzero RMS.
    private func sineBlock(seconds: Double, sampleRate: Double = AudioPipeline.mixerSampleRate) -> [Float] {
        let count = Int(sampleRate * seconds)
        return (0..<count).map { i in
            sinf(Float(i) * 2 * .pi * 440 / Float(sampleRate)) * 0.5
        }
    }

    /// Pushes `seconds` of sine audio to `continuation` in ~100ms chunks so
    /// the mixer actor processes several discrete blocks (matching how real
    /// capture delivers buffers), then yields briefly so pump tasks drain.
    private func push(
        _ continuation: AsyncStream<[Float]>.Continuation, seconds: Double,
        chunkSeconds: Double = 0.1, sampleRate: Double = AudioPipeline.mixerSampleRate
    ) async {
        var remaining = seconds
        while remaining > 0 {
            let this = min(chunkSeconds, remaining)
            continuation.yield(sineBlock(seconds: this, sampleRate: sampleRate))
            remaining -= this
            await Task.yield()
        }
        // Let the detached pump tasks catch up with the mixer actor.
        try? await Task.sleep(for: .milliseconds(50))
    }

    /// Same as `push(_:seconds:...)` above but for the system-audio side —
    /// used by the mic-stall tests, which need system audio to keep flowing
    /// while the mic side stays silent.
    private func pushSystem(
        _ continuation: AsyncStream<[Float]>.Continuation, seconds: Double,
        chunkSeconds: Double = 0.5, sampleRate: Double = AudioPipeline.mixerSampleRate
    ) async {
        var remaining = seconds
        while remaining > 0 {
            let this = min(chunkSeconds, remaining)
            continuation.yield(sineBlock(seconds: this, sampleRate: sampleRate))
            remaining -= this
            await Task.yield()
        }
        try? await Task.sleep(for: .milliseconds(50))
    }

    // MARK: 1. Mic-only happy path

    @Test func micOnlyHappyPath() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("audio.m4a")
        let mic = FakeMicSource()
        let recorder = MeetingRecorder(mic: mic, makeSystemTap: { FakeSystemAudioSource() })

        let output = try await recorder.start(writingTo: url, includeSystemAudio: false, includeMic: true)
        _ = output
        let micContinuation = try #require(mic.continuation)

        await push(micContinuation, seconds: 1.0)

        // `stop()`'s return value is wall-clock elapsed time (RecordingClock
        // measures real time from start() to stop()), which races ahead of
        // how fast the test can push audio — assert on it loosely and rely
        // on the written file's actual audio duration for the real check.
        let duration = await recorder.stop()
        #expect(duration >= 0)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let fileDuration = try #require(AudioTranscoder.duration(of: url))
        #expect(abs(fileDuration - 1.0) < 0.2)

        let spoolURL = url.deletingPathExtension().appendingPathExtension("caf")
        #expect(!FileManager.default.fileExists(atPath: spoolURL.path))
    }

    // MARK: 2. 16kHz chunk stream downsampled 3:1

    @Test func chunkStreamIsDownsampled3to1WithIncreasingStart() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("audio.m4a")
        let mic = FakeMicSource()
        let recorder = MeetingRecorder(mic: mic, makeSystemTap: { FakeSystemAudioSource() })

        let output = try await recorder.start(writingTo: url, includeSystemAudio: false, includeMic: true)
        let micContinuation = try #require(mic.continuation)

        var collected: [AudioChunk] = []
        let collectorTask = Task {
            for await chunk in output.chunks {
                collected.append(chunk)
            }
        }

        // 48,000 samples in = 16,000 samples out at 16kHz (3:1).
        micContinuation.yield(sineBlock(seconds: 1.0))
        try? await Task.sleep(for: .milliseconds(100))

        _ = await recorder.stop()
        await collectorTask.value

        #expect(!collected.isEmpty)
        let totalOutSamples = collected.reduce(0) { $0 + $1.samples.count }
        // 48,000 in / 3 == 16,000 out, within a sample or two of carry.
        #expect(abs(totalOutSamples - 16_000) <= 3)
        #expect(collected.allSatisfy { $0.sampleRate == 16_000 })

        var lastStart: TimeInterval = -1
        for chunk in collected {
            #expect(chunk.start > lastStart)
            lastStart = chunk.start
        }
    }

    // MARK: 3. Pause gates samples

    @Test func pauseGatesSamples() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("audio.m4a")
        let mic = FakeMicSource()
        let recorder = MeetingRecorder(mic: mic, makeSystemTap: { FakeSystemAudioSource() })

        _ = try await recorder.start(writingTo: url, includeSystemAudio: false, includeMic: true)
        let micContinuation = try #require(mic.continuation)

        await push(micContinuation, seconds: 0.5)
        await recorder.pause()
        // Dropped while paused — must not reach the file.
        await push(micContinuation, seconds: 0.5)
        await recorder.resume()
        await push(micContinuation, seconds: 0.5)

        _ = await recorder.stop()

        let fileDuration = try #require(AudioTranscoder.duration(of: url))
        #expect(abs(fileDuration - 1.0) < 0.2)
        #expect(fileDuration < 1.3)
    }

    // MARK: 4. No audio source / mic start throws

    @Test func noAudioSourceWhenNeitherMicNorSystemIncluded() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("audio.m4a")
        let mic = FakeMicSource()
        let recorder = MeetingRecorder(mic: mic, makeSystemTap: { FakeSystemAudioSource() })

        await #expect(throws: MeetingRecorder.RecorderError.noAudioSource) {
            _ = try await recorder.start(writingTo: url, includeSystemAudio: false, includeMic: false)
        }
    }

    @Test func micStartThrowPropagatesAndStopsSystemTap() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("audio.m4a")
        let mic = FakeMicSource()
        mic.startError = FakeError()
        let tap = FakeSystemAudioSource()
        let recorder = MeetingRecorder(mic: mic, makeSystemTap: { tap })

        await #expect(throws: FakeError.self) {
            _ = try await recorder.start(writingTo: url, includeSystemAudio: true, includeMic: true)
        }
        #expect(tap.stopCalled)
    }

    /// The mixer engine (and its m4a/CAF file handles) is already built by
    /// the time mic.start() fails — before the fix it was never finished or
    /// nil'd on this path, leaking open file handles and leaving a
    /// zero-byte/unreadable m4a with no moov atom. `finish()` must run here
    /// too, same as a normal `stop()`.
    @Test func micStartFailureFinishesAndClearsTheEngine() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("audio.m4a")
        let mic = FakeMicSource()
        mic.startError = FakeError()
        let tap = FakeSystemAudioSource()
        let recorder = MeetingRecorder(mic: mic, makeSystemTap: { tap })

        await #expect(throws: FakeError.self) {
            _ = try await recorder.start(writingTo: url, includeSystemAudio: true, includeMic: true)
        }

        // The m4a must be readable (moov atom written) — only true if
        // `finish()` actually ran and closed the file.
        let fileDuration = try #require(AudioTranscoder.duration(of: url))
        #expect(fileDuration >= 0)
        // A clean finish() with no write failures deletes the spool.
        let spoolURL = url.deletingPathExtension().appendingPathExtension("caf")
        #expect(!FileManager.default.fileExists(atPath: spoolURL.path))

        // A subsequent start() must succeed against a fresh engine — no
        // stale engine left retained from the failed attempt.
        mic.startError = nil
        _ = try await recorder.start(writingTo: url, includeSystemAudio: false, includeMic: true)
        _ = await recorder.stop()
    }

    // MARK: 5. System tap fails -> mic-only fallback

    @Test func systemTapFailureFallsBackToMicOnly() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("audio.m4a")
        let mic = FakeMicSource()
        let tap = FakeSystemAudioSource()
        tap.startError = FakeError()
        let recorder = MeetingRecorder(mic: mic, makeSystemTap: { tap })

        _ = try await recorder.start(writingTo: url, includeSystemAudio: true, includeMic: true)

        #expect(recorder.systemAudioActive == false)
        #expect(recorder.micActive == true)

        _ = await recorder.stop()
    }

    // MARK: 5b. Re-entrancy guard

    /// A second `start()` call arriving while the first is still suspended
    /// inside `tap.start()` (mirroring a real await on the TCC prompt) must
    /// be rejected rather than racing on `systemTap`/`engine` state.
    @Test func concurrentStartWhileSuspendedThrowsAlreadyStarting() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("audio.m4a")
        let mic = FakeMicSource()
        let tap = FakeSystemAudioSource()
        let (releaseSignal, releaseContinuation) = AsyncStream.makeStream(of: Void.self)
        tap.suspendUntil = {
            var iterator = releaseSignal.makeAsyncIterator()
            _ = await iterator.next()
        }
        let recorder = MeetingRecorder(mic: mic, makeSystemTap: { tap })

        let firstStart = Task {
            _ = try await recorder.start(writingTo: url, includeSystemAudio: true, includeMic: true)
        }
        // Give the first call a chance to reach and suspend inside tap.start().
        try? await Task.sleep(for: .milliseconds(20))

        await #expect(throws: MeetingRecorder.RecorderError.alreadyStarting) {
            _ = try await recorder.start(writingTo: url, includeSystemAudio: true, includeMic: true)
        }

        releaseContinuation.yield(())
        releaseContinuation.finish()
        try await firstStart.value

        _ = await recorder.stop()
    }

    // MARK: 5c. stop() racing an in-flight start()

    /// Reproduces the reported bug: `stop()` arrives while `start()` is
    /// still suspended inside `tap.start()` (e.g. the system-audio TCC
    /// prompt is up). Before the fix, `stop()` found `systemTap`/`engine`
    /// still nil and tore down nothing; `start()` then resumed, built a live
    /// recording, and nothing was ever listening to stop it. `stop()` must
    /// instead defer to the in-flight `start()`, which tears everything down
    /// itself and throws `.startCancelled` rather than handing back a live
    /// `Output`.
    @Test func stopDuringStartTearsDownAndThrowsStartCancelled() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("audio.m4a")
        let mic = FakeMicSource()
        let tap = FakeSystemAudioSource()
        let (releaseSignal, releaseContinuation) = AsyncStream.makeStream(of: Void.self)
        tap.suspendUntil = {
            var iterator = releaseSignal.makeAsyncIterator()
            _ = await iterator.next()
        }
        let recorder = MeetingRecorder(mic: mic, makeSystemTap: { tap })

        let startTask = Task {
            _ = try await recorder.start(writingTo: url, includeSystemAudio: true, includeMic: true)
        }
        // Give start() a chance to reach and suspend inside tap.start().
        try? await Task.sleep(for: .milliseconds(20))

        // stop() must return immediately (nothing built yet to tear down)
        // rather than blocking on the suspended start().
        let stopDuration = await recorder.stop()
        #expect(stopDuration == 0)

        releaseContinuation.yield(())
        releaseContinuation.finish()

        do {
            _ = try await startTask.value
            Issue.record("expected start() to throw .startCancelled")
        } catch MeetingRecorder.RecorderError.startCancelled {
            // Expected.
        } catch {
            Issue.record("expected .startCancelled, got \(error)")
        }

        // start() must have torn down everything it built before throwing —
        // no orphaned tap, mic capture, or live recording left running.
        #expect(tap.stopCalled)
        #expect(mic.stopCalled)
        #expect(recorder.systemAudioActive == false)
        #expect(recorder.micActive == false)
        #expect(recorder.clock == nil)

        // A fresh start() afterward must succeed normally — isStarting and
        // the pending-stop flag aren't left in a stuck state.
        tap.suspendUntil = nil
        _ = try await recorder.start(writingTo: url, includeSystemAudio: true, includeMic: true)
        _ = await recorder.stop()
    }

    // MARK: 6. Rebuild event forwarding

    @Test func rebuildEventIsForwarded() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("audio.m4a")
        let mic = FakeMicSource()
        let recorder = MeetingRecorder(mic: mic, makeSystemTap: { FakeSystemAudioSource() })

        let output = try await recorder.start(writingTo: url, includeSystemAudio: false, includeMic: true)

        var collected: [RecorderEvent] = []
        let collectorTask = Task {
            for await event in output.events {
                collected.append(event)
            }
        }

        try? await Task.sleep(for: .milliseconds(20))
        mic.onRebuild?("device switch")
        try? await Task.sleep(for: .milliseconds(20))

        _ = await recorder.stop()
        await collectorTask.value

        #expect(collected.contains(.inputRebuilt(reason: "device switch")))
    }

    // MARK: 7b. System audio stall detection + bounded auto-recovery

    /// Reproduces the reported bug: system audio starts successfully
    /// (`systemAudioActive == true`) but then goes silent mid-call (e.g. a
    /// route change or sleep cycle breaks the aggregate device's tap link)
    /// while the mic keeps streaming. The watchdog in `MixerEngine` must
    /// notice — driven purely by sample counts, so this needs no wall-clock
    /// waiting. Like the mic side, the recorder first makes bounded recovery
    /// attempts (`SystemAudioCapturing.rebuild()`, up to
    /// `RestartPolicy.attemptsAllowed` == 2) before giving up and emitting
    /// `.systemAudioStalled` — this fake's `rebuild()` is a no-op
    /// (simulating a tap that can't be brought back), so recovery never
    /// succeeds and the event must eventually surface exactly once, while
    /// the recording keeps running (not stopped) and `systemAudioActive`
    /// stays true (mirroring `.writeFailed`'s auto-stop being the only case
    /// that tears the session down).
    @Test func systemTapNeverRecoveringEmitsSystemAudioStalledAfterBoundedAttempts() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("audio.m4a")
        let mic = FakeMicSource()
        let tap = FakeSystemAudioSource()
        let recorder = MeetingRecorder(mic: mic, makeSystemTap: { tap })

        let output = try await recorder.start(writingTo: url, includeSystemAudio: true, includeMic: true)
        #expect(recorder.systemAudioActive == true)
        let micContinuation = try #require(mic.continuation)
        let systemContinuation = try #require(tap.continuation)

        var collected: [RecorderEvent] = []
        let collectorTask = Task {
            for await event in output.events {
                collected.append(event)
            }
        }

        // A brief moment of real two-sided audio first, so this isn't just
        // "system audio never started" — it genuinely goes quiet mid-call.
        systemContinuation.yield(sineBlock(seconds: 0.2))
        await push(micContinuation, seconds: 0.2)

        // Now system audio goes silent for good while the mic keeps
        // streaming past three stall thresholds — two bounded recovery
        // attempts, then the final report once recovery keeps failing.
        let secondsPerThreshold = Double(LivenessWatchdog.stallThreshold) / AudioPipeline.mixerSampleRate
        await push(micContinuation, seconds: secondsPerThreshold * 3.5, chunkSeconds: 0.5)

        #expect(tap.rebuildCallCount == 2)
        #expect(collected.contains(.systemAudioStalled))
        // Exactly once — not repeated on every subsequent mic push.
        #expect(collected.filter { $0 == .systemAudioStalled }.count == 1)
        // The recording is NOT torn down by a stall — mirrors the fact that
        // only `.writeFailed` triggers auto-stop; `systemAudioActive` stays
        // true because the tap itself never reported failure, only silence.
        #expect(recorder.systemAudioActive == true)

        _ = await recorder.stop()
        await collectorTask.value
    }

    /// When the bounded rebuild actually brings system audio back (the
    /// fake's `rebuild()` here pushes fresh samples into the SAME stream,
    /// simulating `SystemAudioTap.rebuild()`'s stable-stream re-setup), the
    /// recorder must NOT emit `.systemAudioStalled` at all — successful
    /// recovery means no toast — and must reset its attempt counter so a
    /// later, independent stall gets fresh attempts.
    @Test func systemTapDyingMidRecordingAttemptsRebuildAndSuppressesToastOnRecovery() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("audio.m4a")
        let mic = FakeMicSource()
        let tap = FakeSystemAudioSource()
        let recorder = MeetingRecorder(mic: mic, makeSystemTap: { tap })

        let output = try await recorder.start(writingTo: url, includeSystemAudio: true, includeMic: true)
        let micContinuation = try #require(mic.continuation)
        let systemContinuation = try #require(tap.continuation)

        // Simulate a successful rebuild: as soon as `rebuild()` is called,
        // system samples start flowing again on the same continuation.
        tap.onRebuildRequested = { [systemContinuation] in
            systemContinuation.yield([Float](repeating: 0.1, count: 4_800))
        }

        var collected: [RecorderEvent] = []
        let collectorTask = Task {
            for await event in output.events {
                collected.append(event)
            }
        }

        systemContinuation.yield(sineBlock(seconds: 0.2))
        await push(micContinuation, seconds: 0.2)

        // Cross exactly one stall threshold — first rebuild attempt fires,
        // and (per the fake's hook above) immediately "succeeds".
        let secondsPerThreshold = Double(LivenessWatchdog.stallThreshold) / AudioPipeline.mixerSampleRate
        await push(micContinuation, seconds: secondsPerThreshold + 0.2, chunkSeconds: 0.5)

        #expect(tap.rebuildCallCount == 1)
        #expect(!collected.contains(.systemAudioStalled))

        _ = await recorder.stop()
        await collectorTask.value
    }

    /// Symmetric sanity check: when system audio keeps flowing normally
    /// alongside the mic, the watchdog must never fire a false positive.
    @Test func systemAudioStayingLiveNeverEmitsStallEvent() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("audio.m4a")
        let mic = FakeMicSource()
        let tap = FakeSystemAudioSource()
        let recorder = MeetingRecorder(mic: mic, makeSystemTap: { tap })

        let output = try await recorder.start(writingTo: url, includeSystemAudio: true, includeMic: true)
        let micContinuation = try #require(mic.continuation)
        let systemContinuation = try #require(tap.continuation)

        var collected: [RecorderEvent] = []
        let collectorTask = Task {
            for await event in output.events {
                collected.append(event)
            }
        }

        // Interleave mic and system pushes well past the stall threshold —
        // system keeps making progress throughout, so the watchdog baseline
        // keeps resetting and should never trip.
        for _ in 0..<6 {
            await push(micContinuation, seconds: 1.0)
            systemContinuation.yield(sineBlock(seconds: 1.0))
            try? await Task.sleep(for: .milliseconds(20))
        }

        _ = await recorder.stop()
        await collectorTask.value

        #expect(!collected.contains(.systemAudioStalled))
    }

    // MARK: 7c. Mic stall detection + bounded auto-recovery (mirror image of 7b)

    /// Mirror image of `systemAudioGoingSilentMidRecordingEmitsStallEvent`:
    /// the mic goes silent mid-call (e.g. a USB device unplugged with no
    /// fallback) while system audio keeps flowing. Unlike the system side,
    /// the recorder first makes bounded recovery attempts
    /// (`MicCapturing.forceRebuild()`, up to `maxMicRebuildAttempts` == 2)
    /// before giving up and emitting `.micStalled` — this fake's
    /// `forceRebuild()` is a no-op (simulating a truly dead device with no
    /// fallback), so recovery never succeeds and the event must eventually
    /// surface exactly once.
    @Test func micGoingSilentMidRecordingAttemptsRecoveryThenEmitsMicStalledEvent() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("audio.m4a")
        let mic = FakeMicSource()
        let tap = FakeSystemAudioSource()
        let recorder = MeetingRecorder(mic: mic, makeSystemTap: { tap })

        let output = try await recorder.start(writingTo: url, includeSystemAudio: true, includeMic: true)
        #expect(recorder.micActive == true)
        let micContinuation = try #require(mic.continuation)
        let systemContinuation = try #require(tap.continuation)

        var collected: [RecorderEvent] = []
        let collectorTask = Task {
            for await event in output.events {
                collected.append(event)
            }
        }

        // A brief moment of real two-sided audio first, so this is a
        // genuine mid-call dropout, not "the mic never started".
        await push(micContinuation, seconds: 0.2)
        systemContinuation.yield(sineBlock(seconds: 0.2))
        try? await Task.sleep(for: .milliseconds(50))

        // Mic goes silent for good; system audio keeps flowing past three
        // stall thresholds — two bounded recovery attempts, then the final
        // report once recovery keeps failing.
        let secondsPerThreshold = Double(LivenessWatchdog.stallThreshold) / AudioPipeline.mixerSampleRate
        await pushSystem(systemContinuation, seconds: secondsPerThreshold * 3.5)

        #expect(mic.forceRebuildCallCount == 2)
        #expect(collected.contains(.micStalled))
        // Exactly once — not repeated on every subsequent system push.
        #expect(collected.filter { $0 == .micStalled }.count == 1)
        // Mirrors `.systemAudioStalled`'s non-fatal semantics: the recording
        // itself is not stopped or marked inactive by a stall alone. Checked
        // before `stop()`, which unconditionally resets `micActive`.
        #expect(recorder.micActive == true)

        _ = await recorder.stop()
        await collectorTask.value
    }

    /// When the bounded recovery attempt actually brings the mic back (the
    /// fake's `forceRebuild()` here pushes fresh samples, simulating a
    /// successful graph rebuild against a fallback device), the recorder
    /// must NOT emit `.micStalled` and must reset its attempt counter — a
    /// later, independent stall gets its own fresh attempts rather than
    /// being treated as already-exhausted.
    @Test func micRecoveringDuringFirstAttemptSuppressesMicStalledAndResetsAttempts() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("audio.m4a")
        let mic = FakeMicSource()
        let tap = FakeSystemAudioSource()
        let recorder = MeetingRecorder(mic: mic, makeSystemTap: { tap })

        let output = try await recorder.start(writingTo: url, includeSystemAudio: true, includeMic: true)
        let micContinuation = try #require(mic.continuation)
        let systemContinuation = try #require(tap.continuation)

        // Simulate a successful rebuild: as soon as `forceRebuild()` is
        // called, mic samples start flowing again.
        mic.onForceRebuild = { [micContinuation] in
            micContinuation.yield([Float](repeating: 0.1, count: 4_800))
        }

        var collected: [RecorderEvent] = []
        let collectorTask = Task {
            for await event in output.events {
                collected.append(event)
            }
        }

        await push(micContinuation, seconds: 0.2)
        systemContinuation.yield(sineBlock(seconds: 0.2))
        try? await Task.sleep(for: .milliseconds(50))

        // Cross exactly one stall threshold — first recovery attempt fires,
        // and (per the fake's hook above) immediately "succeeds".
        let secondsPerThreshold = Double(LivenessWatchdog.stallThreshold) / AudioPipeline.mixerSampleRate
        await pushSystem(systemContinuation, seconds: secondsPerThreshold + 0.2)

        #expect(mic.forceRebuildCallCount == 1)
        #expect(!collected.contains(.micStalled))

        _ = await recorder.stop()
        await collectorTask.value
    }

    // MARK: 7. Levels stream RMS > 0

    @Test func levelsStreamEmitsPositiveRMSForNonSilentInput() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("audio.m4a")
        let mic = FakeMicSource()
        let recorder = MeetingRecorder(mic: mic, makeSystemTap: { FakeSystemAudioSource() })

        let output = try await recorder.start(writingTo: url, includeSystemAudio: false, includeMic: true)
        let micContinuation = try #require(mic.continuation)

        var collected: [Float] = []
        let collectorTask = Task {
            for await level in output.levels {
                collected.append(level)
            }
        }

        await push(micContinuation, seconds: 0.5)

        _ = await recorder.stop()
        await collectorTask.value

        #expect(!collected.isEmpty)
        #expect(collected.contains { $0 > 0 })
    }

    /// Drives `gate.advance()` `count` times, then polls (bounded, ~2s worst
    /// case) until the watchdog's loop has actually consumed all of them —
    /// more robust than a fixed sleep against a `.utility`-priority task that
    /// can lag behind a busy test runner.
    private func driveTicks(_ gate: TickGate, count: Int) async {
        for _ in 0..<count {
            await gate.advance()
        }
        for _ in 0..<200 {
            if await gate.completed >= count { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        // A little extra settle time for `checkHeartbeat()`/`handleWatchdogEvent`
        // (and any recovery `Task`s they spawn) to finish running after the
        // last tick was consumed.
        try? await Task.sleep(for: .milliseconds(50))
    }

    // MARK: 7d. Mic-only heartbeat watchdog (wall-clock companion to LivenessWatchdog)

    /// Mic-only recording (no system audio at all): a dead mic tap stops
    /// pushing samples entirely, so `LivenessWatchdog`'s sample-count-based
    /// detection has nothing to measure silence against (its mic-stall
    /// direction requires `systemExpected`). `HeartbeatWatchdog`'s wall-clock
    /// tick is the only thing that can notice — with an instant tick
    /// override, the same bounded-recovery path (`RestartPolicy`,
    /// `forceRebuild()`) must still apply: two attempts, then `.micStalled`.
    @Test func micOnlyHeartbeatAttemptsRecoveryThenEmitsMicStalledEvent() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("audio.m4a")
        let mic = FakeMicSource()
        let recorder = MeetingRecorder(mic: mic, makeSystemTap: { FakeSystemAudioSource() })
        let gate = TickGate()
        recorder.testHeartbeatTickOverride = { await gate.wait() }

        let output = try await recorder.start(writingTo: url, includeSystemAudio: false, includeMic: true)
        let micContinuation = try #require(mic.continuation)

        var collected: [RecorderEvent] = []
        let collectorTask = Task {
            for await event in output.events {
                collected.append(event)
            }
        }

        // A brief moment of real audio first, so the mic genuinely goes
        // silent mid-call rather than never starting. No heartbeat ticks are
        // driven during this window, so it can't spuriously trip the
        // watchdog against the chunked delivery of `push(...)`.
        await push(micContinuation, seconds: 0.2)

        // The very first tick always registers as "progress" (the watchdog's
        // baseline starts at 0, and the mic total from the `push` above is
        // already nonzero) — so 3 stall windows costs one extra tick beyond
        // `stallTicks * 3`: two bounded recovery attempts, then the final
        // report once recovery keeps failing (this fake's `forceRebuild()`
        // is a no-op).
        await driveTicks(gate, count: HeartbeatWatchdog.stallTicks * 3 + 1)

        #expect(mic.forceRebuildCallCount == 2)
        #expect(collected.contains(.micStalled))
        #expect(collected.filter { $0 == .micStalled }.count == 1)
        #expect(recorder.micActive == true)

        _ = await recorder.stop()
        await collectorTask.value
    }

    /// When the bounded recovery attempt actually brings the mic back (the
    /// fake's `forceRebuild()` pushes fresh samples), `.micStalled` must
    /// never be emitted.
    @Test func micOnlyHeartbeatRecoveringSuppressesMicStalledEvent() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("audio.m4a")
        let mic = FakeMicSource()
        let recorder = MeetingRecorder(mic: mic, makeSystemTap: { FakeSystemAudioSource() })
        let gate = TickGate()
        recorder.testHeartbeatTickOverride = { await gate.wait() }

        let output = try await recorder.start(writingTo: url, includeSystemAudio: false, includeMic: true)
        let micContinuation = try #require(mic.continuation)

        mic.onForceRebuild = { [micContinuation] in
            micContinuation.yield([Float](repeating: 0.1, count: 4_800))
        }

        var collected: [RecorderEvent] = []
        let collectorTask = Task {
            for await event in output.events {
                collected.append(event)
            }
        }

        await push(micContinuation, seconds: 0.2)

        // The very first tick always registers as "progress" (see the
        // sibling test's comment) — one stall window costs `stallTicks + 1`
        // ticks. The first recovery attempt fires and (per the fake's hook
        // above) immediately "succeeds", pushing samples that resume
        // progress.
        await driveTicks(gate, count: HeartbeatWatchdog.stallTicks + 1)

        #expect(mic.forceRebuildCallCount == 1)
        #expect(!collected.contains(.micStalled))

        _ = await recorder.stop()
        await collectorTask.value
    }

    /// Dual-source recording: the heartbeat must never start at all (only
    /// the mic-only case gets one), so there's no double-reporting alongside
    /// `LivenessWatchdog`. Proven by the heartbeat tick override never being
    /// invoked even with an instant tick and a long wait.
    @Test func dualSourceRecordingNeverStartsHeartbeat() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("audio.m4a")
        let mic = FakeMicSource()
        let tap = FakeSystemAudioSource()
        let recorder = MeetingRecorder(mic: mic, makeSystemTap: { tap })
        let tickCount = TickCounter()
        recorder.testHeartbeatTickOverride = { tickCount.increment() }

        _ = try await recorder.start(writingTo: url, includeSystemAudio: true, includeMic: true)
        try? await Task.sleep(for: .milliseconds(150))

        #expect(tickCount.count == 0)

        _ = await recorder.stop()
    }

    // MARK: 9. Mid-recording low-disk watchdog

    /// `freeBytes` reports comfortably-above-threshold space at first, then
    /// drops below `lowSpaceStopBytes` — the watchdog must emit
    /// `.diskSpaceLow` exactly once and then stop polling (no repeated
    /// events on subsequent ticks).
    @Test func lowDiskSpaceMidRecordingEmitsDiskSpaceLowExactlyOnce() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("audio.m4a")
        let mic = FakeMicSource()
        let callCount = TickCounter()
        let recorder = MeetingRecorder(
            mic: mic, makeSystemTap: { FakeSystemAudioSource() },
            freeBytes: { _ in
                callCount.snapshotAndIncrement() < 2 ? 10_000_000_000 : 100_000_000
            }
        )
        recorder.testFreeSpaceTickOverride = {}

        let output = try await recorder.start(writingTo: url, includeSystemAudio: false, includeMic: true)

        var collected: [RecorderEvent] = []
        let collectorTask = Task {
            for await event in output.events {
                collected.append(event)
            }
        }

        try? await Task.sleep(for: .milliseconds(200))

        #expect(collected.contains(.diskSpaceLow))
        #expect(collected.filter { $0 == .diskSpaceLow }.count == 1)

        _ = await recorder.stop()
        await collectorTask.value
    }

    // MARK: 8. Write failures still trip .writeFailed after moving off the actor

    /// The m4a/spool writes now run on `MixerEngine`'s background write task
    /// instead of inline in `emit()`, but the thrown-error threshold and
    /// `.writeFailed` semantics must be unchanged. Both writers are swapped
    /// for a double that always throws, so neither side can "reset" the
    /// other's failure count back to zero.
    @Test func writersThrowingRepeatedlyStillTripsWriteFailed() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("audio.m4a")
        let mic = FakeMicSource()
        let recorder = MeetingRecorder(mic: mic, makeSystemTap: { FakeSystemAudioSource() })
        recorder.testFileWriterOverride = ThrowingFileWriter()
        recorder.testSpoolWriterOverride = ThrowingFileWriter()

        let output = try await recorder.start(writingTo: url, includeSystemAudio: false, includeMic: true)
        let micContinuation = try #require(mic.continuation)

        var collected: [RecorderEvent] = []
        let collectorTask = Task {
            for await event in output.events {
                collected.append(event)
            }
        }

        // 10 blocks at the default 0.1s chunking — comfortably past the
        // failure threshold (5) on both writers.
        await push(micContinuation, seconds: 1.0)

        _ = await recorder.stop()
        await collectorTask.value

        #expect(collected.contains(.writeFailed))
    }
}

// MARK: - SystemAudioProbeResult error mapping

@Suite struct SystemAudioProbeResultMappingTests {
    @Test func tapCreationFailedMapsToDenied() {
        let result = SystemAudioProbeResult(mappingError: SystemAudioTap.TapError.tapCreationFailed(-1))
        #expect(result == .denied)
    }

    @Test func aggregateCreationFailedMapsToFailedWithMessage() {
        let result = SystemAudioProbeResult(mappingError: SystemAudioTap.TapError.aggregateCreationFailed(-2))
        #expect(result == .failed("aggregateCreationFailed(-2)"))
    }

    @Test func ioSetupFailedMapsToFailedWithMessage() {
        let result = SystemAudioProbeResult(mappingError: SystemAudioTap.TapError.ioSetupFailed(-3))
        #expect(result == .failed("ioSetupFailed(-3)"))
    }

    @Test func formatUnsupportedMapsToFailed() {
        let result = SystemAudioProbeResult(mappingError: SystemAudioTap.TapError.formatUnsupported)
        #expect(result == .failed("formatUnsupported"))
    }

    @Test func unknownErrorMapsToFailed() {
        let result = SystemAudioProbeResult(mappingError: FakeError())
        guard case .failed = result else {
            Issue.record("expected .failed, got \(result)")
            return
        }
    }
}

// MARK: - MeetingRecorder.probeSystemAudio behavior

@MainActor
@Suite struct SystemAudioProbeTests {
    @Test func succeedsOnFirstAttemptWithoutSleeping() async {
        let tap = FakeSystemAudioSource()
        var sleepCalls = 0

        let result = await MeetingRecorder.probeSystemAudio(
            makeTap: { tap },
            sleep: { sleepCalls += 1 }
        )

        #expect(result == .captured)
        #expect(sleepCalls == 0)
        #expect(tap.stopCalled)
    }

    @Test func deniedFirstAttemptRetriesOnceAndSucceeds() async {
        var attempt = 0
        var sleepCalls = 0

        let result = await MeetingRecorder.probeSystemAudio(
            makeTap: {
                attempt += 1
                let tap = FakeSystemAudioSource()
                if attempt == 1 {
                    tap.startError = SystemAudioTap.TapError.tapCreationFailed(-1)
                }
                return tap
            },
            sleep: { sleepCalls += 1 }
        )

        #expect(result == .captured)
        #expect(attempt == 2)
        #expect(sleepCalls == 1)
    }

    @Test func deniedOnBothAttemptsReturnsDenied() async {
        var attempt = 0
        var sleepCalls = 0

        let result = await MeetingRecorder.probeSystemAudio(
            makeTap: {
                attempt += 1
                let tap = FakeSystemAudioSource()
                tap.startError = SystemAudioTap.TapError.tapCreationFailed(-1)
                return tap
            },
            sleep: { sleepCalls += 1 }
        )

        #expect(result == .denied)
        #expect(attempt == 2)
        #expect(sleepCalls == 1)
    }

    @Test func nonDeniedFailureDoesNotRetry() async {
        var attempt = 0
        var sleepCalls = 0

        let result = await MeetingRecorder.probeSystemAudio(
            makeTap: {
                attempt += 1
                let tap = FakeSystemAudioSource()
                tap.startError = SystemAudioTap.TapError.formatUnsupported
                return tap
            },
            sleep: { sleepCalls += 1 }
        )

        #expect(result == .failed("formatUnsupported"))
        #expect(attempt == 1)
        #expect(sleepCalls == 0)
    }

    @Test func stopIsCalledEvenOnFailure() async {
        let tap = FakeSystemAudioSource()
        tap.startError = SystemAudioTap.TapError.formatUnsupported

        _ = await MeetingRecorder.probeSystemAudio(makeTap: { tap }, sleep: {})

        #expect(tap.stopCalled)
    }
}
