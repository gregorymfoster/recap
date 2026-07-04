import AppKit
import RecapCore
import RecapUI
import Sparkle
import SwiftUI
import UniformTypeIdentifiers

@main
struct RecapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// The app-lifetime store graph — the App struct persists for the whole
    /// process, so this is constructed exactly once.
    @State private var stores: AppStores

    /// Owns Sparkle and drives the in-app "update available" indicator
    /// (`stores.updateStatus`). `nil` in dev builds — a dev build must never
    /// update itself into the prod app, so Sparkle isn't even constructed.
    private let updater: UpdaterModel?

    /// Owns the Granola-style floating recording capsule shown while
    /// recording and Recap is backgrounded. Same `AppStores`/session wiring
    /// as prod — no dev-build special-casing needed.
    private let floatingIndicator: FloatingIndicatorController

    /// Backs the Settings window's launch-at-login toggle (a thin
    /// `SMAppService` wrapper with no shared state).
    private let launchAtLogin = LaunchAtLoginController()

    init() {
        let stores = AppStores()
        _stores = State(initialValue: stores)
        updater = AppIdentity.isDevBuild ? nil : UpdaterModel(status: stores.updateStatus)
        floatingIndicator = FloatingIndicatorController(stores: stores)
        // The delegate adaptor is created before any @State is readable from
        // it, so hand the graph over through a static hook; the delegate
        // buffers any file-open events that arrive first.
        AppDelegate.stores = stores
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView(stores: stores)
                .frame(minWidth: 800, minHeight: 500)
                .modifier(MenuBarContentDebugOpener())
        }
        .defaultSize(width: 1060, height: 660)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                if let updater {
                    CheckForUpdatesView(updater: updater.updater)
                }
            }
            CommandGroup(after: .newItem) {
                Button("Import Audio…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.audio]
                    panel.allowsMultipleSelection = true
                    panel.canChooseDirectories = false
                    panel.message = "Choose audio files to import into your library"
                    if panel.runModal() == .OK {
                        stores.importAudioFiles(panel.urls)
                    }
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }

        // Native ⌘, Settings window (design handoff 7c) — toolbar icon tabs,
        // window title tracks the active tab. Injects the same environment
        // values `RootView` provides, since the tabs read stores the same way.
        Settings {
            SettingsWindowView()
                .environment(stores)
                .environment(stores.library)
                .environment(stores.session)
                .environment(stores.models)
                .environment(stores.settings)
                .environment(stores.queue)
                .environment(stores.router)
                .environment(launchAtLogin)
        }

        MenuBarExtra {
            MenuBarContent(stores: stores)
        } label: {
            MenuBarLabel(stores: stores)
        }
        // Rich popover content (design handoff 8a) — `.menu` style can't
        // render the header block, progress rows, or quick actions.
        .menuBarExtraStyle(.window)

        // Debug hook (like `-fixtures`/`-soak`): the menu bar extra's popover
        // normally lives in the status-item overflow, which screen capture
        // and UI-automation tooling can't reach headlessly. This auxiliary,
        // non-resizable window hosts the same `MenuBarContent` view so its
        // idle/recording states can be screenshotted like any other window.
        // `SceneBuilder` doesn't support an `if` here (control flow inside a
        // scene builder isn't just unsupported, it currently ICEs the
        // compiler — confirmed by isolated repro), so the scene is always
        // declared but launch-suppressed; `MenuBarContentDebugOpener` below
        // opens it explicitly only when `-show-menubar-content` is passed
        // (documented in CLAUDE.md's "Run the app with fixture data" section).
        Window("Menu Bar Content", id: "menubar-content-debug") {
            MenuBarContentDebugView(stores: stores)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        // Debug hook for the "Meeting started?" nudge (design mock 9b),
        // opened the same way as `-show-menubar-content` above: the real
        // panel is a borderless, non-activating, all-spaces `NSPanel` that
        // headless screenshot tooling can't reliably find, so this stacks
        // all three content variants in an ordinary window instead. Pure
        // view hosting — no `MeetingNudgePanelController`, no
        // `MeetingNudgeCenter` — so nothing here can misfire a real nudge.
        Window("Nudge Preview", id: "nudge-preview-debug") {
            NudgePreviewDebugView()
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

/// Content view for the `-show-menubar-content` debug window.
private struct MenuBarContentDebugView: View {
    let stores: AppStores

    var body: some View {
        MenuBarContent(stores: stores)
            .background(Tokens.surface)
    }
}

/// Opens the (launch-suppressed) menu-bar-content debug window at launch when
/// `-show-menubar-content` is passed. Lives on `RootView`'s window rather
/// than the debug window's own body, since `openWindow` needs a scene that's
/// actually created to call from — the suppressed window's own content view
/// never runs its body until something opens it.
struct MenuBarContentDebugOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.task {
            if ProcessInfo.processInfo.arguments.contains("-show-menubar-content") {
                openWindow(id: "menubar-content-debug")
            }
            if ProcessInfo.processInfo.arguments.contains("-fixtures"),
                ProcessInfo.processInfo.arguments.contains("-show-nudge")
            {
                openWindow(id: "nudge-preview-debug")
            }
        }
    }
}

/// Content view for the `-fixtures -show-nudge` debug window: stacks all
/// three `MeetingNudgeView` variants (ask with a calendar match, ask
/// app-only, and the auto-record confirmation) so the fixture app can
/// screenshot every state of design mock 9b in one shot.
private struct NudgePreviewDebugView: View {
    private static let now = Date.now

    private static let matchedEvent = CalendarEventSnapshot(
        id: "nudge-preview-match",
        title: "Design crit — mobile",
        start: now.addingTimeInterval(-30),
        end: now.addingTimeInterval(30 * 60),
        otherAttendees: ["Maya Chen", "Priya Patel"],
        hasConferenceURL: true,
        conferenceProvider: "Zoom"
    )

    private static let recordingEvent = CalendarEventSnapshot(
        id: "nudge-preview-recording",
        title: "Roadmap review",
        start: now.addingTimeInterval(-40),
        end: now.addingTimeInterval(20 * 60),
        otherAttendees: ["Jordan Lee"],
        hasConferenceURL: true,
        conferenceProvider: "Zoom"
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            MeetingNudgeView(
                nudge: .ask(appID: "us.zoom.xos", appName: "Zoom", match: Self.matchedEvent),
                onRecord: {}, onNotNow: {}, onDontAsk: {}
            )
            MeetingNudgeView(
                nudge: .ask(appID: "com.microsoft.teams2", appName: "Microsoft Teams", match: nil),
                onRecord: {}, onNotNow: {}, onDontAsk: {}
            )
            MeetingNudgeView(
                nudge: .recordingStarted(event: Self.recordingEvent, missedSeconds: 40),
                onRecord: {}, onNotNow: {}, onStop: {}
            )
        }
        .padding(24)
        .background(Tokens.surface)
    }
}

/// Receives Finder "Open With" file-open events — SwiftUI's `onOpenURL`
/// never sees file opens on macOS, so this needs a real app delegate. The
/// adaptor instantiates it before the App struct's stores are reachable, so
/// the graph arrives via the static hook (set in `RecapApp.init`) and any
/// URLs delivered before then are buffered.
///
/// Also owns the ⌘Q-while-recording guard (design spec 8f): quitting mid-
/// recording must never silently drop audio, so termination is intercepted,
/// confirmed with a native alert, and only proceeds after the normal
/// stop-and-save flow has finished.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var stores: AppStores? {
        didSet { flushPending() }
    }
    private static var pendingURLs: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        Self.pendingURLs.append(contentsOf: urls)
        Self.flushPending()
    }

    private static func flushPending() {
        guard let stores, !pendingURLs.isEmpty else { return }
        let urls = pendingURLs
        pendingURLs = []
        stores.importAudioFiles(urls)
    }

    /// Blocks quitting mid-recording behind a confirmation alert; a manual
    /// stop-and-save always finishes before termination actually proceeds.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let stores = Self.stores else { return .terminateNow }
        let title = stores.session.activeRecord?.meeting.title ?? ""
        let elapsedLabel = stores.session.menuBarElapsedLabel ?? "0:00"
        switch QuitGuard.decide(isRecording: stores.session.isRecording, title: title, elapsedLabel: elapsedLabel) {
        case .terminateNow:
            return .terminateNow
        case .confirmBeforeTerminating(let title, let elapsed):
            let alert = NSAlert()
            alert.messageText = "Still recording '\(title)'"
            alert.informativeText = "\(elapsed) recorded so far. Quitting stops the recording and saves it to your library."
            alert.addButton(withTitle: "Stop & Save, then Quit")
            alert.addButton(withTitle: "Keep Recording")
            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else {
                // "Keep Recording" — cancel the quit outright.
                return .terminateCancel
            }
            // Run the app's NORMAL stop flow (same path a manual Stop click
            // takes) so the meeting is finalized and queued exactly like any
            // other stop, then let termination proceed once that's done.
            stores.stopRecording()
            Task { @MainActor in
                // `stopRecording()` is fire-and-forget internally (it awaits
                // the recorder inside its own Task); give it a beat to reach
                // `session.activeRecord == nil` before replying, so a slow
                // write never races app exit. Bounded so a wedged stop flow
                // can't leave the app hung in terminate-later forever — the
                // spool on disk is salvageable at next launch either way.
                let deadline = ContinuousClock.now + .seconds(15)
                while stores.session.activeRecord != nil, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }
}

/// "Check for Updates…" menu item that follows Sparkle's canUpdate state.
struct CheckForUpdatesView: View {
    @State private var canCheck = true
    let updater: SPUUpdater

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!canCheck)
        .onReceive(updater.publisher(for: \.canCheckForUpdates)) { canCheck = $0 }
    }
}
