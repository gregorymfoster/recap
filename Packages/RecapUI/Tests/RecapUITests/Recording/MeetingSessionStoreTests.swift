import Foundation
import RecapAudio
import RecapCore
import Testing
@testable import RecapUI

/// Fake mic source, copied from `RecapAudioTests/MeetingRecorderTests.swift`
/// so `MeetingRecorder` can be built here without touching real hardware.
@MainActor
private final class FakeMicSource: MicCapturing {
    var preferredInputUID: String?
    var onRebuild: (@MainActor (String) -> Void)?
    var activeDeviceName: String? = "Fake Mic"
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

    func start() async throws -> AsyncStream<[Float]> {
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
@Suite struct MeetingSessionStoreTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeRecord(in dir: URL) -> MeetingRecord {
        MeetingRecord(meeting: Meeting(title: "Test", date: .now), folderURL: dir)
    }

    private func makeStore(
        micGranted: Bool = true,
        probeResult: SystemAudioProbeResult = .captured
    ) -> (store: MeetingSessionStore, probeCallCount: () -> Int) {
        let counter = Counter()
        let store = MeetingSessionStore(
            makeRecorder: { MeetingRecorder(mic: FakeMicSource(), makeSystemTap: { FakeSystemAudioSource() }) },
            requestMicPermission: { micGranted },
            probeSystemAudio: {
                counter.increment()
                return probeResult
            }
        )
        return (store, { counter.count })
    }

    /// Tiny mutable box so the probe closures above (which must be
    /// non-escaping-safe `@Sendable`-free @MainActor closures) can count
    /// calls without capturing `var` directly across the closure boundary.
    @MainActor
    private final class Counter {
        private(set) var count = 0
        func increment() { count += 1 }
    }

    // MARK: preflight

    @Test func micDeniedAndProbeDeniedIsBlockedAndProbesOnce() async throws {
        let (store, probeCallCount) = makeStore(micGranted: false, probeResult: .denied)

        let result = await store.preflight(includeSystemAudio: true, lastTapFailed: nil)

        #expect(result.outcome == .blocked)
        #expect(result.probeResult == .denied)
        #expect(probeCallCount() == 1)
    }

    @Test func micDeniedAndProbeCapturedProceedsSystemAudioOnly() async throws {
        let (store, probeCallCount) = makeStore(micGranted: false, probeResult: .captured)

        let result = await store.preflight(includeSystemAudio: true, lastTapFailed: nil)

        #expect(result.outcome == .proceed(includeMic: false, includeSystemAudio: true))
        #expect(result.probeResult == .captured)
        #expect(probeCallCount() == 1)
    }

    @Test func micGrantedAndKnownGoodSystemAudioSkipsProbe() async throws {
        let (store, probeCallCount) = makeStore(micGranted: true, probeResult: .captured)

        let result = await store.preflight(includeSystemAudio: true, lastTapFailed: false)

        #expect(result.outcome == .proceed(includeMic: true, includeSystemAudio: true))
        #expect(result.probeResult == nil)
        #expect(probeCallCount() == 0)
    }

    @Test func micGrantedAndSystemAudioDisabledSkipsProbe() async throws {
        let (store, probeCallCount) = makeStore(micGranted: true, probeResult: .captured)

        let result = await store.preflight(includeSystemAudio: false, lastTapFailed: nil)

        #expect(result.outcome == .proceed(includeMic: true, includeSystemAudio: false))
        #expect(result.probeResult == nil)
        #expect(probeCallCount() == 0)
    }

    @Test func micGrantedAndProbeFailedProceedsMicOnly() async throws {
        let (store, probeCallCount) = makeStore(micGranted: true, probeResult: .failed("boom"))

        let result = await store.preflight(includeSystemAudio: true, lastTapFailed: true)

        #expect(result.outcome == .proceed(includeMic: true, includeSystemAudio: false))
        #expect(result.probeResult == .failed("boom"))
        #expect(probeCallCount() == 1)
    }

    // MARK: start

    @Test func startWithIncludeMicFalseRunsSystemAudioOnly() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, _) = makeStore()
        let record = makeRecord(in: dir)

        await store.start(record: record, includeSystemAudio: true, includeMic: false)

        #expect(store.isRecording)
        #expect(store.micUnavailable)
        #expect(!store.permissionDenied)

        _ = await store.stop()
    }

    /// The menu bar's elapsed label is plain observable state ticked by the
    /// store — never SwiftUI time machinery, which loops a MenuBarExtra
    /// label at 100% CPU. Guards that the label appears on start and is
    /// cleared on stop.
    @Test func menuBarElapsedLabelSetOnStartClearedOnStop() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, _) = makeStore()
        let record = makeRecord(in: dir)

        #expect(store.menuBarElapsedLabel == nil)
        await store.start(record: record, includeSystemAudio: true, includeMic: true)
        #expect(store.menuBarElapsedLabel == "0:00")

        _ = await store.stop()
        #expect(store.menuBarElapsedLabel == nil)
    }

    /// `currentOffset` is the pause-excluded elapsed time a timed note
    /// captured right now should be pinned to — nil while not recording,
    /// derived from the same `RecordingClock` the pill's timer uses.
    @Test func currentOffsetNilWhileIdleAndNonNilWhileRecording() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, _) = makeStore()
        let record = makeRecord(in: dir)

        #expect(store.currentOffset == nil)
        await store.start(record: record, includeSystemAudio: true, includeMic: true)
        #expect(store.currentOffset != nil)
        #expect(store.currentOffset ?? -1 >= 0)

        _ = await store.stop()
        #expect(store.currentOffset == nil)
    }

    @Test func startMapsAlreadyStartingToStartFailureMessage() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A fake system tap that suspends until manually released lets the
        // first start() call remain "in flight" so a second call races the
        // recorder's re-entrancy guard and observes `.alreadyStarting`.
        let gate = SuspendGate()
        let tap = FakeSystemAudioSource()
        let recorder = MeetingRecorder(
            mic: FakeMicSource(),
            makeSystemTap: { SuspendingSystemAudioSource(gate: gate, wrapped: tap) }
        )
        let store = MeetingSessionStore(
            makeRecorder: { recorder },
            requestMicPermission: { true },
            probeSystemAudio: { .captured }
        )
        let record = makeRecord(in: dir)

        async let first: Void = store.start(record: record, includeSystemAudio: true, includeMic: true)
        // Give the first call a moment to enter the recorder and set its
        // internal `isStarting` flag before the second call races it.
        try await Task.sleep(for: .milliseconds(20))
        await store.start(record: record, includeSystemAudio: true, includeMic: true)

        #expect(store.startFailureMessage == "Already starting a recording")

        gate.release()
        _ = await first
        _ = await store.stop()
    }
}

/// Lets a test hold a fake system-audio source's `start()` suspended until
/// explicitly released, so a second concurrent `MeetingRecorder.start()` can
/// be made to race the first and observe `RecorderError.alreadyStarting`.
@MainActor
private final class SuspendGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class SuspendingSystemAudioSource: SystemAudioCapturing {
    private let gate: SuspendGate
    private let wrapped: FakeSystemAudioSource

    init(gate: SuspendGate, wrapped: FakeSystemAudioSource) {
        self.gate = gate
        self.wrapped = wrapped
    }

    func start() async throws -> AsyncStream<[Float]> {
        await gate.wait()
        return try await wrapped.start()
    }

    func stop() {
        wrapped.stop()
    }
}
