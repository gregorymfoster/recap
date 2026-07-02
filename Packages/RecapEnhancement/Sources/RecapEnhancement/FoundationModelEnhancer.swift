import Foundation
import FoundationModels
import RecapCore

/// What one transcript chunk contributed to the meeting — the "map" step.
@Generable
struct ChunkDigest {
    @Guide(description: "Concrete facts, updates, and specifics discussed, each a short standalone sentence")
    var keyPoints: [String]
    @Guide(description: "Decisions that were made, if any")
    var decisions: [String]
    @Guide(description: "Action items with owner when mentioned, if any")
    var actionItems: [String]
}

/// Enhances rough meeting notes with Apple's on-device language model.
///
/// The ~4k-token context can't hold an hour of transcript, so: chunk on
/// utterance boundaries → digest each chunk (guided generation) → merge
/// digests if there are too many → one final pass that expands the user's
/// notes with digest specifics.
public struct FoundationModelEnhancer: NoteEnhancer {
    public init() {}

    public var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    public func enhance(rawNotes: String, transcript: RecapCore.Transcript) async throws -> String {
        guard isAvailable else { throw EnhancementError.unavailable }

        let chunks = TranscriptChunker.chunk(transcript)
        guard !chunks.isEmpty else { throw EnhancementError.emptyTranscript }

        // Map: digest each chunk.
        var digests: [ChunkDigest] = []
        for chunk in chunks {
            digests.append(try await digest(chunkText: chunk.text))
        }

        // Merge layer: keep the reduce prompt inside the context window.
        while digests.count > 6 {
            digests = try await mergeInPairs(digests)
        }

        return try await reduce(rawNotes: rawNotes, digests: digests)
    }

    // MARK: Map

    private func digest(chunkText: String) async throws -> ChunkDigest {
        let session = LanguageModelSession(
            instructions: """
            You extract structured facts from a portion of a meeting transcript. \
            Be specific and faithful — never invent details. Prefer fewer, denser points.
            """
        )
        return try await respondWithRetry {
            try await session.respond(
                to: "Transcript portion:\n\n\(chunkText)",
                generating: ChunkDigest.self
            ).content
        }
    }

    private func mergeInPairs(_ digests: [ChunkDigest]) async throws -> [ChunkDigest] {
        var merged: [ChunkDigest] = []
        for pair in stride(from: 0, to: digests.count, by: 2) {
            if pair + 1 < digests.count {
                let combined = render([digests[pair], digests[pair + 1]])
                let session = LanguageModelSession(
                    instructions: """
                    You condense meeting summaries. Merge the two digests into one, \
                    keeping every decision and action item, deduplicating and tightening key points.
                    """
                )
                merged.append(
                    try await respondWithRetry {
                        try await session.respond(to: combined, generating: ChunkDigest.self).content
                    }
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
            let session = LanguageModelSession(
                instructions: """
                You summarize a meeting digest as concise Markdown with a "## Summary" \
                section and, when there are any, an "## Action items" section. State only \
                facts from the digest. Never invent outcomes, reactions, or evaluations. \
                No preamble.
                """
            )
            return try await respondWithRetry {
                try await session.respond(to: "Meeting digest:\n\(digestText)").content
            }
        }

        // One call per note line: the code owns the structure, so no line can
        // be dropped or reordered — the model only ever rewrites one line.
        var bullets: [String] = []
        for line in noteLines {
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

    private func rewrite(line: String, digestText: String) async throws -> String {
        let session = LanguageModelSession(
            instructions: """
            You rewrite one rough meeting-note line as ONE clear sentence, using the \
            meeting digest only when it has facts about the note's own topic.

            Example digest: "- Budget approved at 40k for Q3. - Launch moved to Sept 12."
            Note: "budget ok??" → "Budget approved at 40k for Q3."
            Note: "launch date" → "Launch moved to September 12."
            Note: "ask legal re trademark" → "Ask legal about the trademark." \
            (digest says nothing about it, so only the wording is cleaned)

            Rules: one short sentence; keep the user's question marks; never mention the \
            digest or notes themselves; never invent outcomes or reactions; never import \
            digest facts about other topics.
            """
        )
        let response = try await respondWithRetry {
            try await session.respond(
                to: "Meeting digest:\n\(digestText)\n\nRough note to rewrite:\n\(line)",
                generating: RewrittenLine.self
            ).content
        }
        let text = response.text
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
        let session = LanguageModelSession(
            instructions: """
            You compare meeting-digest facts against a user's notes and return only the \
            important digest facts the notes do not mention. Exclude anything the notes \
            already say, even in different words. Return them as short standalone \
            sentences. Return an empty list when the notes already cover everything \
            important. Never invent facts.
            """
        )
        let prompt = """
        Meeting digest:
        \(digestText)

        User's notes:
        \(noteLines.map { "- \($0)" }.joined(separator: "\n"))
        """
        let response = try await respondWithRetry {
            try await session.respond(to: prompt, generating: ExtraFacts.self).content
        }
        return response.items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
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
        } catch {
            do {
                return try await attempt()
            } catch {
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
}

/// Fallback when FoundationModels can't run; also used by unit tests.
public struct UnavailableEnhancer: NoteEnhancer {
    public init() {}

    public var isAvailable: Bool { false }

    public func enhance(rawNotes: String, transcript: RecapCore.Transcript) async throws -> String {
        throw EnhancementError.unavailable
    }
}
