import RecapCore
import RecapTranscription
import SwiftUI

/// App root: sidebar navigation + the selected section.
public struct RootView: View {
    @State private var library: LibraryStore
    @State private var session = MeetingSessionStore()
    @State private var models = WhisperModelManager()
    @State private var settings = SettingsStore()
    @State private var queue: QueueStore?
    @State private var sidebarSelection: SidebarItem? = .library
    @State private var showSearch = false

    /// Disk-backed root, used by the app. `-fixtures` swaps in sample data
    /// for UI work and screenshots.
    public init() {
        if ProcessInfo.processInfo.arguments.contains("-fixtures") {
            _library = State(initialValue: .fixture())
            _settings = State(initialValue: .ephemeralOnboarded())
            return
        }
        let settings = SettingsStore()
        let storage = LibraryStorage(rootURL: settings.saveRootURL)
        let index = (try? SearchIndex(databaseURL: SearchIndex.defaultDatabaseURL)) ?? (try! SearchIndex())
        let library = LibraryStore(storage: storage, index: index)
        let models = WhisperModelManager()
        _settings = State(initialValue: settings)
        _library = State(initialValue: library)
        _models = State(initialValue: models)
        _queue = State(initialValue: QueueStore(library: library, storage: storage, models: models))
    }

    /// Injectable root, for previews.
    init(library: LibraryStore) {
        _library = State(initialValue: library)
        _settings = State(initialValue: .ephemeralOnboarded())
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
                    Task {
                        if let (record, duration) = await session.stop() {
                            library.finishRecording(record, duration: duration)
                            queue?.enqueueTranscription(for: record.meeting.id)
                        }
                    }
                }
                .padding(.bottom, 22)
            }
        }
        .overlay {
            if showSearch {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.15)
                        .ignoresSafeArea()
                        .onTapGesture { showSearch = false }
                    SearchOverlay(isPresented: $showSearch)
                        .padding(.top, 90)
                }
            }
        }
        .background {
            // Global ⌘K without a visible control.
            Button("") { showSearch.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
        }
        .sheet(isPresented: .constant(!settings.hasOnboarded)) {
            OnboardingView()
        }
        .environment(library)
        .environment(session)
        .environment(models)
        .environment(settings)
        .environment(queue)
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
            ModelManagerView()
        case .settings:
            SettingsView()
        }
    }
}

#Preview("Library") {
    RootView(library: .fixture())
        .frame(width: 1060, height: 660)
}
