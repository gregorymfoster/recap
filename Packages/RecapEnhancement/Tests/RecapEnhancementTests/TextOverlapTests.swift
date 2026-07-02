import Testing
@testable import RecapEnhancement

@Suite struct TextOverlapTests {
    @Test func restatementScoresHigh() {
        let containment = TextOverlap.containment(
            of: "Engineering wants to move the launch date to September 12.",
            in: "The launch date moves to September 12 so engineering can finish the migration tool."
        )
        #expect(containment >= 0.7)
    }

    @Test func unrelatedFactScoresLow() {
        let containment = TextOverlap.containment(
            of: "Podcast sponsorship will be dropped to save funds.",
            in: "Budget approved at 40k for Q3."
        )
        #expect(containment < 0.3)
    }

    @Test func emptyTextScoresZero() {
        #expect(TextOverlap.containment(of: "", in: "anything at all") == 0)
    }
}
