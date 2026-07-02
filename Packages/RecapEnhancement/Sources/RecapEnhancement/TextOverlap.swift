import Foundation

/// Cheap redundancy check between generated bullets: content-word containment.
/// Used to drop "Also discussed" items that restate a rewritten note.
enum TextOverlap {
    private static let stopwords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "will", "from", "was", "were",
        "has", "have", "been", "are", "not", "but", "its", "his", "her", "their",
    ]

    static func contentWords(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 3 && !stopwords.contains($0) }
        )
    }

    /// Fraction of `text`'s content words that also appear in `other` (0…1).
    static func containment(of text: String, in other: String) -> Double {
        let words = contentWords(text)
        guard !words.isEmpty else { return 0 }
        return Double(words.intersection(contentWords(other)).count) / Double(words.count)
    }
}
