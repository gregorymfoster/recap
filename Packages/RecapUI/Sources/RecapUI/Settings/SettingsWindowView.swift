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
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                tabButton(.general, title: "General", image: "gearshape", id: .settingsTabGeneral)
                tabButton(.recording, title: "Recording", image: "mic", id: .settingsTabRecording)
                tabButton(.calendar, title: "Calendar", image: "calendar", id: .settingsTabCalendar)
                tabButton(.sync, title: "Sync", image: "arrow.triangle.2.circlepath", id: .settingsTabSync)
                tabButton(.privacy, title: "Privacy", image: "hand.raised", id: .settingsTabPrivacy)
            }
            .padding(12)
            .accessibilityElement(children: .contain)
            Divider()
            tabContent
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

    private func tabButton(_ tab: SettingsTab, title: String, image: String, id: AXID) -> some View {
        Button {
            selectedTab = tab
        } label: {
            Label(title, systemImage: image)
                .font(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(selectedTab == tab ? Tokens.accentBlue : Tokens.chipBackground, in: Capsule())
                .foregroundStyle(selectedTab == tab ? Color.white : Tokens.textSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .axID(id)
    }

    @ViewBuilder private var tabContent: some View {
        switch selectedTab {
        case .general: SettingsGeneralTab()
        case .recording: SettingsRecordingTab()
        case .calendar: SettingsCalendarTab()
        case .sync: SettingsSyncTab()
        case .privacy: SettingsPrivacyTab()
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
