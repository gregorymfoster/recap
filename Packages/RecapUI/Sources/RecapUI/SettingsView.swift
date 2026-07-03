import SwiftUI

/// The sidebar's "Settings" destination in this worktree.
///
/// Superseded by `SettingsWindowView`, which reorganizes this same content
/// into a native `TabView` (General/Recording/Calendar/Sync/Privacy) meant
/// for a separate `Settings { }` scene (design handoff #7c). Kept as a thin
/// wrapper — rather than deleting the sidebar route outright — because
/// another in-flight package still removes `.settings` from `Sidebar`/
/// `RootView`; once that lands, this file and the `.settings` case can go
/// away together.
///
/// A single scrollable tab list stands in for toolbar tabs here, since this
/// path renders inside the main window's content area rather than inside a
/// `TabView`-driven `Settings` window.
struct SettingsView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case general, recording, calendar, sync, privacy
        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "General"
            case .recording: "Recording"
            case .calendar: "Calendar"
            case .sync: "Sync"
            case .privacy: "Privacy"
            }
        }

        var systemImage: String {
            switch self {
            case .general: "gearshape"
            case .recording: "mic"
            case .calendar: "calendar"
            case .sync: "arrow.triangle.2.circlepath"
            case .privacy: "hand.raised"
            }
        }
    }

    @State private var tab: Tab = .general
    // `RootView` doesn't inject a `LaunchAtLoginController` (this route is
    // slated for removal, so that's rightly out of scope for it) — owned
    // here instead so `SettingsGeneralTab` always finds one in scope.
    @State private var launchAtLogin = LaunchAtLoginController()

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Label(tab.title, systemImage: tab.systemImage).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            switch tab {
            case .general: SettingsGeneralTab()
            case .recording: SettingsRecordingTab()
            case .calendar: SettingsCalendarTab()
            case .sync: SettingsSyncTab()
            case .privacy: SettingsPrivacyTab()
            }
        }
        .environment(launchAtLogin)
    }
}
