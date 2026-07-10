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

        // Map: digest each chunk.
        var digests: [ChunkDigest] = []
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            enhancementLog.info("digest \(index + 1, privacy: .public)/\(chunks.count, privacy: .public)")
            digests.append(DigestSanitizer.sanitize(try await digest(chunkText: chunk.text)))
        }

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
        let raw = try await respondWithRetry {
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

    private func digest(chunkText: String) async throws -> ChunkDigest {
        try await respondWithRetry {
            try await model.digest(chunkText: chunkText)
        }
    }

    private func mergeInPairs(_ digests: [ChunkDigest]) async throws -> [ChunkDigest] {
        var merged: [ChunkDigest] = []
        for pair in stride(from: 0, to: digests.count, by: 2) {
            try Task.checkCancellation()
            if pair + 1 < digests.count {
                let combined = render([digests[pair], digests[pair + 1]])
                merged.append(
                    DigestSanitizer.sanitize(
                        try await respondWithRetry {
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
            let raw = try await respondWithRetry {
                try await model.summarize(digestText: digestText)
            }
            let cleaned = DigestSanitizer.cleanSummaryMarkdown(raw)
            guard !cleaned.isEmpty else { throw EnhancementError.transcriptTooShort }
            return cleaned
        }

        // One call per note line: the code owns the structure, so no line can
        // be dropped or reordered — the model only ever rewrites one line.
        var bullets: [String] = []
        for line in noteLines {
            try Task.checkCancellation()
            bullets.append("- " + (try await rewrite(line: line, digestText: digestText)))
        }

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

    private func rewrite(line: String, digestText: String) async throws -> String {
        let text = try await respondWithRetry {
            try await model.rewrite(line: line, digestText: digestText)
        }
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        // A small model occasionally narrates instead of rewriting; keep the
        // user's own words rather than shipping meta-commentary.
        let lowered = text.lowercased()
        if text.isEmpty || lowered.contains("digest") || lowered.contains("the note") {
            return line
        }
        return text
    }

    private func alsoDiscussed(noteLines: [String], digestText: String) async throws -> [String] {
        let notesBlock = noteLines.map { "- \($0)" }.joined(separator: "\n")
        let items = try await respondWithRetry {
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
    private func respondWithRetry<T>(_ attempt: () async throws -> T) async throws -> T {
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
