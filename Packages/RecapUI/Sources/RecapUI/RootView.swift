import Observation
import RecapCore
import RecapTranscription
import SwiftUI

/// Which top-level section is showing. Held in the environment so any view
/// (e.g. a "needs model" library chip) can navigate without threading bindings.
/// Owned by `AppStores` so the menu bar extra can navigate too.
@MainActor
@Observable
public final class AppRouter {
    public var section: SidebarItem? = .library

    public init() {}
}

/// App root: sidebar navigation + the selected section. Never build stores
/// here — view values re-initialize freely; the graph lives in `AppStores`.
public struct RootView: View {
    private let stores: AppStores
    @State private var showSearch = false

    private var library: LibraryStore { stores.library }
    private var session: MeetingSessionStore { stores.session }
    private var models: WhisperModelManager { stores.models }
    private var settings: SettingsStore { stores.settings }
    private var queue: QueueStore? { stores.queue }
    private var router: AppRouter { stores.router }

    public init(stores: AppStores) {
        self.stores = stores
    }

    /// Injectable root, for previews.
    init(library: LibraryStore) {
        stores = AppStores(library: library)
    }

    public var body: some View {
        @Bindable var router = router
        return NavigationSplitView {
            Sidebar(selection: $router.section)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            detail
        }
        .overlay(alignment: .bottom) {
            if let clock = session.clock {
                RecordingPill(
                    clock: clock, isPaused: session.isPaused,
                    levels: WaveformDownsample.bars(from: session.levels, count: 5),
                    onPauseToggle: { stores.togglePause() },
                    onStop: { stores.stopRecording() }
                )
                .padding(.bottom, 22)
            }
        }
        .overlay {
            if showSearch {
                ZStack(alignment: .top) {
                    Tokens.scrim
                        .ignoresSafeArea()
                        .onTapGesture { showSearch = false }
                    SearchOverlay(isPresented: $showSearch)
                        .padding(.top, 90)
                }
            }
        }
        .overlay(alignment: .bottom) {
            // Lift above the recording pill (~64pt tall + 22pt bottom
            // padding) when one is showing, so the two don't collide — the
            // system-audio-fallback toast fires right as recording starts.
            ToastOverlay(toasts: stores.toasts, bottomInset: session.clock != nil ? 96 : 12)
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
        // A model was installed at launch or just now → finish any recordings
        // parked in `.needsModel`.
        .task { if models.activeModelID != nil { queue?.retryMeetingsAwaitingModel(in: library) } }
        .onChange(of: models.activeModelID) { _, active in
            if active != nil { queue?.retryMeetingsAwaitingModel(in: library) }
        }
        .environment(stores)
        .environment(library)
        .environment(session)
        .environment(models)
        .environment(settings)
        .environment(queue)
        .environment(router)
    }

    @ViewBuilder
    private var detail: some View {
        switch router.section {
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
