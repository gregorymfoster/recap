import Testing
@testable import RecapAudio

@Suite struct MixBufferTests {
    @Test func micOnlyModePassesThroughImmediately() {
        var buffer = MixBuffer()
        buffer.systemActive = false
        #expect(buffer.pushMic([0.1, 0.2]) == [0.1, 0.2])
        #expect(buffer.mic.isEmpty)
    }

    @Test func systemOnlyModePassesThroughImmediately() {
        var buffer = MixBuffer()
        buffer.micActive = false
        #expect(buffer.pushSystem([0.1, 0.2]) == [0.1, 0.2])
        #expect(buffer.system.isEmpty)
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

    /// Symmetric to `starvedSideGetsFlushedAloneAfterThreshold`: when the
    /// SYSTEM side is the one backed up (mic has gone quiet instead), it must
    /// flush alone past the threshold exactly the same way. This is the
    /// buffer-level half of the "system audio silently drops out" bug —
    /// the mirror case wasn't previously covered.
    @Test func starvedSystemSideGetsFlushedAloneAfterThreshold() {
        var buffer = MixBuffer(starvationThreshold: 10)
        #expect(buffer.pushSystem([Float](repeating: 0.5, count: 10)).isEmpty)
        let flushed = buffer.pushSystem([0.5])
        #expect(flushed.count == 11)
        #expect(buffer.system.isEmpty)
    }

    /// The flushed-alone branch must route through `MonoMixer.mix` with a
    /// zero-filled counterpart rather than passing the backed-up side through
    /// raw — this keeps the flush path consistent with `flushRemainder` and
    /// applies the same [-1, 1] clamping `mix` guarantees everywhere else.
    @Test func starvedSideFlushIsZeroPaddedThroughMixer() {
        var buffer = MixBuffer(starvationThreshold: 10)
        // Include an out-of-range sample to prove clamping now applies here
        // too, not just a value-preservation check that any implementation
        // would pass.
        let side: [Float] = [Float](repeating: 0.5, count: 10) + [1.5]
        _ = buffer.pushMic(Array(side.dropLast()))
        let flushed = buffer.pushMic([side.last!])
        let expected = MonoMixer.mix(side, [Float](repeating: 0, count: side.count))
        #expect(flushed == expected)
        #expect(flushed.last == 1.0)  // clamped, where raw pass-through would have been 1.5
    }

    /// Regression coverage for the mic/system alignment invariant: a stall
    /// that triggers a starvation flush on one side must not leave a
    /// permanent skew once both sides resume normal paired delivery. Total
    /// frames emitted must exactly track total frames pushed on the leading
    /// side — no samples silently dropped or double-counted across the
    /// stall-then-resume transition.
    @Test func stallThenResumeStaysAlignedAcrossMultipleFlushes() {
        var buffer = MixBuffer(starvationThreshold: 10)
        var totalOut = 0

        // System is silent while mic pushes past threshold — mic backs up
        // and flushes alone.
        totalOut += buffer.pushMic([Float](repeating: 0.2, count: 11)).count
        #expect(buffer.mic.isEmpty)
        #expect(buffer.system.isEmpty)

        // Resume normal paired cadence on both sides for several cycles.
        for _ in 0..<5 {
            totalOut += buffer.pushMic([0.1, 0.1, 0.1]).count
            totalOut += buffer.pushSystem([0.1, 0.1, 0.1]).count
            #expect(buffer.mic.isEmpty)
            #expect(buffer.system.isEmpty)
        }

        let tail = buffer.flushRemainder()
        totalOut += tail.count

        #expect(totalOut == buffer.totalMicSamples)
        #expect(buffer.mic.isEmpty && buffer.system.isEmpty)
    }

    @Test func totalSampleCountsTrackBothSidesIndependently() {
        var buffer = MixBuffer()
        _ = buffer.pushMic([0.1, 0.1, 0.1])
        #expect(buffer.totalMicSamples == 3)
        #expect(buffer.totalSystemSamples == 0)
        _ = buffer.pushSystem([0.2, 0.2])
        #expect(buffer.totalMicSamples == 3)
        #expect(buffer.totalSystemSamples == 2)
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
