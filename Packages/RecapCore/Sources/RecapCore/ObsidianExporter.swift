import Foundation

/// Writes one Markdown note per meeting into an Obsidian vault folder.
///
/// The vault file is a *copy* — the meeting folder stays the source of
/// truth. Re-exporting the same meeting overwrites its note (filenames are
/// date + title, like the meeting folders).
public struct ObsidianExporter: Sendable {
    public var vaultFolderURL: URL

    public init(vaultFolderURL: URL) {
        self.vaultFolderURL = vaultFolderURL
    }

    /// Renders and writes the note; returns its URL.
    @discardableResult
    public func export(
        _ record: MeetingRecord,
        notes: String?,
        enhanced: String?,
        transcript: Transcript?
    ) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: vaultFolderURL, withIntermediateDirectories: true)
        let url = vaultFolderURL.appendingPathComponent(fileName(for: record.meeting))
        let content = render(record.meeting, notes: notes, enhanced: enhanced, transcript: transcript)
        try Data(content.utf8).write(to: url, options: .atomic)
        return url
    }

    func fileName(for meeting: Meeting) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: meeting.date)
        let prefix = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        // Obsidian rejects these characters in note names.
        let unsafe = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]")
        let title = meeting.title
            .components(separatedBy: unsafe)
            .joined(separator: " ")
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return "\(prefix) \(title.isEmpty ? "Meeting" : title).md"
    }

    func render(
        _ meeting: Meeting,
        notes: String?,
        enhanced: String?,
        transcript: Transcript?
    ) -> String {
        var lines: [String] = ["---"]
        lines.append("date: \(meeting.date.ISO8601Format())")
        if meeting.duration > 0 {
            lines.append("duration: \(Int((meeting.duration / 60).rounded()))m")
        }
        if !meeting.attendees.isEmpty {
            lines.append("attendees:")
            lines += meeting.attendees.map { "  - \"\($0)\"" }
        }
        lines.append("source: recap")
        lines.append("---")
        lines.append("")

        let enhancedText = enhanced?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let notesText = notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !enhancedText.isEmpty {
            lines.append(enhancedText)
        } else if !notesText.isEmpty {
            lines.append(notesText)
        }

        if let transcript, !transcript.utterances.isEmpty {
            lines.append("")
            lines.append("## Transcript")
            lines.append("")
            var currentSpeaker: String?
            for utterance in transcript.utterances {
                if let speaker = utterance.speakerID, speaker != currentSpeaker {
                    currentSpeaker = speaker
                    lines.append("")
                    lines.append("**\(displayName(for: speaker))**")
                }
                lines.append(utterance.text)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func displayName(for speakerID: String) -> String {
        if speakerID.hasPrefix("S"), let number = Int(speakerID.dropFirst()) {
            return "Speaker \(number)"
        }
        return speakerID
    }
}
