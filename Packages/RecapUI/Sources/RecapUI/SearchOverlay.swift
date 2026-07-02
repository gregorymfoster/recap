import RecapCore
import SwiftUI

/// ⌘K full-text search over the whole library, Spotlight-style.
struct SearchOverlay: View {
    @Environment(LibraryStore.self) private var library
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool

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
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(hit.title)
                                        .font(Tokens.rowTitle)
                                        .foregroundStyle(Tokens.textPrimary)
                                    if !hit.snippet.isEmpty {
                                        Text(hit.snippet)
                                            .font(Tokens.meta)
                                            .foregroundStyle(Tokens.textSecondary)
                                            .lineLimit(2)
                                    }
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
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 320)
            } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Divider()
                Text("No matches")
                    .font(Tokens.meta)
                    .foregroundStyle(Tokens.textTertiary)
                    .padding(18)
            }
        }
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
        .onChange(of: query) {
            hits = library.search(query)
            highlighted = 0
        }
        .onAppear { fieldFocused = true }
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
