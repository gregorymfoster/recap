import Foundation
import Testing
import RecapCore
@testable import RecapEnhancement

/// Fake `EnhancerModel` — an actor so its mutable call counters/recorders are
/// safe to touch from the orchestrator's concurrent-looking `async` calls
/// while staying a clean `Sendable` conformer (no `@unchecked`). Never
/// imports/calls FoundationModels — this is the whole point of the seam.
private actor FakeEnhancerModel: EnhancerModel {
    nonisolated let isAvailable: Bool

    var digestCalls: [String] = []
    var mergeCalls: [String] = []
    var summarizeCalls: [String] = []
    var rewriteCalls: [(line: String, digestText: String)] = []
    var rewriteAllCalls: [(lines: [String], digestText: String)] = []
    var extraFactsCalls: [(digestText: String, notesBlock: String)] = []
    var subtitleCalls: [String] = []

    private var digestImpl: (@Sendable (String) async throws -> ChunkDigest)?
    private var mergeImpl: (@Sendable (String) async throws -> ChunkDigest)?
    private var summarizeImpl: (@Sendable (String) async throws -> String)?
    private var rewriteImpl: (@Sendable (String, String) async throws -> String)?
    private var rewriteAllImpl: (@Sendable ([String], String) async throws -> [String])?
    private var extraFactsImpl: (@Sendable (String, String) async throws -> [String])?
    private var subtitleImpl: (@Sendable (String) async throws -> String)?

    init(
        isAvailable: Bool = true,
        digest: (@Sendable (String) async throws -> ChunkDigest)? = nil,
        merge: (@Sendable (String) async throws -> ChunkDigest)? = nil,
        summarize: (@Sendable (String) async throws -> String)? = nil,
        rewrite: (@Sendable (String, String) async throws -> String)? = nil,
        rewriteAll: (@Sendable ([String], String) async throws -> [String])? = nil,
        extraFacts: (@Sendable (String, String) async throws -> [String])? = nil,
        subtitle: (@Sendable (String) async throws -> String)? = nil
    ) {
        self.isAvailable = isAvailable
        self.digestImpl = digest
        self.mergeImpl = merge
        self.summarizeImpl = summarize
        self.rewriteImpl = rewrite
        self.rewriteAllImpl = rewriteAll
        self.extraFactsImpl = extraFacts
        self.subtitleImpl = subtitle
    }

    func digest(chunkText: String) async throws -> ChunkDigest {
        digestCalls.append(chunkText)
        if let digestImpl {
            return try await digestImpl(chunkText)
        }
        return ChunkDigest(keyPoints: ["point"], decisions: [], actionItems: [])
    }

    func merge(renderedPair: String) async throws -> ChunkDigest {
        mergeCalls.append(renderedPair)
        if let mergeImpl {
            return try await mergeImpl(renderedPair)
        }
        return ChunkDigest(keyPoints: ["merged"], decisions: [], actionItems: [])
    }

    func summarize(digestText: String) async throws -> String {
        summarizeCalls.append(digestText)
        if let summarizeImpl {
            return try await summarizeImpl(digestText)
        }
        return "## Summary\nsummarized"
    }

    func rewrite(line: String, digestText: String) async throws -> String {
        rewriteCalls.append((line, digestText))
        if let rewriteImpl {
            return try await rewriteImpl(line, digestText)
        }
        return line
    }

    /// Default (no explicit `rewriteAll` closure given) delegates to
    /// `rewrite` one line at a time, so existing tests that only configure
    /// `rewrite:` keep exercising the same per-line call recording/behavior
    /// they always have — the batched path is opt-in per test via
    /// `rewriteAll:`.
    func rewriteAll(lines: [String], digestText: String) async throws -> [String] {
        rewriteAllCalls.append((lines, digestText))
        if let rewriteAllImpl {
            return try await rewriteAllImpl(lines, digestText)
        }
        var results: [String] = []
        for line in lines {
            results.append(try await rewrite(line: line, digestText: digestText))
        }
        return results
    }

    func extraFacts(digestText: String, notesBlock: String) async throws -> [String] {
        extraFactsCalls.append((digestText, notesBlock))
        if let extraFactsImpl {
            return try await extraFactsImpl(digestText, notesBlock)
        }
        return []
    }

    func subtitle(digestText: String) async throws -> String {
        subtitleCalls.append(digestText)
        if let subtitleImpl {
            return try await subtitleImpl(digestText)
        }
        return "Fake subtitle about the meeting"
    }
}

@Suite struct EnhancerOrchestrationTests {
    /// 20+ words — clears `FoundationModelEnhancer.minimumTranscriptWords` so
    /// tests that aren't specifically about the short-transcript guard still
    /// exercise the normal map/merge/reduce path.
    private static let longEnoughText = """
    We reviewed the quarterly roadmap today and discussed several open items \
    that need follow-up before the next planning cycle begins in earnest.
    """

    private func transcript(_ texts: [String]) -> Transcript {
        var utterances: [Utterance] = []
        var t: TimeInterval = 0
        for text in texts {
            utterances.append(Utterance(start: t, end: t + 5, text: text))
            t += 5
        }
        return Transcript(utterances: utterances, engine: "test", model: "test", language: "en")
    }

    // MARK: 1. Digest per chunk

    @Test func digestCalledOncePerChunk() async throws {
        // `enhance` chunks internally with the default 2_000-token budget; use
        // enough utterances to force multiple chunks and confirm digest is
        // called exactly once per chunk the real chunker produces.
        let bigUtterance = String(repeating: "word ", count: 1_800) // ~9000 chars ≈ 2250 tokens > 2000 budget alone
        let utterances = Array(repeating: bigUtterance, count: 3)
        let expectedChunks = TranscriptChunker.chunk(transcript(utterances)).count
        #expect(expectedChunks == 3)

        let model = FakeEnhancerModel()
        let enhancer = FoundationModelEnhancer(model: model)
        _ = try await enhancer.enhance(rawNotes: "", transcript: transcript(utterances))
        let calls = await model.digestCalls.count
        #expect(calls == expectedChunks)
    }

    // MARK: 2. Merge loop

    @Test func mergeLoopReducesEightToFour() async throws {
        // Force 8 chunks by using 8 utterances that each exceed a tiny implicit
        // budget isn't controllable from here (TranscriptChunker's 2_000 budget is
        // hardcoded inside `enhance`), so instead we drive mergeInPairs indirectly:
        // craft a transcript with 8 utterances, each large enough to force its own
        // chunk under the real 2_000-token budget (~8000 chars each).
        let bigUtterance = String(repeating: "word ", count: 1_800) // ~9000 chars ≈ 2250 tokens > 2000 budget alone
        let eightUtterances = Array(repeating: bigUtterance, count: 8)
        let expectedChunks = TranscriptChunker.chunk(transcript(eightUtterances)).count
        #expect(expectedChunks == 8)

        let model = FakeEnhancerModel()
        let enhancer = FoundationModelEnhancer(model: model)
        _ = try await enhancer.enhance(rawNotes: "", transcript: transcript(eightUtterances))

        let digestCount = await model.digestCalls.count
        let mergeCount = await model.mergeCalls.count
        #expect(digestCount == 8)
        // 8 -> 4 in one merge pass (4 pairs merged), loop exits since 4 <= 6.
        #expect(mergeCount == 4)
    }

    @Test func mergeLoopCarriesOddTail() async throws {
        // 7 chunks: merge pass produces ceil(7/2) = 4 (3 merged pairs + 1 carried
        // tail unmerged) -> loop exits at 4 (<=6). Expect 3 merge calls (the
        // unpaired tail digest doesn't call merge).
        let bigUtterance = String(repeating: "word ", count: 1_800)
        let sevenUtterances = Array(repeating: bigUtterance, count: 7)
        let expectedChunks = TranscriptChunker.chunk(transcript(sevenUtterances)).count
        #expect(expectedChunks == 7)

        let model = FakeEnhancerModel()
        let enhancer = FoundationModelEnhancer(model: model)
        _ = try await enhancer.enhance(rawNotes: "", transcript: transcript(sevenUtterances))

        let digestCount = await model.digestCalls.count
        let mergeCount = await model.mergeCalls.count
        #expect(digestCount == 7)
        #expect(mergeCount == 3)
    }

    // MARK: 2a. Concurrent digests stay index-ordered

    @Test func chunkDigestsCompleteOutOfOrderButResultsStayIndexOrdered() async throws {
        // Three big-enough utterances force three separate chunks (same trick
        // as the merge tests above), each tagged with a marker so the fake
        // can tell them apart and each given a different completion delay —
        // the earliest chunk finishes last. If ordering were determined by
        // completion time instead of chunk index, "Third" would land first.
        func markedUtterance(_ marker: String) -> String {
            String(repeating: "word ", count: 1_800) + marker
        }
        let utterances = [markedUtterance("MARKER-A"), markedUtterance("MARKER-B"), markedUtterance("MARKER-C")]
        let expectedChunks = TranscriptChunker.chunk(transcript(utterances)).count
        #expect(expectedChunks == 3)

        let model = FakeEnhancerModel(digest: { chunkText in
            if chunkText.contains("MARKER-A") {
                try await Task.sleep(nanoseconds: 40_000_000)
                return ChunkDigest(keyPoints: ["First"], decisions: [], actionItems: [])
            } else if chunkText.contains("MARKER-B") {
                try await Task.sleep(nanoseconds: 20_000_000)
                return ChunkDigest(keyPoints: ["Second"], decisions: [], actionItems: [])
            } else {
                return ChunkDigest(keyPoints: ["Third"], decisions: [], actionItems: [])
            }
        })
        let enhancer = FoundationModelEnhancer(model: model)
        _ = try await enhancer.enhance(rawNotes: "", transcript: transcript(utterances))

        let digestText = try #require(await model.summarizeCalls.first)
        let firstRange = try #require(digestText.range(of: "First"))
        let secondRange = try #require(digestText.range(of: "Second"))
        let thirdRange = try #require(digestText.range(of: "Third"))
        #expect(firstRange.lowerBound < secondRange.lowerBound)
        #expect(secondRange.lowerBound < thirdRange.lowerBound)
    }

    // MARK: 3. Empty notes -> summarize path

    @Test func emptyNotesUsesSummarizePath() async throws {
        let model = FakeEnhancerModel(summarize: { _ in "## Summary\nfinal summary text" })
        let enhancer = FoundationModelEnhancer(model: model)
        let result = try await enhancer.enhance(rawNotes: "   \n  \n", transcript: transcript([Self.longEnoughText]))
        #expect(result.notes == "## Summary\nfinal summary text")
        let summarizeCount = await model.summarizeCalls.count
        let rewriteCount = await model.rewriteCalls.count
        #expect(summarizeCount == 1)
        #expect(rewriteCount == 0)
    }

    // MARK: 4. One bullet per note line, order preserved

    @Test func oneRewriteCallPerNoteLineInOrder() async throws {
        let model = FakeEnhancerModel(rewrite: { line, _ in "Rewritten: \(line)" })
        let enhancer = FoundationModelEnhancer(model: model)
        let rawNotes = "- first line\n\n• second line\nthird line"
        let result = try await enhancer.enhance(rawNotes: rawNotes, transcript: transcript([Self.longEnoughText]))

        let calls = await model.rewriteCalls
        #expect(calls.count == 3)
        #expect(calls.map(\.line) == ["first line", "second line", "third line"])

        let bulletsSection = result.notes.components(separatedBy: "\n\n## Also discussed").first ?? result.notes
        let bullets = bulletsSection.components(separatedBy: "\n")
        #expect(bullets.count == 3)
        #expect(bullets == [
            "- Rewritten: first line",
            "- Rewritten: second line",
            "- Rewritten: third line",
        ])
    }

    // MARK: 4a. Batched rewrite

    @Test func rewriteAllHappyPathIsOneBatchedCallInOrder() async throws {
        let model = FakeEnhancerModel(
            rewriteAll: { lines, _ in lines.map { "Rewritten: \($0)" } }
        )
        let enhancer = FoundationModelEnhancer(model: model)
        let rawNotes = "- first line\n\n• second line\nthird line"
        let result = try await enhancer.enhance(rawNotes: rawNotes, transcript: transcript([Self.longEnoughText]))

        let rewriteAllCalls = await model.rewriteAllCalls
        let rewriteCalls = await model.rewriteCalls.count
        #expect(rewriteAllCalls.count == 1)
        #expect(rewriteAllCalls.first?.lines == ["first line", "second line", "third line"])
        // The per-line path must not run at all on the happy path.
        #expect(rewriteCalls == 0)

        let bulletsSection = result.notes.components(separatedBy: "\n\n## Also discussed").first ?? result.notes
        let bullets = bulletsSection.components(separatedBy: "\n")
        #expect(bullets == [
            "- Rewritten: first line",
            "- Rewritten: second line",
            "- Rewritten: third line",
        ])
    }

    @Test func rewriteAllCountMismatchFallsBackToPerLine() async throws {
        let model = FakeEnhancerModel(
            rewrite: { line, _ in "Rewritten: \(line)" },
            // Drop the last line's output — a structurally unsafe response
            // that must never be trusted.
            rewriteAll: { lines, _ in Array(lines.dropLast()) }
        )
        let enhancer = FoundationModelEnhancer(model: model)
        let rawNotes = "- first line\n- second line\n- third line"
        let result = try await enhancer.enhance(rawNotes: rawNotes, transcript: transcript([Self.longEnoughText]))

        let rewriteAllCalls = await model.rewriteAllCalls.count
        let rewriteCalls = await model.rewriteCalls
        #expect(rewriteAllCalls == 1)
        // Fallback ran the per-line path for every line, in order.
        #expect(rewriteCalls.map(\.line) == ["first line", "second line", "third line"])

        let bulletsSection = result.notes.components(separatedBy: "\n\n## Also discussed").first ?? result.notes
        let bullets = bulletsSection.components(separatedBy: "\n")
        #expect(bullets == [
            "- Rewritten: first line",
            "- Rewritten: second line",
            "- Rewritten: third line",
        ])
    }

    // MARK: 5. Meta-commentary fallback

    @Test(arguments: [
        "The note refers to a budget discussion.",
        "This digest doesn't mention that topic.",
        "",
        "   ",
    ])
    func metaCommentaryFallsBackToOriginalLine(rewriteResponse: String) async throws {
        let model = FakeEnhancerModel(rewrite: { _, _ in rewriteResponse })
        let enhancer = FoundationModelEnhancer(model: model)
        let result = try await enhancer.enhance(rawNotes: "- original line text", transcript: transcript([Self.longEnoughText]))
        #expect(result.notes == "- original line text")
    }

    // MARK: 6. Overlap dedup

    @Test func overlapDedupDropsCoveredExtraFacts() async throws {
        // Content-word containment (>3-char words, minus stopwords, trailing-s
        // folded) must find "Budget approved Q3 launch" >= 0.7 contained in the
        // rewritten bullet below to be dropped; the second extra fact shares no
        // content words with the bullet, so it survives.
        let model = FakeEnhancerModel(
            rewrite: { line, _ in line == "budget" ? "Budget approved launch for Q3 project timeline." : line },
            extraFacts: { _, _ in ["Budget approved launch project.", "Legal review starts Monday morning."] }
        )
        let enhancer = FoundationModelEnhancer(model: model)
        let result = try await enhancer.enhance(rawNotes: "- budget", transcript: transcript([Self.longEnoughText]))

        #expect(result.notes.contains("## Also discussed"))
        #expect(result.notes.contains("Legal review starts Monday morning."))
        #expect(!result.notes.contains("Budget approved launch project."))
    }

    @Test func overlapDedupDropsSectionWhenAllCovered() async throws {
        let model = FakeEnhancerModel(
            rewrite: { line, _ in line == "budget" ? "Budget approved launch for Q3 project timeline." : line },
            extraFacts: { _, _ in ["Budget approved launch project."] }
        )
        let enhancer = FoundationModelEnhancer(model: model)
        let result = try await enhancer.enhance(rawNotes: "- budget", transcript: transcript([Self.longEnoughText]))
        #expect(!result.notes.contains("## Also discussed"))
    }

    // MARK: 7. Retry

    @Test func retrySucceedsOnSecondAttempt() async throws {
        let attemptCount = Counter()
        let model = FakeEnhancerModel(digest: { _ in
            let n = await attemptCount.increment()
            if n == 1 {
                throw TestError.failed
            }
            return ChunkDigest(keyPoints: ["ok"], decisions: [], actionItems: [])
        })
        let enhancer = FoundationModelEnhancer(model: model)
        let result = try await enhancer.enhance(rawNotes: "", transcript: transcript([Self.longEnoughText]))
        #expect(!result.notes.isEmpty)
        let calls = await model.digestCalls.count
        #expect(calls == 2)
    }

    @Test func retryFailsTwiceThrowsGenerationFailed() async throws {
        let model = FakeEnhancerModel(digest: { _ in throw TestError.failed })
        let enhancer = FoundationModelEnhancer(model: model)
        await #expect(throws: EnhancementError.generationFailed) {
            _ = try await enhancer.enhance(rawNotes: "", transcript: transcript([Self.longEnoughText]))
        }
        let calls = await model.digestCalls.count
        #expect(calls == 2)
    }

    // MARK: 8. Unavailable / empty transcript errors

    @Test func unavailableModelThrowsUnavailable() async {
        let model = FakeEnhancerModel(isAvailable: false)
        let enhancer = FoundationModelEnhancer(model: model)
        await #expect(throws: EnhancementError.unavailable) {
            _ = try await enhancer.enhance(rawNotes: "- notes", transcript: transcript([Self.longEnoughText]))
        }
    }

    @Test func emptyTranscriptThrowsEmptyTranscript() async {
        let model = FakeEnhancerModel()
        let enhancer = FoundationModelEnhancer(model: model)
        await #expect(throws: EnhancementError.emptyTranscript) {
            _ = try await enhancer.enhance(rawNotes: "- notes", transcript: transcript([]))
        }
    }

    @Test func shortTranscriptThrowsTranscriptTooShortWithoutCallingModel() async {
        let model = FakeEnhancerModel()
        let enhancer = FoundationModelEnhancer(model: model)
        await #expect(throws: EnhancementError.transcriptTooShort) {
            _ = try await enhancer.enhance(rawNotes: "", transcript: transcript(["Thank you."]))
        }
        let digestCalls = await model.digestCalls.count
        let mergeCalls = await model.mergeCalls.count
        let summarizeCalls = await model.summarizeCalls.count
        let rewriteCalls = await model.rewriteCalls.count
        let subtitleCalls = await model.subtitleCalls.count
        #expect(digestCalls == 0)
        #expect(mergeCalls == 0)
        #expect(summarizeCalls == 0)
        #expect(rewriteCalls == 0)
        #expect(subtitleCalls == 0)
    }

    // MARK: 9a. Digest sanitization

    @Test func allEchoDigestsThrowTranscriptTooShortBeforeSummarize() async throws {
        let model = FakeEnhancerModel(
            digest: { _ in ChunkDigest(keyPoints: ["Response format in json"], decisions: ["Decision:"], actionItems: ["Action:  "]) }
        )
        let enhancer = FoundationModelEnhancer(model: model)
        await #expect(throws: EnhancementError.transcriptTooShort) {
            _ = try await enhancer.enhance(rawNotes: "", transcript: transcript([Self.longEnoughText]))
        }
        let summarizeCalls = await model.summarizeCalls.count
        #expect(summarizeCalls == 0)
    }

    @Test func echoItemsRemovedFromDigestBeforeRender() async throws {
        let model = FakeEnhancerModel(
            digest: { _ in
                ChunkDigest(
                    keyPoints: ["Response format in json", "Real budget fact discussed here"],
                    decisions: ["Decision:"],
                    actionItems: ["Action: follow up with legal team"]
                )
            }
        )
        let enhancer = FoundationModelEnhancer(model: model)
        _ = try await enhancer.enhance(rawNotes: "", transcript: transcript([Self.longEnoughText]))

        let digestText = await model.summarizeCalls.first
        let text = try #require(digestText)
        #expect(text.contains("Real budget fact discussed here"))
        #expect(text.contains("follow up with legal team"))
        #expect(!text.lowercased().contains("response format"))
        #expect(!text.contains("Decision:\n") && !text.contains("- Decision:"))
    }

    @Test func summarizeOutputWithEchoBulletsIsCleaned() async throws {
        let model = FakeEnhancerModel(
            summarize: { _ in
                """
                ## Summary
                - Real fact about the roadmap discussion
                - Decision:
                - Response format in json

                ## Action items
                - Response format in json
                """
            }
        )
        let enhancer = FoundationModelEnhancer(model: model)
        let result = try await enhancer.enhance(rawNotes: "", transcript: transcript([Self.longEnoughText]))
        #expect(result.notes.contains("Real fact about the roadmap discussion"))
        #expect(!result.notes.lowercased().contains("response format"))
        #expect(!result.notes.contains("## Action items"))
    }

    @Test func echoSubtitleYieldsNilSubtitle() async throws {
        let model = FakeEnhancerModel(subtitle: { _ in "Response format in json" })
        let enhancer = FoundationModelEnhancer(model: model)
        let result = try await enhancer.enhance(rawNotes: "", transcript: transcript([Self.longEnoughText]))
        #expect(result.subtitle == nil)
    }

    // MARK: 9. Subtitle

    @Test func subtitleLandsInResultTrimmedAndPeriodStripped() async throws {
        let model = FakeEnhancerModel(subtitle: { _ in "  Q3 budget approved, launch moves to Sept 12. \n" })
        let enhancer = FoundationModelEnhancer(model: model)
        let result = try await enhancer.enhance(rawNotes: "", transcript: transcript([Self.longEnoughText]))
        #expect(result.subtitle == "Q3 budget approved, launch moves to Sept 12")
        let calls = await model.subtitleCalls.count
        #expect(calls == 1)
    }

    @Test func subtitleFailureStillReturnsNotesWithNilSubtitle() async throws {
        let model = FakeEnhancerModel(
            summarize: { _ in "## Summary\nstill here" },
            subtitle: { _ in throw TestError.failed }
        )
        let enhancer = FoundationModelEnhancer(model: model)
        let result = try await enhancer.enhance(rawNotes: "", transcript: transcript([Self.longEnoughText]))
        #expect(result.notes == "## Summary\nstill here")
        #expect(result.subtitle == nil)
        // The retry wrapper gives the subtitle call two attempts before giving up.
        let calls = await model.subtitleCalls.count
        #expect(calls == 2)
    }

    @Test func whitespaceOnlySubtitleBecomesNil() async throws {
        let model = FakeEnhancerModel(subtitle: { _ in " . " })
        let enhancer = FoundationModelEnhancer(model: model)
        let result = try await enhancer.enhance(rawNotes: "", transcript: transcript([Self.longEnoughText]))
        #expect(result.subtitle == nil)
    }
}

private enum TestError: Error {
    case failed
}

/// Small actor to count attempts across retry closures without data races.
private actor Counter {
    private var value = 0
    func increment() -> Int {
        value += 1
        return value
    }
}
