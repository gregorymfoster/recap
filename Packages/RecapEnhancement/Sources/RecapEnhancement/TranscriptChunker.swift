import Foundation
import RecapCore

/// Splits a transcript into chunks that fit the on-device model's context
/// window, breaking only on utterance boundaries.
///
/// Token counts are approximated at 4 characters/token — close enough for
/// budgeting, and the budgets leave generous headroom.
enum TranscriptChunker {
    struct Chunk: Equatable {
        var text: String
        var startTime: TimeInterval
        var endTime: TimeInterval
    }

    static func estimatedTokens(_ text: String) -> Int {
        max(1, text.count / 4)
    }

    static func chunk(_ transcript: Transcript, tokenBudget: Int = 2_000) -> [Chunk] {
        var chunks: [Chunk] = []
        var currentLines: [String] = []
        var currentTokens = 0
        var currentStart: TimeInterval = 0
        var currentEnd: TimeInterval = 0

        func flush() {
            guard !currentLines.isEmpty else { return }
            chunks.append(
                Chunk(
                    text: currentLines.joined(separator: "\n"),
                    startTime: currentStart,
                    endTime: currentEnd
                )
            )
            currentLines = []
            currentTokens = 0
        }

        for utterance in transcript.utterances {
            let text = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let tokens = estimatedTokens(text)
            if currentTokens + tokens > tokenBudget {
                flush()
            }
            if currentLines.isEmpty {
                currentStart = utterance.start
            }
            currentLines.append(text)
            currentTokens += tokens
            currentEnd = utterance.end
        }
        flush()
        return chunks
    }
}
