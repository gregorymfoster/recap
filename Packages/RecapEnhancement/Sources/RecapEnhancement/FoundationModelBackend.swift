import Foundation
import FoundationModels

/// The on-device LLM surface, one method per prompt shape. `FoundationModelBackend`
/// is the real implementation, backed by `LanguageModelSession`; tests inject a fake
/// that returns canned responses so the map/merge/reduce orchestration in
/// `FoundationModelEnhancer` can be tested without Apple Intelligence.
protocol EnhancerModel: Sendable {
    var isAvailable: Bool { get }
    func digest(chunkText: String) async throws -> ChunkDigest
    func merge(renderedPair: String) async throws -> ChunkDigest
    func summarize(digestText: String) async throws -> String
    func rewrite(line: String, digestText: String) async throws -> String
    func extraFacts(digestText: String, notesBlock: String) async throws -> [String]
    func subtitle(digestText: String) async throws -> String
}

/// Real on-device model backend. Each method wraps exactly one
/// `LanguageModelSession` call — instructions and generation types are moved
/// here verbatim from the orchestrator; behavior must stay byte-for-byte
/// identical to before this seam existed.
struct FoundationModelBackend: EnhancerModel {
    var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    func digest(chunkText: String) async throws -> ChunkDigest {
        let session = LanguageModelSession(
            instructions: """
            You extract structured facts from a portion of a meeting transcript. \
            Be specific and faithful — never invent details. Prefer fewer, denser points.
            """
        )
        return try await session.respond(
            to: "Transcript portion:\n\n\(chunkText)",
            generating: ChunkDigest.self
        ).content
    }

    func merge(renderedPair: String) async throws -> ChunkDigest {
        let session = LanguageModelSession(
            instructions: """
            You condense meeting summaries. Merge the two digests into one, \
            keeping every decision and action item, deduplicating and tightening key points.
            """
        )
        return try await session.respond(to: renderedPair, generating: ChunkDigest.self).content
    }

    func summarize(digestText: String) async throws -> String {
        let session = LanguageModelSession(
            instructions: """
            You summarize a meeting digest as concise Markdown with a "## Summary" \
            section and, when there are any, an "## Action items" section. State only \
            facts from the digest. Never invent outcomes, reactions, or evaluations. \
            No preamble.
            """
        )
        return try await session.respond(to: "Meeting digest:\n\(digestText)").content
    }

    func rewrite(line: String, digestText: String) async throws -> String {
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
        return try await session.respond(
            to: "Meeting digest:\n\(digestText)\n\nRough note to rewrite:\n\(line)",
            generating: FoundationModelEnhancer.RewrittenLine.self
        ).content.text
    }

    func extraFacts(digestText: String, notesBlock: String) async throws -> [String] {
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
        \(notesBlock)
        """
        return try await session.respond(to: prompt, generating: FoundationModelEnhancer.ExtraFacts.self).content.items
    }

    func subtitle(digestText: String) async throws -> String {
        let session = LanguageModelSession(
            instructions: """
            You write a one-line subtitle for a meeting, from its digest of facts, \
            decisions, and action items.

            Rules: 6-10 words and under 80 characters — when the digest has many \
            items, pick the one or two most important rather than listing them all; \
            a sentence fragment, not a full sentence; no trailing \
            period; name the actual topics, decisions, or outcomes discussed — never \
            generic filler like "Team meeting" or "Weekly sync", and never meta-narration \
            like "This meeting covers..." or "Discussion about...". Never mention the \
            digest, notes, or these instructions.

            Example digest: "- Budget approved at 40k for Q3. - Launch moved to Sept 12."
            Good subtitle: Q3 budget approved, launch date moves to Sept 12
            Bad subtitle: Team meeting about budget and launch (generic, not specific)
            Bad subtitle: This meeting discusses the Q3 budget. (meta-narration, has a period)
            """
        )
        return try await session.respond(
            to: "Meeting digest:\n\(digestText)",
            generating: FoundationModelEnhancer.MeetingSubtitle.self
        ).content.text
    }
}
