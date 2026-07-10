import Observation
import RecapCore
import RecapTranscription
import SwiftUI

/// Which top-level screen is showing. Held in the environment so any view
/// (e.g. a "needs model" library chip, the menu bar extra) can navigate
/// without threading bindings. Owned by `AppStores`.
@MainActor
@Observable
public final class AppRouter {
    /// The coarse-grained screen `RootView` renders: the Library list, one
    /// meeting's detail, or the (placeholder, pre-Phase-3C) full-window
    /// recording surface.
    public enum Screen: Equatable, Sendable {
        case library
        case detail(meetingID: UUID)
        case recording
    }

    public var screen: Screen = .library

    /// Preselects a Settings tab the next time the Settings window opens —
    /// set by `-open settings/<tab>` (`LaunchRouteApplier`) and read once by
    /// `SettingsWindowView`'s `.task`, which clears it back to `nil` so a
    /// later manual ⌘, doesn't keep reapplying a stale launch route.
    /// `SettingsWindowView` still drives its tab selection from this today —
    /// the Settings one-page rewrite (Phase 3D) retires it in favor of
    /// `pendingSettingsSection` below.
    public var pendingSettingsTab: SettingsTab?

    /// Settings tab groupings for the redesigned Settings surface. Distinct
    /// from `SettingsTab` (today's tab enum) — later phases reconcile the two.
    public enum SettingsSection: String, Sendable {
        case audio
        case transcription
        case storage

        /// Coarse mapping from today's legacy `SettingsTab` names, wired
        /// alongside `pendingSettingsTab` by `-open settings/<tab>` so the
        /// redesigned Settings surface (Phase 3D) has real routing data to
        /// switch onto once it exists; `SettingsWindowView` doesn't read this
        /// yet.
        public init?(legacyTab: SettingsTab?) {
            guard let legacyTab else { return nil }
            switch legacyTab {
            case .general, .recording, .calendar, .privacy: self = .audio
            case .sync: self = .storage
            }
        }
    }

    /// Preselects a redesigned-Settings section the next time it opens,
    /// mirroring `pendingSettingsTab`'s "set once, consume once" contract.
    public var pendingSettingsSection: SettingsSection?

    public init() {}
}

/// App root: push-style navigation over `router.screen`. Never build stores
/// here — view values re-initialize freely; the graph lives in `AppStores`.
public struct RootView: View {
    private let stores: AppStores
    @State private var showSearch = false
    /// Prefill for the search overlay when opened via `-open search:<query>`.
    @State private var searchQuery = ""
    /// Applies `stores.launchRoute` exactly once. `@State` so it survives
    /// re-invocations of `body` (a plain local `var` wouldn't); seeded from
    /// `stores.launchRoute` in both initializers below.
    @State private var routeApplier: LaunchRouteApplier
    /// Native Settings-window opener (macOS 14+). The legacy
    /// `SettingsOpener.open()` selector hack silently no-ops when invoked
    /// from launch-time `.task` context (no key window / responder chain
    /// yet), so `-open settings[/<tab>]` must use the real action.
    @Environment(\.openSettings) private var openSettings

    private var library: LibraryStore { stores.library }
    private var session: MeetingSessionStore { stores.session }
    private var models: WhisperModelManager { stores.models }
    private var settings: SettingsStore { stores.settings }
    private var queue: QueueStore? { stores.queue }
    private var router: AppRouter { stores.router }

    public init(stores: AppStores) {
        self.stores = stores
        _routeApplier = State(initialValue: LaunchRouteApplier(route: stores.launchRoute))
    }

    /// Injectable root, for previews.
    init(library: LibraryStore) {
        let stores = AppStores(library: library)
        self.stores = stores
        _routeApplier = State(initialValue: LaunchRouteApplier(route: stores.launchRoute))
    }

    public var body: some View {
        screenContent
            // `.contain` forces a dedicated AX container for `root-view` —
            // without it the identifier lands on the child screen's own root
            // element (e.g. LibraryView's ScrollView), overwriting that
            // screen's identifier (`library-list`) in the AX tree.
            .accessibilityElement(children: .contain)
            .axID(.rootView)
            .overlay {
                if showSearch {
                    ZStack(alignment: .top) {
                        Tokens.scrim
                            .ignoresSafeArea()
                            .onTapGesture { showSearch = false }
                        SearchOverlay(isPresented: $showSearch, initialQuery: searchQuery)
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
            // Applies `-open <route>` exactly once (`LaunchRouteApplier` guards
            // repeat `.task` runs), after the store graph above already exists
            // and the main window is up. Must not fight scene restoration —
            // restoration is disabled outright in fixtures/soak
            // (`LaunchConfiguration.restoresWindowState`), and in normal mode a
            // route is only ever present when `-open` was actually passed, so
            // there's nothing here to race against a restored window.
            .task { applyLaunchRouteIfNeeded() }
            .environment(stores)
            .environment(library)
            .environment(session)
            .environment(models)
            .environment(settings)
            .environment(queue)
            .environment(router)
    }

    /// Runs whatever `LaunchRouteAction`s `routeApplier` hands back for
    /// `stores.launchRoute` — a no-op after the first successful call.
    /// `settings/<tab>` is staged on `router.pendingSettingsTab` and the
    /// Settings window opened via the `openSettings` environment action (no
    /// `AppStores` write: `launchRoute` is read-only for this work);
    /// `SettingsWindowView` consumes and clears the staged tab itself.
    private func applyLaunchRouteIfNeeded() {
        let meetingIDs = library.meetings.map { $0.meeting.id.uuidString }
        let actions = routeApplier.applyOnce { rawID in
            LaunchRouteMeetingResolver.resolve(rawID, meetingIDs: meetingIDs)
        }
        for action in actions {
            switch action {
            case .showLibrary:
                router.screen = .library
                library.selectedMeetingID = nil
            case .selectMeeting(let id):
                guard let uuid = UUID(uuidString: id) else { continue }
                router.screen = .detail(meetingID: uuid)
                library.selectedMeetingID = uuid
            case .openSettings(let tab):
                router.pendingSettingsTab = tab
                router.pendingSettingsSection = AppRouter.SettingsSection(legacyTab: tab)
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            case .openSearch(let query):
                searchQuery = query
                showSearch = true
            }
        }
    }

    /// The whole main window's content, driven entirely by `router.screen` —
    /// push-style navigation with no sidebar. `.detail` falls back to
    /// `.library` when the id doesn't resolve to a meeting (e.g. it was just
    /// trashed); `.recording` falls back the same way once the recording
    /// that put it there has ended.
    @ViewBuilder
    private var screenContent: some View {
        switch router.screen {
        case .library:
            LibraryView(showSearch: $showSearch)
        case .detail(let meetingID):
            if let record = library.record(for: meetingID) {
                MeetingDetailView(record: record)
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Button("Library", systemImage: "chevron.left") {
                                library.flushNotes(for: record)
                                router.screen = .library
                                library.selectedMeetingID = nil
                            }
                            .axID(.libraryBackButton)
                        }
                    }
            } else {
                LibraryView(showSearch: $showSearch)
            }
        case .recording:
            if session.activeRecord != nil {
                RecordingView()
            } else {
                LibraryView(showSearch: $showSearch)
            }
        }
    }
}

#Preview("Library") {
    RootView(library: .fixture())
        .frame(width: 1060, height: 660)
}
