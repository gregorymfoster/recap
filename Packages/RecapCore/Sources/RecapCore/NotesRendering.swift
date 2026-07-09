import Foundation

/// Pure rendering of a meeting's raw notes input for enhancement: timed
/// notes (each pinned to an offset into the recording) followed by the
/// freeform notes.md body. Extracted so the combination is unit-testable
/// without `LibraryStorage`/`NoteEnhancer`.
public enum NotesRendering {
    /// Renders `timed` as one `[MM:SS] text` line per note (switching to
    /// `H:MM:SS` once the meeting passes an hour), sorted by offset, then a
    /// blank line, then `freeform` verbatim. Either side may be empty:
    /// - no timed notes → just `freeform` (trimmed).
    /// - no freeform notes → just the timed-note lines (trimmed).
    /// - neither → empty string.
    public static func rawNotes(timed: [TimedNote], freeform: String) -> String {
        let trimmedFreeform = freeform.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !timed.isEmpty else { return trimmedFreeform }

        let lines = timed
            .sorted { $0.offset < $1.offset }
            .map { "[\(timestamp(for: $0.offset))] \($0.text)" }
            .joined(separator: "\n")

        guard !trimmedFreeform.isEmpty else { return lines }
        return "\(lines)\n\n\(trimmedFreeform)"
    }

    private static func timestamp(for offset: TimeInterval) -> String {
        let totalSeconds = max(0, Int(offset.rounded()))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
