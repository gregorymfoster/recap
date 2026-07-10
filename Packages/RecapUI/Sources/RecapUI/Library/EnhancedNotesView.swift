import SwiftUI

/// Read-only rendering of the enhanced notes Markdown. Handles the subset
/// the enhancer emits: "## " headings, "- "/"* " bullets, "- [ ] " checkbox
/// items, and paragraphs, with inline styling via AttributedString. Never
/// shows raw `#`/`-`/`[ ]` markdown — everything renders as real bullets,
/// bold section heads, and checkbox rows (design handoff v2 §8c).
struct EnhancedNotesView: View {
    var markdown: String

    // No longer wraps itself in a `ScrollView` (chunk 3B, meeting-detail
    // redesign): the whole meeting-detail page is one outer `ScrollView`
    // now ("the transcript IS the page"), and this view is laid out inline
    // inside it — nesting a second `ScrollView` here would either break
    // scrolling or clip to an arbitrary height. Callers that still want a
    // bounded, independently-scrolling region can wrap this view in their
    // own `ScrollView`.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(markdown.components(separatedBy: .newlines).enumerated()), id: \.offset) { _, rawLine in
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.isEmpty {
                    EmptyView()
                } else if let heading = strippedPrefix(line, prefixes: ["### ", "## ", "# "]) {
                    Text(inline(heading))
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(Tokens.textPrimary)
                        .tint(Tokens.accentBlue)
                        .padding(.top, 8)
                } else if let item = strippedPrefix(line, prefixes: ["- [ ] ", "- [x] ", "* [ ] ", "* [x] "]) {
                    checkboxRow(checked: line.contains("[x]"), text: item)
                } else if let bullet = strippedPrefix(line, prefixes: ["- ", "* ", "• "]) {
                    bulletRow(bullet)
                } else {
                    Text(inline(line))
                        .font(Tokens.body)
                        .lineSpacing(6)
                        .foregroundStyle(Tokens.textBody)
                        .tint(Tokens.accentBlue)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bulletRow(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("•")
                .foregroundStyle(Tokens.textTertiary)
            Text(inline(text))
                .font(Tokens.body)
                .lineSpacing(6)
                .foregroundStyle(Tokens.textBody)
                .tint(Tokens.accentBlue)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "☐"/"☑" rendered as an 11×11 rounded square rather than raw
    /// `[ ]`/`[x]` markdown, per design handoff v2 §8c action-item rows.
    private func checkboxRow(checked: Bool, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(Tokens.textTertiary, lineWidth: 1.5)
                .background {
                    if checked {
                        RoundedRectangle(cornerRadius: 3).fill(Tokens.accentBlue)
                    }
                }
                .frame(width: 11, height: 11)
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 2 }
            Text(inline(text))
                .font(Tokens.body)
                .lineSpacing(6)
                .foregroundStyle(Tokens.textBody)
                .tint(Tokens.accentBlue)
                .strikethrough(checked, color: Tokens.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func strippedPrefix(_ line: String, prefixes: [String]) -> String? {
        for prefix in prefixes where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return nil
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}

#Preview {
    ScrollView {
        EnhancedNotesView(markdown: """
        ## Updates
        - Maya shipped the Q3 roadmap draft — feedback due **Friday**.
        - Performance regressions on older laptops — Sam follows up with numbers next week.

        ## Action items
        - [ ] Sam pings IT for API access **by EOD**
        - [x] Maya escalates if no response by tomorrow standup
        """)
        .padding(20)
    }
    .frame(width: 560, height: 400)
    .background(Tokens.surface)
}

#Preview("Dark") {
    ScrollView {
        EnhancedNotesView(markdown: """
        ## Updates
        - Maya shipped the Q3 roadmap draft — feedback due **Friday**.
        - Performance regressions on older laptops — Sam follows up with numbers next week.

        ## Action items
        - [ ] Sam pings IT for API access **by EOD**
        - [x] Maya escalates if no response by tomorrow standup
        """)
        .padding(20)
    }
    .frame(width: 560, height: 400)
    .background(Tokens.surface)
    .preferredColorScheme(.dark)
}
