import Foundation
import RecapCore
import Testing
@testable import RecapUI

/// `TranscriptPlaybackIndex.currentIndex(for:in:)` — the binary search that
/// drives transcript playback-follow highlighting.
@Suite struct TranscriptPlaybackIndexTests {
    private func utterances(starts: [TimeInterval]) -> [Utterance] {
        starts.map { Utterance(start: $0, end: $0 + 4, text: "text") }
    }

    @Test func emptyArrayReturnsNil() {
        #expect(TranscriptPlaybackIndex.currentIndex(for: 5, in: []) == nil)
    }

    @Test func beforeFirstUtteranceReturnsNil() {
        let u = utterances(starts: [10, 20, 30])
        #expect(TranscriptPlaybackIndex.currentIndex(for: 5, in: u) == nil)
    }

    @Test func exactlyAtFirstStartReturnsFirstIndex() {
        let u = utterances(starts: [10, 20, 30])
        #expect(TranscriptPlaybackIndex.currentIndex(for: 10, in: u) == 0)
    }

    @Test func betweenUtterancesReturnsTheLastStartedOne() {
        let u = utterances(starts: [0, 10, 20])
        // 15 is between utterance 1's start (10) and utterance 2's start (20).
        #expect(TranscriptPlaybackIndex.currentIndex(for: 15, in: u) == 1)
    }

    @Test func exactlyAtASubsequentStartMovesForward() {
        let u = utterances(starts: [0, 10, 20])
        #expect(TranscriptPlaybackIndex.currentIndex(for: 20, in: u) == 2)
    }

    @Test func afterLastUtteranceReturnsLastIndex() {
        let u = utterances(starts: [0, 10, 20])
        #expect(TranscriptPlaybackIndex.currentIndex(for: 999, in: u) == 2)
    }

    @Test func singleUtteranceAtItsStart() {
        let u = utterances(starts: [5])
        #expect(TranscriptPlaybackIndex.currentIndex(for: 5, in: u) == 0)
    }

    @Test func singleUtteranceBeforeStart() {
        let u = utterances(starts: [5])
        #expect(TranscriptPlaybackIndex.currentIndex(for: 0, in: u) == nil)
    }

    @Test func manyUtterancesBinarySearchLandsCorrectly() {
        let starts: [TimeInterval] = stride(from: 0, to: 100, by: 5).map { $0 }
        let u = utterances(starts: starts)
        // position 47 -> last start <= 47 is 45, at index 9
        #expect(TranscriptPlaybackIndex.currentIndex(for: 47, in: u) == 9)
    }
}
