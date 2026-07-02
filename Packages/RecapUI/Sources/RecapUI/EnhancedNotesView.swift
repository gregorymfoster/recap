import SwiftUI

/// Read-only rendering of the enhanced notes Markdown. Handles the subset
/// the enhancer emits: "## " headings, "- "/"* " bullets, and paragraphs,
/// with inline styling via AttributedString.
struct EnhancedNotesView: View {
    var markdown: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(markdown.components(separatedBy: .newlines).enumerated()), id: \.offset) { _, rawLine in
                    let line = rawLine.trimmingCharacters(in: .whitespaces)
                    if line.isEmpty {
                        EmptyView()
                    } else if let heading = strippedPrefix(line, prefixes: ["### ", "## ", "# "]) {
                        Text(inline(heading))
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Tokens.textPrimary)
                            .padding(.top, 8)
                    } else if let bullet = strippedPrefix(line, prefixes: ["- ", "* ", "• "]) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("•")
                                .foregroundStyle(Tokens.textTertiary)
                            Text(inline(bullet))
                                .font(Tokens.body)
                                .lineSpacing(6)
                                .foregroundStyle(Tokens.textBody)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        Text(inline(line))
                            .font(Tokens.body)
                            .lineSpacing(6)
                            .foregroundStyle(Tokens.textBody)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 16)
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
    EnhancedNotesView(markdown: """
    - Maya confirmed the onboarding revision ships at the end of the month after one more round of user testing.
    - Performance regressions on older laptops — Sam follows up with numbers next week.

    ## Also discussed
    - Setup time drops from ten minutes to about three.
    """)
    .frame(width: 560, height: 400)
    .background(.white)
}
