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
        }
        .defaultSize(width: 1060, height: 660)
        .commands {
            CommandGroup(after: .appInfo) {
                if let updater {
                    CheckForUpdatesView(updater: updater.updater)
                }
            }
            CommandGroup(replacing: .appSettings) {
                SettingsCommand(stores: stores)
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

        MenuBarExtra {
            MenuBarContent(stores: stores)
        } label: {
            MenuBarLabel(stores: stores)
        }
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
                // write never races app exit.
                while stores.session.activeRecord != nil {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }
}

/// "Settings…" (⌘,) — routes to the Settings sidebar section and brings the
/// main window forward, matching the same entry point the menu bar exposes.
private struct SettingsCommand: View {
    @Environment(\.openWindow) private var openWindow
    let stores: AppStores

    var body: some View {
        Button("Settings…") {
            stores.openMainWindow(section: .settings, openWindow: { openWindow(id: $0) })
        }
        .keyboardShortcut(",", modifiers: .command)
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
