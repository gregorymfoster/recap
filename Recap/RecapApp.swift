import RecapUI
import Sparkle
import SwiftUI

@main
struct RecapApp: App {
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .defaultSize(width: 1060, height: 660)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
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
