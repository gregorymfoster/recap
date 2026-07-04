import Foundation

/// Strips FoundationModels' occasional self-echo of its own response-format
/// schema out of a `ChunkDigest` (or the freeform `summarize()` Markdown), so
/// a trivial transcript doesn't get amplified into garbage notes/subtitle.
/// Pure and non-public: no framework dependency, tested directly.
enum DigestSanitizer {
    private static let labelPrefixes = ["decision:", "action:"]

    /// True when `item` looks like model self-narration rather than real content:
    /// empty, a short fragment mentioning "response format"/"json", or a bare
    /// "Decision:"/"Action:" label with nothing (or only whitespace/punctuation)
    /// after it. The schema-echo phrase checks only apply to fragment-length
    /// items (≤ 5 words): a real digest fact is a full sentence, and meetings
    /// legitimately discuss JSON ("The API will return data in JSON format").
    static func isEcho(_ item: String) -> Bool {
        let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }

        let lowered = trimmed.lowercased()
        let wordCount = lowered.split(whereSeparator: \.isWhitespace).count
        if wordCount <= 5 {
            if lowered.contains("response format") { return true }
            if lowered == "json" { return true }
            if lowered.contains("in json") { return true }
        }

        for prefix in labelPrefixes where lowered.hasPrefix(prefix) {
            let rest = String(trimmed.dropFirst(prefix.count))
            let restTrimmed = rest.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if restTrimmed.isEmpty { return true }
        }
        return false
    }

    /// Trims each item, strips a redundant leading "Decision:"/"Action:" label
    /// prefix, then drops echo items — for all three digest arrays.
    static func sanitize(_ digest: ChunkDigest) -> ChunkDigest {
        ChunkDigest(
            keyPoints: sanitizeItems(digest.keyPoints),
            decisions: sanitizeItems(digest.decisions),
            actionItems: sanitizeItems(digest.actionItems)
        )
    }

    private static func sanitizeItems(_ items: [String]) -> [String] {
        items.compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let stripped = stripLabelPrefix(trimmed)
            return isEcho(stripped) ? nil : stripped
        }
    }

    private static func stripLabelPrefix(_ text: String) -> String {
        let lowered = text.lowercased()
        for prefix in labelPrefixes where lowered.hasPrefix(prefix) {
            let rest = String(text.dropFirst(prefix.count))
            return rest.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    static func isEmpty(_ digest: ChunkDigest) -> Bool {
        digest.keyPoints.isEmpty && digest.decisions.isEmpty && digest.actionItems.isEmpty
    }

    /// Line-based cleanup of `summarize()`'s freeform Markdown: drops echo
    /// bullets, drops headings left with no surviving content, collapses
    /// runs of 3+ blank lines to one, and trims the result.
    static func cleanSummaryMarkdown(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: .newlines)

        // Pass 1: drop echo bullet lines; keep everything else as-is for now.
        var kept: [String] = []
        for line in lines {
            if let bulletContent = bulletContent(of: line), isEcho(bulletContent) {
                continue
            }
            kept.append(line)
        }

        // Pass 2: drop headings with no surviving non-blank, non-heading
        // content before the next heading (or end of document).
        var result: [String] = []
        var index = 0
        while index < kept.count {
            let line = kept[index]
            if isHeading(line) {
                var j = index + 1
                var hasContent = false
                while j < kept.count, !isHeading(kept[j]) {
                    if !kept[j].trimmingCharacters(in: .whitespaces).isEmpty {
                        hasContent = true
                    }
                    j += 1
                }
                if hasContent {
                    result.append(line)
                }
                index += 1
                continue
            }
            result.append(line)
            index += 1
        }

        // Pass 3: collapse 3+ consecutive blank lines to one.
        var collapsed: [String] = []
        var blankRun = 0
        for line in result {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                blankRun += 1
                if blankRun <= 1 {
                    collapsed.append(line)
                }
            } else {
                blankRun = 0
                collapsed.append(line)
            }
        }

        return collapsed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func bulletContent(of line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "\u{2022} "] {
            if trimmed.hasPrefix(marker) {
                return String(trimmed.dropFirst(marker.count))
            }
        }
        return nil
    }

    private static func isHeading(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("#")
    }
}
