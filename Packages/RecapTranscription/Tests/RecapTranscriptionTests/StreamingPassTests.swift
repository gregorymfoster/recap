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
}
