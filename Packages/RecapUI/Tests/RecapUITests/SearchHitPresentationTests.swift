import RecapCore
import SwiftUI
import Testing
@testable import RecapUI

/// `SearchHitPresentation` — pure row-presentation logic for ⌘K search hits:
/// which source tag to show, and where the match-highlight ranges land
/// inside a snippet (design spec: "Interactions & Behavior" search polish).
@Suite struct SearchHitPresentationTests {
    // MARK: - sourceTag

    @Test func sourceTagIsTitleWhenQueryMatchesTitle() {
        let hit = SearchHit(meetingID: UUID(), title: "Weekly standup", snippet: "…talked about the roadmap…")
        #expect(SearchHitPresentation.sourceTag(for: hit, query: "standup") == "title")
    }

    @Test func sourceTagIsTitleMatchCaseInsensitive() {
        let hit = SearchHit(meetingID: UUID(), title: "Weekly Standup", snippet: "")
        #expect(SearchHitPresentation.sourceTag(for: hit, query: "STANDUP") == "title")
    }

    @Test func sourceTagFallsBackToTranscriptWhenTitleDoesNotMatch() {
        let hit = SearchHit(meetingID: UUID(), title: "Weekly standup", snippet: "…discussed the Q3 budget…")
        #expect(SearchHitPresentation.sourceTag(for: hit, query: "budget") == "transcript")
    }

    @Test func sourceTagFallsBackToTranscriptForEmptyQuery() {
        let hit = SearchHit(meetingID: UUID(), title: "Weekly standup", snippet: "")
        #expect(SearchHitPresentation.sourceTag(for: hit, query: "  ") == "transcript")
    }

    // MARK: - matchRanges

    @Test func matchRangesFindsSingleOccurrence() {
        let ranges = SearchHitPresentation.matchRanges(of: "budget", in: "discussed the Q3 budget review")
        #expect(ranges.count == 1)
    }

    @Test func matchRangesFindsMultipleNonOverlappingOccurrences() {
        let ranges = SearchHitPresentation.matchRanges(of: "cat", in: "cat scat cat")
        // "cat", "scat" (contains "cat"), "cat" — 3 non-overlapping matches.
        #expect(ranges.count == 3)
    }

    @Test func matchRangesIsCaseInsensitive() {
        let ranges = SearchHitPresentation.matchRanges(of: "BUDGET", in: "the budget review")
        #expect(ranges.count == 1)
    }

    @Test func matchRangesIsEmptyWhenNoMatch() {
        let ranges = SearchHitPresentation.matchRanges(of: "zzz", in: "the budget review")
        #expect(ranges.isEmpty)
    }

    @Test func matchRangesIsEmptyForEmptyQuery() {
        let ranges = SearchHitPresentation.matchRanges(of: "", in: "the budget review")
        #expect(ranges.isEmpty)
    }

    // MARK: - highlighted

    @Test @MainActor func highlightedAppliesBackgroundColorToMatch() {
        let attributed = SearchHitPresentation.highlighted("the budget review", matching: "budget", highlight: .yellow)
        let hasHighlight = attributed.runs.contains { $0.backgroundColor != nil }
        #expect(hasHighlight)
    }

    @Test @MainActor func highlightedLeavesTextUnstyledForEmptyQuery() {
        let attributed = SearchHitPresentation.highlighted("the budget review", matching: "", highlight: .yellow)
        let hasHighlight = attributed.runs.contains { $0.backgroundColor != nil }
        #expect(!hasHighlight)
    }

    @Test @MainActor func highlightedPreservesOriginalText() {
        let attributed = SearchHitPresentation.highlighted("the budget review", matching: "budget", highlight: .yellow)
        #expect(String(attributed.characters) == "the budget review")
    }
}
