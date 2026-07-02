import Testing
@testable import RecapAudio

@Suite struct MixBufferTests {
    @Test func micOnlyModePassesThroughImmediately() {
        var buffer = MixBuffer()
        buffer.systemActive = false
        #expect(buffer.pushMic([0.1, 0.2]) == [0.1, 0.2])
        #expect(buffer.mic.isEmpty)
    }

    @Test func pairwiseDrainMixesEqualLengths() {
        var buffer = MixBuffer()
        #expect(buffer.pushMic([0.1, 0.1, 0.1]).isEmpty)  // system side empty, below threshold
        let mixed = buffer.pushSystem([0.2, 0.2])
        #expect(mixed.count == 2)
        #expect(mixed.allSatisfy { abs($0 - 0.3) < 0.0001 })
        #expect(buffer.mic.count == 1)  // leftover mic sample waits for more system audio
    }

    @Test func starvedSideGetsFlushedAloneAfterThreshold() {
        var buffer = MixBuffer(starvationThreshold: 10)
        #expect(buffer.pushMic([Float](repeating: 0.5, count: 10)).isEmpty)
        let flushed = buffer.pushMic([0.5])
        #expect(flushed.count == 11)
        #expect(buffer.mic.isEmpty)
    }

    @Test func flushRemainderZeroPadsShorterSide() {
        var buffer = MixBuffer()
        _ = buffer.pushMic([0.1, 0.1, 0.1])
        _ = buffer.pushSystem([0.2])
        // drain consumed 1 pair; 2 mic samples remain
        let tail = buffer.flushRemainder()
        #expect(tail.count == 2)
        #expect(tail.allSatisfy { abs($0 - 0.1) < 0.0001 })
        #expect(buffer.mic.isEmpty && buffer.system.isEmpty)
    }

    @Test func downsamplerAveragesGroupsOfThree() {
        #expect(Downsampler3x.downsample([0.0, 0.3, 0.6, 1.0, 1.0, 1.0]) == [0.3, 1.0])
        #expect(Downsampler3x.downsample([0.1, 0.2]).isEmpty)  // partial group dropped
    }
}
