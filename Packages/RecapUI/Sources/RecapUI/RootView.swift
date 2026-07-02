import RecapCore
import SwiftUI

/// App root: sidebar navigation + the selected section.
public struct RootView: View {
    @State private var library: LibraryStore
    @State private var session = MeetingSessionStore()
    @State private var sidebarSelection: SidebarItem? = .library

    /// Disk-backed root, used by the app. `-fixtures` swaps in sample data
    /// for UI work and screenshots.
    public init() {
        if ProcessInfo.processInfo.arguments.contains("-fixtures") {
            _library = State(initialValue: .fixture())
            return
        }
        let storage = LibraryStorage(rootURL: LibraryStorage.defaultRootURL)
        let index = (try? SearchIndex(databaseURL: SearchIndex.defaultDatabaseURL)) ?? (try! SearchIndex())
        _library = State(initialValue: LibraryStore(storage: storage, index: index))
    }

    /// Injectable root, for previews.
    init(library: LibraryStore) {
        _library = State(initialValue: library)
    }

    public var body: some View {
        NavigationSplitView {
            Sidebar(selection: $sidebarSelection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            detail
        }
        .overlay(alignment: .bottom) {
            if let startedAt = session.startedAt {
                RecordingPill(startedAt: startedAt, levels: session.levels) {
                    if let (record, duration) = session.stop() {
                        library.finishRecording(record, duration: duration)
                    }
                }
                .padding(.bottom, 22)
            }
        }
        .environment(library)
        .environment(session)
    }

    @ViewBuilder
    private var detail: some View {
        switch sidebarSelection {
        case .library, nil:
            if let id = library.selectedMeetingID, let record = library.record(for: id) {
                MeetingDetailView(record: record)
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Button("Library", systemImage: "chevron.left") {
                                library.flushNotes(for: record)
                                library.selectedMeetingID = nil
                            }
                        }
                    }
            } else {
                LibraryView()
            }
        case .models:
            placeholder("Models", note: "Model manager arrives in M5.")
        case .settings:
            placeholder("Settings", note: "Settings arrive in M9.")
        }
    }

    private func placeholder(_ title: String, note: String) -> some View {
        VStack(spacing: 10) {
            Text(title)
                .font(Tokens.sectionTitle)
                .foregroundStyle(Tokens.textPrimary)
            Text(note)
                .font(Tokens.meta)
                .foregroundStyle(Tokens.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white)
    }
}

#Preview("Library") {
    RootView(library: .fixture())
        .frame(width: 1060, height: 660)
}
