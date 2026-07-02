import Foundation
import Testing
import RecapCore
@testable import RecapEnhancement

@Suite struct TranscriptChunkerTests {
    private func transcript(_ texts: [String]) -> Transcript {
        var utterances: [Utterance] = []
        var t: TimeInterval = 0
        for text in texts {
            utterances.append(Utterance(start: t, end: t + 5, text: text))
            t += 5
        }
        return Transcript(utterances: utterances, engine: "test", model: "test", language: "en")
    }

    @Test func shortTranscriptIsOneChunk() {
        let chunks = TranscriptChunker.chunk(transcript(["Hello.", "Goodbye."]))
        #expect(chunks.count == 1)
        #expect(chunks[0].text == "Hello.\nGoodbye.")
        #expect(chunks[0].startTime == 0)
        #expect(chunks[0].endTime == 10)
    }

    @Test func splitsOnUtteranceBoundariesUnderBudget() {
        // Each utterance ≈ 100 tokens (400 chars); budget of 250 fits two per chunk.
        let utterance = String(repeating: "word ", count: 80)
        let chunks = TranscriptChunker.chunk(
            transcript([utterance, utterance, utterance, utterance, utterance]),
            tokenBudget: 250
        )
        #expect(chunks.count == 3)
        #expect(chunks[0].text.components(separatedBy: "\n").count == 2)
        #expect(chunks[2].text.components(separatedBy: "\n").count == 1)
        // Chunk time ranges stay contiguous with the source utterances.
        #expect(chunks[0].startTime == 0)
        #expect(chunks[1].startTime == 10)
    }

    @Test func emptyAndBlankUtterancesSkipped() {
        let chunks = TranscriptChunker.chunk(transcript(["  ", ""]))
        #expect(chunks.isEmpty)
    }

    @Test func oversizedSingleUtteranceStillEmits() {
        let huge = String(repeating: "a", count: 20_000)
        let chunks = TranscriptChunker.chunk(transcript([huge]), tokenBudget: 100)
        #expect(chunks.count == 1)
    }
}
