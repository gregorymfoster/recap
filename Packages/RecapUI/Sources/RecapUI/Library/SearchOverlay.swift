import RecapCore
import SwiftUI

/// ⌘K full-text search over the whole library, Spotlight-style.
struct SearchOverlay: View {
    @Environment(LibraryStore.self) private var library
    @Binding var isPresented: Bool
    /// Prefills the field when the overlay first appears — set by
    /// `-open search:<query>` (`LaunchRouteApplier`/`RootView`). Only applied
    /// once, in `onAppear`; typing afterwards is untouched by this value.
    var initialQuery: String = ""
    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool

    /// Yellow-tinted match highlight (design spec: `rgba(255,214,10,.3)`).
    /// Not in `Tokens` (no highlight color exists there yet) — scoped locally
    /// since this is the only place it's used.
    private static let matchHighlight = Color(red: 1, green: 0.84, blue: 0.04).opacity(0.3)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Tokens.textTertiary)
                TextField("Search meetings, notes, transcripts…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($fieldFocused)
                    .onSubmit { open(hitAt: highlighted) }
                    .axID(.searchOverlayField)
                Text("esc")
                    .font(Tokens.microLabel)
                    .foregroundStyle(Tokens.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Tokens.chipBackground, in: RoundedRectangle(cornerRadius: 4))
            }
            .padding(14)

            if !hits.isEmpty {
                Divider()
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                            Button {
                                open(hitAt: index)
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(hit.title)
                                            .font(Tokens.rowTitle)
                                            .foregroundStyle(Tokens.textPrimary)
                                        if !hit.snippet.isEmpty {
                                            Text(SearchHitPresentation.highlighted(
                                                hit.snippet, matching: query, highlight: Self.matchHighlight
                                            ))
                                            .font(Tokens.meta)
                                            .foregroundStyle(Tokens.textSecondary)
                                            .lineLimit(2)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    Text(SearchHitPresentation.sourceTag(for: hit, query: query))
                                        .font(Tokens.microLabel)
                                        .foregroundStyle(Tokens.textTertiary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Tokens.chipBackground, in: RoundedRectangle(cornerRadius: Tokens.radiusChip))
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(
                                    index == highlighted ? Tokens.chipBackground : .clear,
                                    in: RoundedRectangle(cornerRadius: Tokens.radiusRow)
                                )
                            }
                            .buttonStyle(.plain)
                            .onHover { if $0 { highlighted = index } }
                            .axID(.searchHitRow(hit.id.uuidString))
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 320)
            } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Divider()
                VStack(spacing: 4) {
                    Text("No matches for \"\(query)\"")
                        .font(Tokens.meta)
                        .foregroundStyle(Tokens.textSecondary)
                    Text("Search covers titles, notes, and transcripts")
                        .font(Tokens.caption)
                        .foregroundStyle(Tokens.textTertiary)
                }
                .padding(18)
            }
        }
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
        .axID(.searchOverlay)
        .onChange(of: query) {
            hits = library.search(query)
            highlighted = 0
        }
        .onAppear {
            fieldFocused = true
            if !initialQuery.isEmpty, query.isEmpty {
                query = initialQuery
            }
        }
        .onExitCommand { isPresented = false }
        .onKeyPress(.downArrow) {
            highlighted = min(highlighted + 1, max(0, hits.count - 1))
            return .handled
        }
        .onKeyPress(.upArrow) {
            highlighted = max(highlighted - 1, 0)
            return .handled
        }
    }

    private func open(hitAt index: Int) {
        guard hits.indices.contains(index) else { return }
        library.selectedMeetingID = hits[index].meetingID
        isPresented = false
    }
}

/// Pure, testable presentation logic for a `SearchHit` row: which source
/// label to show, and where to paint the match highlight inside the snippet.
/// Framework-free (works on plain `String`/`AttributedString`) so it's
/// directly unit-testable without booting a view.
enum SearchHitPresentation {
    /// "title" / "notes" / "transcript" — `SearchHit` itself doesn't carry
    /// which FTS column matched, so this derives the cheapest available
    /// signal: if the query appears in the (already-loaded) title, call it a
    /// title match; otherwise fall back to "transcript" without loading
    /// anything extra per row. "notes" is reachable once/if a hit ever
    /// carries loaded notes text — not the common case today, so it's
    /// handled but never actually selected from `SearchHit` alone.
    static func sourceTag(for hit: SearchHit, query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "transcript" }
        if hit.title.range(of: trimmed, options: .caseInsensitive) != nil {
            return "title"
        }
        return "transcript"
    }

    /// Wraps every case-insensitive occurrence of `query` inside `text` with
    /// a highlight background. Empty/whitespace queries return the text
    /// unstyled (nothing to highlight, and a match on "" would otherwise
    /// highlight every character).
    static func highlighted(_ text: String, matching query: String, highlight: Color) -> AttributedString {
        var attributed = AttributedString(text)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return attributed }
        for range in matchRanges(of: trimmed, in: text) {
            if let attributedRange = Range(range, in: attributed) {
                attributed[attributedRange].backgroundColor = highlight
            }
        }
        return attributed
    }

    /// Every non-overlapping case-insensitive occurrence of `query` in `text`,
    /// as `String`-relative ranges.
    static func matchRanges(of query: String, in text: String) -> [Range<String.Index>] {
        guard !query.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let found = text.range(of: query, options: .caseInsensitive, range: searchStart..<text.endIndex) {
            ranges.append(found)
            searchStart = found.upperBound
        }
        return ranges
    }
}

#Preview("Light") {
    SearchOverlay(isPresented: .constant(true))
        .environment(LibraryStore.fixture())
        .padding(40)
        .background(Tokens.subtleBackground)
}

#Preview("Dark") {
    SearchOverlay(isPresented: .constant(true))
        .environment(LibraryStore.fixture())
        .padding(40)
        .background(Tokens.subtleBackground)
        .preferredColorScheme(.dark)
}
