import Testing
@testable import RecapEnhancement

@Suite struct DigestSanitizerTests {
    // MARK: isEcho

    @Test(arguments: [
        "",
        "   ",
        "Response format in json",
        "response format",
        "JSON",
        "json",
        "Format response in JSON",
        "Decision:",
        "Decision: ",
        "decision:  .",
        "Action:",
        "Action:   -",
    ])
    func isEchoDetectsEchoPhrases(item: String) {
        #expect(DigestSanitizer.isEcho(item))
    }

    @Test(arguments: [
        "Budget approved at 40k for Q3.",
        "Decision: budget approved at 40k for Q3.",
        "Action: follow up with legal team.",
        "The launch date moved to September.",
        "The API will return data in JSON format.",
        "Sam reviewed the new response format for the export endpoint.",
    ])
    func isEchoLeavesValidItemsAlone(item: String) {
        #expect(!DigestSanitizer.isEcho(item))
    }

    // MARK: sanitize

    @Test func sanitizeStripsLabelPrefixFromValidDecision() {
        let digest = ChunkDigest(keyPoints: [], decisions: ["Decision: budget approved at 40k"], actionItems: [])
        let sanitized = DigestSanitizer.sanitize(digest)
        #expect(sanitized.decisions == ["budget approved at 40k"])
    }

    @Test func sanitizeStripsLabelPrefixFromValidAction() {
        let digest = ChunkDigest(keyPoints: [], decisions: [], actionItems: ["Action: follow up with legal"])
        let sanitized = DigestSanitizer.sanitize(digest)
        #expect(sanitized.actionItems == ["follow up with legal"])
    }

    @Test func sanitizeDropsEchoItemsAcrossAllArrays() {
        let digest = ChunkDigest(
            keyPoints: ["Response format in json", "Real key point here"],
            decisions: ["Decision:"],
            actionItems: ["Action:  ", "Action: real follow up"]
        )
        let sanitized = DigestSanitizer.sanitize(digest)
        #expect(sanitized.keyPoints == ["Real key point here"])
        #expect(sanitized.decisions.isEmpty)
        #expect(sanitized.actionItems == ["real follow up"])
    }

    @Test func sanitizeTrimsWhitespace() {
        let digest = ChunkDigest(keyPoints: ["  spaced out point  "], decisions: [], actionItems: [])
        let sanitized = DigestSanitizer.sanitize(digest)
        #expect(sanitized.keyPoints == ["spaced out point"])
    }

    // MARK: isEmpty

    @Test func isEmptyTrueWhenAllArraysEmpty() {
        let digest = ChunkDigest(keyPoints: [], decisions: [], actionItems: [])
        #expect(DigestSanitizer.isEmpty(digest))
    }

    @Test func isEmptyFalseWhenAnyArrayHasContent() {
        #expect(!DigestSanitizer.isEmpty(ChunkDigest(keyPoints: ["a"], decisions: [], actionItems: [])))
        #expect(!DigestSanitizer.isEmpty(ChunkDigest(keyPoints: [], decisions: ["a"], actionItems: [])))
        #expect(!DigestSanitizer.isEmpty(ChunkDigest(keyPoints: [], decisions: [], actionItems: ["a"])))
    }

    // MARK: cleanSummaryMarkdown

    @Test func cleanSummaryMarkdownDropsDecisionBullet() {
        let input = """
        ## Summary
        - Real fact about the project
        - Decision:
        """
        let cleaned = DigestSanitizer.cleanSummaryMarkdown(input)
        #expect(cleaned.contains("Real fact about the project"))
        #expect(!cleaned.contains("Decision:"))
    }

    @Test func cleanSummaryMarkdownDropsResponseFormatBullet() {
        let input = """
        ## Summary
        - Response format in json
        - Real fact here
        """
        let cleaned = DigestSanitizer.cleanSummaryMarkdown(input)
        #expect(!cleaned.lowercased().contains("response format"))
        #expect(cleaned.contains("Real fact here"))
    }

    @Test func cleanSummaryMarkdownDropsHeadingWithNoSurvivingContent() {
        let input = """
        ## Summary
        - Real fact about the project

        ## Action items
        - Response format in json
        - Decision:
        """
        let cleaned = DigestSanitizer.cleanSummaryMarkdown(input)
        #expect(cleaned.contains("## Summary"))
        #expect(!cleaned.contains("## Action items"))
    }

    @Test func cleanSummaryMarkdownKeepsValidSections() {
        let input = """
        ## Summary
        - Real fact about the project

        ## Action items
        - Follow up with legal team
        """
        let cleaned = DigestSanitizer.cleanSummaryMarkdown(input)
        #expect(cleaned.contains("## Summary"))
        #expect(cleaned.contains("## Action items"))
        #expect(cleaned.contains("Follow up with legal team"))
    }

    @Test func cleanSummaryMarkdownCollapsesBlankLines() {
        let input = "Line one.\n\n\n\n\nLine two."
        let cleaned = DigestSanitizer.cleanSummaryMarkdown(input)
        #expect(cleaned == "Line one.\n\nLine two.")
    }

    @Test func cleanSummaryMarkdownTrimsResult() {
        let input = "\n\n  ## Summary\n- Real fact.\n\n  "
        let cleaned = DigestSanitizer.cleanSummaryMarkdown(input)
        #expect(cleaned == "## Summary\n- Real fact.")
    }

    @Test func cleanSummaryMarkdownAllEchoYieldsEmptyResult() {
        let input = """
        ## Summary
        - Response format in json

        ## Action items
        - Decision:
        """
        let cleaned = DigestSanitizer.cleanSummaryMarkdown(input)
        #expect(cleaned.isEmpty)
    }
}
