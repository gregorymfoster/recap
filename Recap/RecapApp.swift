import RecapUI
import Sparkle
import SwiftUI

@main
struct RecapApp: App {
    /// The app-lifetime store graph — the App struct persists for the whole
    /// process, so this is constructed exactly once.
    @State private var stores = AppStores()

    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView(stores: stores)
        }
        .defaultSize(width: 1060, height: 660)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
            CommandGroup(replacing: .appSettings) {
                SettingsCommand(stores: stores)
            }
        }

        MenuBarExtra {
            MenuBarContent(stores: stores)
        } label: {
            MenuBarLabel(stores: stores)
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
