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

    /// The launch arguments, parsed exactly once (pure `LaunchConfiguration`
    /// in RecapUI — the shell never inspects `CommandLine` beyond this).
    private let launch = LaunchConfiguration(arguments: Array(CommandLine.arguments.dropFirst()))

    init() {
        // MUST run before NSApplicationMain: stops AppKit from treating a
        // leftover bare launch argument (e.g. the route in `-fixtures -open
        // settings/general`) as a document to open, which suppresses the
        // main WindowGroup window entirely — the app would boot windowless
        // and hang. See `LaunchConfiguration.requiredDefaultsRegistrations`.
        UserDefaults.standard.register(defaults: LaunchConfiguration.requiredDefaultsRegistrations)
        let stores = AppStores(configuration: launch)
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
                .frame(minWidth: 880, minHeight: 560)
                .modifier(DebugWindowOpener(configuration: launch))
        }
        .defaultSize(width: 880, height: 560)
        .windowResizability(.contentMinSize)
        // Fixtures/soak launches must boot into a deterministic single
        // window — never restore stale multi-window state from a previous
        // launch. (`LaunchConfiguration.restoresWindowState` is the tested
        // decision.)
        .restorationBehavior(launch.restoresWindowState ? .automatic : .disabled)
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

        // Debug hooks (like `-fixtures`/`-soak`), content hosted in RecapUI
        // (`DebugWindows.swift`): the menu bar extra's popover and the real
        // nudge `NSPanel` live where headless screenshot tooling can't
        // reach, so these auxiliary windows host the same content.
        // `SceneBuilder` doesn't support an `if` here (control flow inside a
        // scene builder isn't just unsupported, it currently ICEs the
        // compiler — confirmed by isolated repro), so the scenes are always
        // declared but launch-suppressed; `DebugWindowOpener` (on the main
        // window above) opens them only when this launch actually passed
        // `-show-menubar-content` / `-fixtures -show-nudge`. Restoration is
        // disabled outright: a debug window must never reappear on a later
        // launch via scene restoration when its flag isn't present.
        Window("Menu Bar Content", id: DebugWindowID.menuBarContent) {
            MenuBarContentDebugView(stores: stores)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("Nudge Preview", id: DebugWindowID.nudgePreview) {
            NudgePreviewDebugView()
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
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
    /// Also flushes any pending (debounced) notes edit on every return path —
    /// `MeetingDetailView`'s `.onDisappear` and `RootView`'s window-close
    /// observer both cover in-app teardown, but quitting via ⌘Q/menu goes
    /// straight here without either firing first, so a note edit still
    /// sitting inside the 1s autosave debounce would otherwise be lost.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let stores = Self.stores else { return .terminateNow }
        if case .detail(let meetingID) = stores.router.screen, let record = stores.library.record(for: meetingID) {
            stores.library.flushNotes(for: record)
        }
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
