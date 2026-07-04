import SwiftUI

/// Native Settings window (design handoff turn 7c): a fixed-width `TabView`
/// meant to live inside a SwiftUI `Settings { }` scene, where `.tabItem`
/// toolbar tabs render as macOS's native System-Settings-style icon tabs and
/// the window title tracks the selected tab automatically.
///
/// This view only supplies content — the call site (the app shell's
/// `Settings { }` scene) is responsible for injecting every environment
/// value the tabs read: `AppStores`, `SettingsStore`, `QueueStore`,
/// `WhisperModelManager`, and a `LaunchAtLoginController`.
public struct SettingsWindowView: View {
    public init() {}

    public var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                SettingsGeneralTab()
                    .axID(.settingsTabGeneral)
            }
            Tab("Recording", systemImage: "mic") {
                SettingsRecordingTab()
                    .axID(.settingsTabRecording)
            }
            Tab("Calendar", systemImage: "calendar") {
                SettingsCalendarTab()
                    .axID(.settingsTabCalendar)
            }
            Tab("Sync", systemImage: "arrow.triangle.2.circlepath") {
                SettingsSyncTab()
                    .axID(.settingsTabSync)
            }
            Tab("Privacy", systemImage: "hand.raised") {
                SettingsPrivacyTab()
                    .axID(.settingsTabPrivacy)
            }
        }
        .axID(.settingsWindow)
        .frame(width: 620)
        .formStyle(.grouped)
    }
}

/// Thin, single-purpose wrapper so a group Section has exactly one footnote
/// (design handoff #7c: "One footnote per group ... not per row"). Every tab
/// in this file builds its groups with this helper instead of scattering
/// `Text(...).font(Tokens.caption)` calls after individual controls.
struct SettingsFootnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(Tokens.caption)
            .foregroundStyle(Tokens.textTertiary)
    }
}
