import Testing
@testable import RecapTranscription

@Suite struct StreamingPassTests {
    @Test func confirmsAllButTrailingSegment() {
        let outcome = StreamingPass.process(
            segments: [
                .init(start: 0, end: 3, text: " Hello everyone."),
                .init(start: 3, end: 6, text: "Let's get started."),
                .init(start: 6, end: 8, text: "Today we"),
            ],
            bufferStart: 10,
            bufferSampleCount: 8 * 16_000,
            sampleRate: 16_000
        )
        #expect(outcome.confirmed.map(\.text) == ["Hello everyone.", "Let's get started."])
        #expect(outcome.confirmed.map(\.start) == [10, 13])  // buffer offset applied
        #expect(outcome.partial?.text == "Today we")
        #expect(outcome.partial?.start == 16)
        #expect(outcome.trimSamples == 6 * 16_000)  // trailing segment stays in the buffer
    }

    @Test func singleSegmentStaysPartial() {
        let outcome = StreamingPass.process(
            segments: [.init(start: 0.5, end: 2, text: "Testing")],
            bufferStart: 0,
            bufferSampleCount: 2 * 16_000,
            sampleRate: 16_000
        )
        #expect(outcome.confirmed.isEmpty)
        #expect(outcome.partial?.text == "Testing")
        #expect(outcome.trimSamples == 8_000)
    }

    @Test func emptyAndWhitespaceSegmentsIgnored() {
        let outcome = StreamingPass.process(
            segments: [.init(start: 0, end: 1, text: "  ")],
            bufferStart: 0,
            bufferSampleCount: 16_000,
            sampleRate: 16_000
        )
        #expect(outcome.confirmed.isEmpty)
        #expect(outcome.partial == nil)
        #expect(outcome.trimSamples == 0)
    }

    @Test func trimNeverExceedsBuffer() {
        let outcome = StreamingPass.process(
            segments: [.init(start: 100, end: 101, text: "clock skew")],
            bufferStart: 0,
            bufferSampleCount: 16_000,
            sampleRate: 16_000
        )
        #expect(outcome.trimSamples == 16_000)
    }

    @Test func overflowDropZeroWhenUnderMax() {
        #expect(StreamingPass.overflowDrop(bufferCount: 10, maxBuffer: 30) == 0)
        #expect(StreamingPass.overflowDrop(bufferCount: 30, maxBuffer: 30) == 0)
    }

    @Test func overflowDropExactAmountWhenOver() {
        #expect(StreamingPass.overflowDrop(bufferCount: 45, maxBuffer: 30) == 15)
    }

    @Test func overflowDropCapsMonologueBufferAcrossPasses() {
        // Simulates a continuous monologue: every pass, Whisper returns one long segment whose
        // start stays ~0, so `trimSamples` alone makes no progress. The buffer should still
        // never exceed `maxBuffer` once the unconditional clamp is applied.
        let maxBuffer = 30 * 16_000
        let passStride = 4 * 16_000
        var bufferCount = 0
        for _ in 0..<20 {
            bufferCount += passStride
            let outcome = StreamingPass.process(
                segments: [.init(start: 0, end: Double(bufferCount) / 16_000, text: "still talking")],
                bufferStart: 0,
                bufferSampleCount: bufferCount,
                sampleRate: 16_000
            )
            bufferCount -= outcome.trimSamples
            bufferCount -= StreamingPass.overflowDrop(bufferCount: bufferCount, maxBuffer: maxBuffer)
            #expect(bufferCount <= maxBuffer)
        }
    }
}
