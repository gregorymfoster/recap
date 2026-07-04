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
    @Environment(AppRouter.self) private var router
    @State private var selectedTab: SettingsTab = .general

    public init() {}

    public var body: some View {
        TabView(selection: $selectedTab) {
            Tab("General", systemImage: "gearshape", value: SettingsTab.general) {
                SettingsGeneralTab()
                    .axID(.settingsTabGeneral)
            }
            Tab("Recording", systemImage: "mic", value: SettingsTab.recording) {
                SettingsRecordingTab()
                    .axID(.settingsTabRecording)
            }
            Tab("Calendar", systemImage: "calendar", value: SettingsTab.calendar) {
                SettingsCalendarTab()
                    .axID(.settingsTabCalendar)
            }
            Tab("Sync", systemImage: "arrow.triangle.2.circlepath", value: SettingsTab.sync) {
                SettingsSyncTab()
                    .axID(.settingsTabSync)
            }
            Tab("Privacy", systemImage: "hand.raised", value: SettingsTab.privacy) {
                SettingsPrivacyTab()
                    .axID(.settingsTabPrivacy)
            }
        }
        .axID(.settingsWindow)
        .frame(width: 620)
        .formStyle(.grouped)
        // `-open settings/<tab>` (`LaunchRouteApplier`) stages the requested
        // tab on the shared `AppRouter` and opens this window; consuming it
        // here (once, then clearing it) means a later manual ⌘, doesn't keep
        // reapplying a stale launch route.
        .task {
            if let pending = router.pendingSettingsTab {
                selectedTab = pending
                router.pendingSettingsTab = nil
            }
        }
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
