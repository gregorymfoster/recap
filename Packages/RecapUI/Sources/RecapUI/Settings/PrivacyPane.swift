import AppKit
import Foundation

/// Deep links into System Settings' Privacy & Security panes. Shared by
/// onboarding, the Permissions section in Settings, and toast actions.
enum PrivacyPane {
    static let microphone = "Privacy_Microphone"
    /// "Screen & System Audio Recording" — the pane the system-audio tap's
    /// permission prompt lives under.
    static let systemAudio = "Privacy_ScreenCapture"
    static let calendars = "Privacy_Calendars"

    static func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
