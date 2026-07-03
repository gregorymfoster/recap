import Foundation

/// Renders a transcript as plain text for the clipboard and other exports.
/// One line per utterance: `[m:ss] Speaker 1: text` (speaker omitted when
/// diarization hasn't labeled the utterance). This is the single home for the
/// speaker display-name convention — the transcript UI uses it too, so copied
/// text always matches what's on screen.
public enum TranscriptFormatter {
    public static func plainText(utterances: [Utterance]) -> String {
        utterances.map { utterance in
            let stamp = "[\(timestamp(utterance.start))]"
            if let speakerID = utterance.speakerID {
                return "\(stamp) \(speakerDisplayName(speakerID)): \(utterance.text)"
            }
            return "\(stamp) \(utterance.text)"
        }
        .joined(separator: "\n")
    }

    /// "S1" → "Speaker 1"; unrecognized IDs pass through unchanged.
    public static func speakerDisplayName(_ speakerID: String) -> String {
        if let number = speakerNumber(speakerID) { return "Speaker \(number)" }
        return speakerID
    }

    /// Parses the 1-based speaker index out of an "S<n>" diarization label,
    /// nil for anything else. Shared with the UI's per-speaker coloring.
    public static func speakerNumber(_ speakerID: String) -> Int? {
        guard speakerID.hasPrefix("S") else { return nil }
        return Int(speakerID.dropFirst())
    }

    /// "m:ss", rolling to "h:mm:ss" at the hour mark — mirrors the transcript
    /// pane's timestamp column.
    public static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
