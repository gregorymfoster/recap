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
}

private struct FakeError: Error {}

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

    // MARK: 7b. System audio stall detection

    /// Reproduces the reported bug: system audio starts successfully
    /// (`systemAudioActive == true`) but then goes silent mid-call (e.g. a
    /// route change breaks the aggregate device's tap link) while the mic
    /// keeps streaming. The watchdog in `MixerEngine` must notice — driven
    /// purely by sample counts, so this needs no wall-clock waiting: push
    /// enough mic-only audio past `systemAudioStallThreshold` (4s ≈ 192,000
    /// samples at 48kHz) with zero further system samples, and the recorder
    /// must emit `.systemAudioStalled` exactly once, while the recording
    /// keeps running (not stopped) and `systemAudioActive` stays true
    /// (mirroring `.writeFailed`'s auto-stop being the only case that tears
    /// the session down).
    @Test func systemAudioGoingSilentMidRecordingEmitsStallEvent() async throws {
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

        // Now system audio goes silent while the mic keeps streaming past
        // the stall threshold (4s of mic samples with zero more from system).
        await push(micContinuation, seconds: 4.5)

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
