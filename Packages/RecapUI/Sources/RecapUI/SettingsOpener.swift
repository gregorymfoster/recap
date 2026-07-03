import AppKit

/// Opens the app's Settings scene (⌘,) from non-View contexts — menu bar
/// items, toasts, AppKit controllers. Views inside the SwiftUI hierarchy can
/// use `SettingsLink` instead; this sends the same responder-chain action.
@MainActor
public enum SettingsOpener {
    public static func open() {
        NSApp.activate(ignoringOtherApps: true)
        // The selector SwiftUI's Settings scene registers on macOS 14+.
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
