import SwiftUI

/// Pure text logic behind `SummaryDisclosure`'s collapsed-row preview,
/// extracted so it can be unit tested without a view host (house
/// pure-logic-extraction pattern — see `Packages/RecapUI/CLAUDE.md`).
enum SummaryPreview {
    /// The one-line preview shown next to "Summary & notes" while the
    /// disclosure is collapsed: the first meaningful line of the enhanced
    /// summary (skipping headings and blank lines, with list/checkbox
    /// markers stripped), falling back to the first line of the user's own
    /// notes, or `nil` when neither has anything to show.
    static func line(enhancedNotes: String?, notes: String) -> String? {
        if let enhancedNotes, let line = firstMeaningfulLine(in: enhancedNotes) {
            return line
        }
        return firstMeaningfulLine(in: notes)
    }

    /// Same line as `line(enhancedNotes:notes:)`, rendered as inline markdown
    /// (`**bold**`, `_italic_`, etc.) so the collapsed preview never shows
    /// raw emphasis markers — matches `EnhancedNotesView.inline(_:)`, the
    /// house pattern for one-line markdown rendering.
    static func attributedLine(enhancedNotes: String?, notes: String) -> AttributedString? {
        guard let line = line(enhancedNotes: enhancedNotes, notes: notes) else { return nil }
        return (try? AttributedString(markdown: line)) ?? AttributedString(line)
    }

    /// The first non-blank, non-heading line of `markdown`, with leading
    /// bullet/checkbox markers stripped so the preview reads as plain text.
    static func firstMeaningfulLine(in markdown: String) -> String? {
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard !isHeading(line) else { continue }
            return stripListMarkers(line)
        }
        return nil
    }

    private static func isHeading(_ line: String) -> Bool {
        line.hasPrefix("#")
    }

    private static func stripListMarkers(_ line: String) -> String {
        for prefix in ["- [ ] ", "- [x] ", "* [ ] ", "* [x] ", "- ", "* ", "• "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return line
    }
}

/// Collapsed-by-default "Summary & notes" disclosure (design mock 10b/11d):
/// a quiet row with a one-line preview of the enhanced summary; expanding it
/// reveals the read-only enhanced summary (`EnhancedNotesView`) followed by
/// the user's own editable notes. Replaces the old editor|transcript split
/// and the Enhanced/My-notes segmented toggle — both views are visible at
/// once here rather than switched between.
struct SummaryDisclosure: View {
    var enhancedNotes: String?
    @Binding var notes: String
    /// True while this meeting's notes are being enhanced on-device — shows
    /// a quiet inline note above the notes editor when expanded.
    var isEnhancing: Bool = false
    /// Seeds the initial expanded/collapsed state — always `false` in
    /// production (collapsed by default per design mock 10b/11d); `true` is
    /// only used by the "Expanded" preview below.
    var startsExpanded: Bool = false

    @State private var isExpanded: Bool

    init(enhancedNotes: String?, notes: Binding<String>, isEnhancing: Bool = false, startsExpanded: Bool = false) {
        self.enhancedNotes = enhancedNotes
        self._notes = notes
        self.isEnhancing = isEnhancing
        self.startsExpanded = startsExpanded
        self._isExpanded = State(initialValue: startsExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(Tokens.textPrimary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Tokens.hairline, lineWidth: 1)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
                }
                .axID(.summaryDisclosure)

            if isExpanded {
                expandedContent
                    .padding(.top, 12)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Tokens.textPrimary.opacity(0.45))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("Summary & notes")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary.opacity(0.7))
                if !isExpanded, let preview {
                    Text(preview)
                        .font(.system(size: 11))
                        .foregroundStyle(Tokens.textPrimary.opacity(0.35))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var preview: AttributedString? {
        SummaryPreview.attributedLine(enhancedNotes: enhancedNotes, notes: notes)
    }

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let enhancedNotes {
                EnhancedNotesView(markdown: enhancedNotes)
                    .axID(.enhancedNotesView)
            }
            if isEnhancing {
                enhancingNote
            }
            notesEditor
        }
    }

    private var enhancingNote: some View {
        HStack(spacing: 7) {
            ProgressView()
                .controlSize(.small)
            Text("Enhancing your notes from the transcript…")
                .font(.system(size: 11))
                .foregroundStyle(Tokens.accentBlue)
        }
    }

    private var notesEditor: some View {
        TextEditor(text: $notes)
            .accessibilityLabel("Meeting notes")
            .overlay(alignment: .topLeading) {
                if notes.isEmpty {
                    Text("Type rough notes, decisions, or follow-ups…")
                        .font(Tokens.body)
                        .foregroundStyle(Tokens.textTertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .font(Tokens.body)
            .foregroundStyle(Tokens.textBody)
            .lineSpacing(7)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .background(Tokens.chipBackground, in: RoundedRectangle(cornerRadius: Tokens.radiusRow))
            .axID(.notesEditor)
    }
}

#if DEBUG
#Preview("Collapsed") {
    SummaryDisclosure(enhancedNotes: "## Updates\n- Maya shipped the Q3 roadmap draft.", notes: .constant(""))
        .frame(width: 620)
        .padding(20)
        .background(Tokens.surface)
}

#Preview("Expanded") {
    SummaryDisclosureExpandedPreview()
        .frame(width: 620)
        .padding(20)
        .background(Tokens.surface)
}

private struct SummaryDisclosureExpandedPreview: View {
    @State private var notes = "Follow up with Sam about the API access ticket."

    var body: some View {
        SummaryDisclosure(
            enhancedNotes: """
            ## Updates
            - Maya shipped the Q3 roadmap draft — feedback due **Friday**.

            ## Action items
            - [ ] Sam pings IT for API access **by EOD**
            """,
            notes: $notes,
            startsExpanded: true
        )
    }
}
#endif
