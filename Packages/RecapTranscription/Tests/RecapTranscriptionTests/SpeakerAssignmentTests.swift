import Foundation
import RecapCore
import Testing
@testable import RecapTranscription

@Suite struct SpeakerAssignmentTests {
    private func utterance(_ start: TimeInterval, _ end: TimeInterval) -> Utterance {
        Utterance(start: start, end: end, text: "…")
    }

    @Test func assignsDominantSpeakerByOverlap() {
        let turns = [
            SpeakerTurn(speakerID: "S1", start: 0, end: 10),
            SpeakerTurn(speakerID: "S2", start: 10, end: 20),
        ]
        // 3s of S1, 7s of S2 → S2 wins.
        let labeled = SpeakerAssignment.label([utterance(7, 17)], with: turns)
        #expect(labeled[0].speakerID == "S2")
    }

    @Test func noOverlapLeavesSpeakerNil() {
        let turns = [SpeakerTurn(speakerID: "S1", start: 0, end: 5)]
        let labeled = SpeakerAssignment.label([utterance(8, 12)], with: turns)
        #expect(labeled[0].speakerID == nil)
    }

    @Test func emptyTurnsLeaveUtterancesUntouched() {
        let source = [utterance(0, 5)]
        let labeled = SpeakerAssignment.label(source, with: [])
        #expect(labeled == source)
    }

    @Test func renumbersSpeakersByFirstAppearance() {
        // Cluster IDs come back in arbitrary order: "S3" speaks first here.
        let turns = [
            SpeakerTurn(speakerID: "S3", start: 0, end: 10),
            SpeakerTurn(speakerID: "S1", start: 10, end: 20),
        ]
        let labeled = SpeakerAssignment.label([utterance(2, 8), utterance(12, 18)], with: turns)
        #expect(labeled[0].speakerID == "S1")
        #expect(labeled[1].speakerID == "S2")
    }

    @Test func accumulatesOverlapAcrossMultipleTurns() {
        // S1 speaks twice within the utterance (4s total), S2 once (3s).
        let turns = [
            SpeakerTurn(speakerID: "S1", start: 0, end: 2),
            SpeakerTurn(speakerID: "S2", start: 2, end: 5),
            SpeakerTurn(speakerID: "S1", start: 5, end: 7),
        ]
        let labeled = SpeakerAssignment.label([utterance(0, 7)], with: turns)
        #expect(labeled[0].speakerID == "S1")
    }

    @Test func exactTieBreaksDeterministically() {
        let turns = [
            SpeakerTurn(speakerID: "S2", start: 5, end: 10),
            SpeakerTurn(speakerID: "S1", start: 0, end: 5),
        ]
        // 5s each; the lexicographically smaller original ID wins, and it is
        // also the first voice heard, so it renumbers to S1.
        let labeled = SpeakerAssignment.label([utterance(0, 10)], with: turns)
        #expect(labeled[0].speakerID == "S1")
    }

    @Test func preservesUtteranceIdentityAndText() {
        let source = Utterance(start: 0, end: 4, text: "hello")
        let turns = [SpeakerTurn(speakerID: "S1", start: 0, end: 4)]
        let labeled = SpeakerAssignment.label([source], with: turns)
        #expect(labeled[0].id == source.id)
        #expect(labeled[0].text == "hello")
        #expect(labeled[0].start == source.start)
        #expect(labeled[0].end == source.end)
    }
}
