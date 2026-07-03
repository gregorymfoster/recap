import AppKit
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
    /// (`stores.updateStatus`).
    private let updater: UpdaterModel

    init() {
        let stores = AppStores()
        _stores = State(initialValue: stores)
        updater = UpdaterModel(status: stores.updateStatus)
        if ProcessInfo.processInfo.arguments.contains("-force-update-indicator") {
            stores.updateStatus.markAvailable()
        }
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
                CheckForUpdatesView(updater: updater.updater)
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
