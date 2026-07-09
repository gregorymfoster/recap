import Foundation
import Testing
@testable import RecapCore

@Suite struct TranscriptMergeTests {
    private func utterance(_ start: TimeInterval) -> Utterance {
        Utterance(start: start, end: start + 1, text: "…")
    }

    private func note(_ offset: TimeInterval, _ text: String = "note") -> TimedNote {
        TimedNote(offset: offset, text: text)
    }

    @Test func emptyBothSidesReturnsEmpty() {
        #expect(TranscriptMerge.merged(utterances: [], notes: []) == [])
    }

    @Test func emptyNotesReturnsUtterancesInOrder() {
        let utterances = [utterance(0), utterance(5), utterance(10)]
        let merged = TranscriptMerge.merged(utterances: utterances, notes: [])
        #expect(merged == utterances.map(TranscriptMerge.Item.utterance))
    }

    @Test func emptyUtterancesReturnsNotesInOrder() {
        let notes = [note(0), note(5)]
        let merged = TranscriptMerge.merged(utterances: [], notes: notes)
        #expect(merged == notes.map(TranscriptMerge.Item.note))
    }

    @Test func interleavesByTime() {
        let u1 = utterance(0)
        let u2 = utterance(10)
        let n = note(5)
        let merged = TranscriptMerge.merged(utterances: [u1, u2], notes: [n])
        #expect(merged == [.utterance(u1), .note(n), .utterance(u2)])
    }

    @Test func tieSortsNoteBeforeUtterance() {
        let u = utterance(5)
        let n = note(5)
        let merged = TranscriptMerge.merged(utterances: [u], notes: [n])
        #expect(merged == [.note(n), .utterance(u)])
    }

    @Test func trailingNoteAfterLastUtteranceAppendsAtEnd() {
        let u = utterance(0)
        let n = note(100)
        let merged = TranscriptMerge.merged(utterances: [u], notes: [n])
        #expect(merged == [.utterance(u), .note(n)])
    }

    @Test func leadingNoteBeforeFirstUtteranceSortsFirst() {
        let u = utterance(10)
        let n = note(0)
        let merged = TranscriptMerge.merged(utterances: [u], notes: [n])
        #expect(merged == [.note(n), .utterance(u)])
    }
}
