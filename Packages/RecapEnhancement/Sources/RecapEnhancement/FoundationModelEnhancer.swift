import Foundation
import FoundationModels
import os
import RecapCore

private let enhancementLog = Logger(subsystem: "com.gregfoster.recap", category: "Enhancement")

/// What one transcript chunk contributed to the meeting — the "map" step.
@Generable
struct ChunkDigest {
    @Guide(description: "Concrete facts, updates, and specifics discussed, each a short standalone sentence")
    var keyPoints: [String]
    @Guide(description: "Decisions that were made, if any")
    var decisions: [String]
    @Guide(description: "Action items with owner when mentioned, if any")
    var actionItems: [String]

    // The @Generable macro's synthesized memberwise init isn't guaranteed to
    // be usable from test code in another module boundary within this
    // package; add an explicit one so tests can construct fixtures directly.
    init(keyPoints: [String], decisions: [String], actionItems: [String]) {
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
    }
}

/// Enhances rough meeting notes with Apple's on-device language model.
///
/// The ~4k-token context can't hold an hour of transcript, so: chunk on
/// utterance boundaries → digest each chunk (guided generation) → merge
/// digests if there are too many → one final pass that expands the user's
/// notes with digest specifics.
///
/// All LLM calls go through `model` (`EnhancerModel`); this type owns only
/// the map/merge/reduce orchestration around it, so it's testable with a
/// fake model and no Apple Intelligence.
public struct FoundationModelEnhancer: NoteEnhancer {
    /// Below this many whitespace-separated words, a transcript has too
    /// little substance to enhance meaningfully — the on-device model tends
    /// to hallucinate content echoing its own response-format schema instead.
    static let minimumTranscriptWords = 20

    var model: EnhancerModel

    public init() {
        self.model = FoundationModelBackend()
    }

    /// Test seam — production callers use `init()`.
    init(model: EnhancerModel) {
        self.model = model
    }

    public var isAvailable: Bool {
        model.isAvailable
    }

    public func enhance(rawNotes: String, transcript: RecapCore.Transcript) async throws -> EnhancementResult {
        guard isAvailable else { throw EnhancementError.unavailable }

        let chunks = TranscriptChunker.chunk(transcript)
        guard !chunks.isEmpty else { throw EnhancementError.emptyTranscript }

        let wordCount = transcript.utterances.reduce(0) { total, utterance in
            total + utterance.text.split(whereSeparator: \.isWhitespace).count
        }
        guard wordCount >= Self.minimumTranscriptWords else {
            enhancementLog.info("transcript too short: \(wordCount, privacy: .public) word(s)")
            throw EnhancementError.transcriptTooShort
        }

        // Map: digest each chunk. Chunks are independent (fresh session per
        // call, no shared state) so they run concurrently, capped so we don't
        // spawn an unbounded number of tasks for very long meetings.
        var digests = try await digestConcurrently(chunks: chunks)

        // Merge layer: keep the reduce prompt inside the context window.
        var mergeRound = 0
        while digests.count > 6 {
            try Task.checkCancellation()
            mergeRound += 1
            enhancementLog.info("merge round \(mergeRound, privacy: .public): \(digests.count, privacy: .public) digests")
            digests = try await mergeInPairs(digests)
        }

        if digests.allSatisfy(DigestSanitizer.isEmpty) {
            enhancementLog.info("all digests empty after sanitizing")
            throw EnhancementError.transcriptTooShort
        }

        enhancementLog.info("reduce: \(digests.count, privacy: .public) digest(s)")
        let notes = try await reduce(rawNotes: rawNotes, digests: digests)

        // Best-effort: a failed subtitle must never fail enhancement, since the
        // notes themselves are already done at this point.
        let subtitle: String?
        do {
            subtitle = try await generateSubtitle(digests: digests)
        } catch {
            enhancementLog.error("subtitle generation failed")
            subtitle = nil
        }

        return EnhancementResult(notes: notes, subtitle: subtitle)
    }

    // MARK: Subtitle

    /// Returns nil (rather than throwing) when the model's answer trims down
    /// to nothing, so callers only ever see a usable subtitle or none.
    private func generateSubtitle(digests: [ChunkDigest]) async throws -> String? {
        let digestText = render(digests)
        let raw = try await Self.respondWithRetry {
            try await model.subtitle(digestText: digestText)
        }
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(".") {
            trimmed.removeLast()
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if trimmed.isEmpty || DigestSanitizer.isEcho(trimmed) { return nil }
        return trimmed
    }

    // MARK: Map

    /// Maximum number of digest calls in flight at once. The on-device model
    /// may serialize these anyway, but we shouldn't spawn dozens of unbounded
    /// tasks for a long meeting.
    private static let maxConcurrentDigests = 3

    /// Digests every chunk concurrently (each chunk is independent — fresh
    /// session per call, no shared state), then returns results back in
    /// chunk order regardless of completion order, since downstream merge
    /// and "Part N" numbering depend on that order.
    private func digestConcurrently(chunks: [TranscriptChunker.Chunk]) async throws -> [ChunkDigest] {
        let model = self.model
        let total = chunks.count
        var results = [ChunkDigest?](repeating: nil, count: total)
        var nextIndex = 0

        try await withThrowingTaskGroup(of: (Int, ChunkDigest).self) { group in
            func addNext() {
                guard nextIndex < total else { return }
                let index = nextIndex
                let chunkText = chunks[index].text
                nextIndex += 1
                group.addTask {
                    try Task.checkCancellation()
                    enhancementLog.info("digest \(index + 1, privacy: .public)/\(total, privacy: .public)")
                    let raw = try await Self.respondWithRetry {
                        try await model.digest(chunkText: chunkText)
                    }
                    return (index, DigestSanitizer.sanitize(raw))
                }
            }

            for _ in 0..<min(Self.maxConcurrentDigests, total) {
                addNext()
            }
            while let (index, digest) = try await group.next() {
                results[index] = digest
                addNext()
            }
        }

        return results.map { $0! }
    }

    private func mergeInPairs(_ digests: [ChunkDigest]) async throws -> [ChunkDigest] {
        var merged: [ChunkDigest] = []
        for pair in stride(from: 0, to: digests.count, by: 2) {
            try Task.checkCancellation()
            if pair + 1 < digests.count {
                let combined = render([digests[pair], digests[pair + 1]])
                merged.append(
                    DigestSanitizer.sanitize(
                        try await Self.respondWithRetry {
                            try await model.merge(renderedPair: combined)
                        }
                    )
                )
            } else {
                merged.append(digests[pair])
            }
        }
        return merged
    }

    // MARK: Reduce

    private func reduce(rawNotes: String, digests: [ChunkDigest]) async throws -> String {
        // Number the user's note lines so the model can be held to one output
        // bullet per input line — small models drop unnumbered items.
        let noteLines = rawNotes
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t-•*")) }
            .filter { !$0.isEmpty }

        let digestText = render(digests)

        if noteLines.isEmpty {
            let raw = try await Self.respondWithRetry {
                try await model.summarize(digestText: digestText)
            }
            let cleaned = DigestSanitizer.cleanSummaryMarkdown(raw)
            guard !cleaned.isEmpty else { throw EnhancementError.transcriptTooShort }
            return cleaned
        }

        // The code owns the structure, so no line can be dropped or
        // reordered: try one batched call for all note lines, but the model's
        // returned count is never trusted — a count mismatch falls back to
        // the one-call-per-line path, which pairs each output with its input
        // by construction and can't drop or reorder anything.
        let rewrittenLines = try await rewriteAll(lines: noteLines, digestText: digestText)
        let bullets = rewrittenLines.map { "- " + $0 }

        var sections = [bullets.joined(separator: "\n")]
        // Compare against the REWRITTEN bullets: they contain the facts that
        // were merged in, so the model (and the overlap filter below) can see
        // a topic is already covered — the rough lines alone can't show that.
        let rewritten = bullets.map { String($0.dropFirst(2)) }
        let extras = try await alsoDiscussed(noteLines: rewritten, digestText: digestText)
            .filter { extra in
                !rewritten.contains { TextOverlap.containment(of: extra, in: $0) >= 0.7 }
            }
        if !extras.isEmpty {
            sections.append("## Also discussed\n" + extras.map { "- \($0)" }.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    @Generable
    struct RewrittenLine {
        @Guide(description: "The note rewritten as one clear, complete sentence")
        var text: String
    }

    @Generable
    struct ExtraFacts {
        @Guide(description: "Digest facts not covered by any note line; empty if none")
        var items: [String]
    }

    @Generable
    struct MeetingSubtitle {
        @Guide(description: "A concrete, specific one-line meeting subtitle, 6-10 words, sentence fragment, no trailing period")
        var text: String
    }

    @Generable
    struct RewrittenLines {
        @Guide(description: "One rewritten line per numbered input line, in the same order — no additions or omissions")
        var lines: [String]
    }

    /// Rewrites every note line in one batched call when possible, falling
    /// back to the one-call-per-line path if the model's output count
    /// doesn't match the input count — the fallback is what actually
    /// guarantees no line is dropped or reordered; the batched path is only
    /// ever a fast path on top of it.
    private func rewriteAll(lines: [String], digestText: String) async throws -> [String] {
        let raw = try await Self.respondWithRetry {
            try await model.rewriteAll(lines: lines, digestText: digestText)
        }
        guard raw.count == lines.count else {
            enhancementLog.error(
                "rewriteAll returned \(raw.count, privacy: .public) line(s) for \(lines.count, privacy: .public) input(s); falling back to per-line rewrite"
            )
            var bullets: [String] = []
            for line in lines {
                try Task.checkCancellation()
                bullets.append(try await rewrite(line: line, digestText: digestText))
            }
            return bullets
        }
        return zip(lines, raw).map { line, text in Self.postProcessRewrite(original: line, raw: text) }
    }

    private func rewrite(line: String, digestText: String) async throws -> String {
        let raw = try await Self.respondWithRetry {
            try await model.rewrite(line: line, digestText: digestText)
        }
        return Self.postProcessRewrite(original: line, raw: raw)
    }

    /// A small model occasionally narrates instead of rewriting; keep the
    /// user's own words rather than shipping meta-commentary.
    private static func postProcessRewrite(original line: String, raw: String) -> String {
        let text = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = text.lowercased()
        if text.isEmpty || lowered.contains("digest") || lowered.contains("the note") {
            return line
        }
        return text
    }

    private func alsoDiscussed(noteLines: [String], digestText: String) async throws -> [String] {
        let notesBlock = noteLines.map { "- \($0)" }.joined(separator: "\n")
        let items = try await Self.respondWithRetry {
            try await model.extraFacts(digestText: digestText, notesBlock: notesBlock)
        }
        return items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !DigestSanitizer.isEcho($0) }
    }

    private func render(_ digests: [ChunkDigest]) -> String {
        digests.enumerated().map { index, digest in
            var lines = ["Part \(index + 1):"]
            lines += digest.keyPoints.map { "- \($0)" }
            lines += digest.decisions.map { "- Decision: \($0)" }
            lines += digest.actionItems.map { "- Action: \($0)" }
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    /// Meetings can trip safety guardrails; retry once, then surface a typed error.
    /// Static (doesn't touch `self`) so it can be called from concurrent
    /// tasks without capturing the enclosing struct.
    private static func respondWithRetry<T>(_ attempt: () async throws -> T) async throws -> T {
        do {
            return try await attempt()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            enhancementLog.info("retrying after generation failure")
            do {
                return try await attempt()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                enhancementLog.error("generation failed after retry")
                throw EnhancementError.generationFailed
            }
        }
    }
}

public enum EnhancementError: Error, Equatable {
    /// Apple Intelligence is off or unsupported on this Mac — meeting stays transcript-only.
    case unavailable
    case emptyTranscript
    /// The model refused or errored twice; the meeting completes without enhancement.
    case generationFailed
    /// The transcript has too little substance to enhance meaningfully (e.g. a
    /// few-word recording) — the on-device model tends to hallucinate content
    /// echoing its own response-format schema instead of real notes. The
    /// meeting completes transcript-only, same as any other thrown error here.
    case transcriptTooShort
}

/// Fallback when FoundationModels can't run; also used by unit tests.
public struct UnavailableEnhancer: NoteEnhancer {
    public init() {}

    public var isAvailable: Bool { false }

    public func enhance(rawNotes: String, transcript: RecapCore.Transcript) async throws -> EnhancementResult {
        throw EnhancementError.unavailable
    }
}
