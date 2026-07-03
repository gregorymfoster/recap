import Foundation

/// Pure word-error-rate scoring for transcription quality evals (M7). No I/O,
/// no models — just string normalization and word-level edit distance, so
/// it's cheap to unit-test and safe to run in normal CI.
public enum WordErrorRate {
    /// Lowercases, strips punctuation, and collapses whitespace so scoring
    /// ignores casing/punctuation differences that don't reflect real
    /// transcription errors (Whisper vs. a hand-typed reference will differ
    /// on commas/periods even when every word matches).
    static func normalize(_ text: String) -> [String] {
        let lowered = text.lowercased()
        let stripped = String(lowered.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) || CharacterSet.whitespaces.contains(scalar)
                ? Character(scalar) : " "
        })
        return stripped.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    }

    /// Word error rate of `hypothesis` against `reference`: the minimum
    /// number of word-level substitutions/insertions/deletions to turn
    /// `hypothesis` into `reference`, divided by `reference`'s word count.
    ///
    /// Returns 0.0 when both normalize to no words (nothing to get wrong).
    /// Returns 1.0 when `reference` has words but `hypothesis` normalizes to
    /// none (matches the deletion-only edit distance, capped at 1.0 isn't
    /// applied — WER can exceed 1.0 when the hypothesis is longer than the
    /// reference and mostly wrong, which is the standard definition).
    public static func wer(reference: String, hypothesis: String) -> Double {
        let refWords = normalize(reference)
        let hypWords = normalize(hypothesis)
        guard !refWords.isEmpty else { return hypWords.isEmpty ? 0.0 : 1.0 }
        let distance = levenshtein(refWords, hypWords)
        return Double(distance) / Double(refWords.count)
    }

    /// Classic word-level Levenshtein distance via a two-row DP table.
    static func levenshtein(_ a: [String], _ b: [String]) -> Int {
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...max(a.count, 1) where a.count > 0 {
            current[0] = i
            for j in 1...max(b.count, 1) where b.count > 0 {
                if a[i - 1] == b[j - 1] {
                    current[j] = previous[j - 1]
                } else {
                    current[j] = 1 + min(previous[j - 1], previous[j], current[j - 1])
                }
            }
            if b.isEmpty { current[0] = i }
            previous = current
        }
        return b.isEmpty ? a.count : previous[b.count]
    }
}
