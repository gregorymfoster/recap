import Testing
import RecapCore
@testable import RecapAudio

@Suite struct AudioChunkTests {
    @Test func chunkDurationDerivesFromSampleCount() {
        let chunk = AudioChunk(samples: [Float](repeating: 0, count: 16_000), sampleRate: 16_000, start: 0)
        #expect(chunk.duration == 1.0)
    }
}
