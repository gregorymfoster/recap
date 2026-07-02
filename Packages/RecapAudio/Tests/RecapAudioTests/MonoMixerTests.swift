import Testing
@testable import RecapAudio

@Suite struct MonoMixerTests {
    @Test func sumsOverlappingSamples() {
        #expect(MonoMixer.mix([0.1, 0.2], [0.3, 0.1]) == [0.4, 0.3])
    }

    @Test func preservesLongerTail() {
        #expect(MonoMixer.mix([0.5], [0.1, 0.2, 0.3]) == [0.6, 0.2, 0.3])
        #expect(MonoMixer.mix([0.1, 0.2, 0.3], [0.5]) == [0.6, 0.2, 0.3])
    }

    @Test func clampsToUnitRange() {
        let mixed = MonoMixer.mix([0.9, -0.9], [0.9, -0.9])
        #expect(mixed == [1.0, -1.0])
    }

    @Test func emptyInputsPassThrough() {
        #expect(MonoMixer.mix([], [0.1]) == [0.1])
        #expect(MonoMixer.mix([0.1], []) == [0.1])
        #expect(MonoMixer.mix([], []).isEmpty)
    }
}
