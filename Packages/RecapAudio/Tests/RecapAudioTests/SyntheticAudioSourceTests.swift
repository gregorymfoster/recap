import Foundation
import Testing
@testable import RecapAudio

/// Fast sanity checks for the soak-test-only synthetic sources: they must
/// actually produce buffers and stop cleanly, without needing real time to
/// elapse for the assertions to hold.
@MainActor
@Suite struct SyntheticAudioSourceTests {
    @Test func micSourceYieldsABufferThenFinishesOnStop() async throws {
        let source = SyntheticMicSource()
        #expect(source.activeDeviceName == "Synthetic (soak)")
        let stream = try source.start()

        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first != nil)
        #expect(first?.isEmpty == false)
        #expect(first?.allSatisfy { $0 == 0 } == true)

        source.stop()
        // Draining the rest of the stream must terminate promptly.
        let drained = await withTimeout(seconds: 2) {
            for await _ in stream {}
            return true
        }
        #expect(drained == true)
    }

    @Test func systemAudioSourceYieldsABufferThenFinishesOnStop() async throws {
        let source = SyntheticSystemAudioSource()
        let stream = try await source.start()

        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first != nil)
        #expect(first?.isEmpty == false)

        source.stop()
        let drained = await withTimeout(seconds: 2) {
            for await _ in stream {}
            return true
        }
        #expect(drained == true)
    }
}

/// Races `operation` against a timeout so a stream that fails to finish
/// after `stop()` fails the test instead of hanging the suite.
private func withTimeout(seconds: Double, operation: @escaping @Sendable () async -> Bool) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return false
        }
        let result = await group.next() ?? false
        group.cancelAll()
        return result
    }
}
