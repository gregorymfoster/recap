import Testing
@testable import RecapUI

/// Pure-logic coverage for `SummaryDisclosure`'s collapsed-row preview text
/// (house pure-logic-extraction pattern), no view host needed.
@Suite struct SummaryPreviewTests {
    @Test func prefersFirstMeaningfulLineOfEnhancedNotes() {
        let enhanced = """
        ## Updates
        Maya shipped the Q3 roadmap draft.
        - Sam follows up next week.
        """
        let preview = SummaryPreview.line(enhancedNotes: enhanced, notes: "raw notes should be ignored")
        #expect(preview == "Maya shipped the Q3 roadmap draft.")
    }

    @Test func skipsHeadingsToFindFirstMeaningfulLine() {
        let enhanced = """
        # Meeting title
        ## Section
        The actual first line of content.
        """
        #expect(SummaryPreview.firstMeaningfulLine(in: enhanced) == "The actual first line of content.")
    }

    @Test func stripsBulletAndCheckboxMarkers() {
        #expect(SummaryPreview.firstMeaningfulLine(in: "- Sam pings IT") == "Sam pings IT")
        #expect(SummaryPreview.firstMeaningfulLine(in: "* Sam pings IT") == "Sam pings IT")
        #expect(SummaryPreview.firstMeaningfulLine(in: "- [ ] Follow up with Sam") == "Follow up with Sam")
        #expect(SummaryPreview.firstMeaningfulLine(in: "- [x] Done already") == "Done already")
    }

    @Test func skipsBlankLines() {
        let enhanced = "\n\n   \nReal content here."
        #expect(SummaryPreview.firstMeaningfulLine(in: enhanced) == "Real content here.")
    }

    @Test func fallsBackToUserNotesWhenEnhancedNotesAreNilOrHeadingsOnly() {
        #expect(SummaryPreview.line(enhancedNotes: nil, notes: "Follow up with Sam.") == "Follow up with Sam.")

        let headingsOnly = "## Updates\n### Nothing else"
        #expect(SummaryPreview.line(enhancedNotes: headingsOnly, notes: "Follow up with Sam.") == "Follow up with Sam.")
    }

    @Test func returnsNilWhenNeitherSourceHasContent() {
        #expect(SummaryPreview.line(enhancedNotes: nil, notes: "") == nil)
        #expect(SummaryPreview.line(enhancedNotes: "## Just a heading", notes: "   ") == nil)
    }
}
