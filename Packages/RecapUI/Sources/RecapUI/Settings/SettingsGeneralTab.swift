import SwiftUI

/// General tab: launch at login. The background capsule (design handoff
/// #7a/#7c) always shows while recording and backgrounded now — no style
/// picker to configure.
struct SettingsGeneralTab: View {
    @Environment(LaunchAtLoginController.self) private var launchAtLogin

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Launch Recap at login",
                    isOn: Binding(
                        get: { launchAtLogin.status.isOn },
                        set: { launchAtLogin.setEnabled($0) }
                    )
                )
                .axID(.settingsLaunchAtLoginToggle)
                if let footnote = launchAtLogin.status.footnote {
                    SettingsFootnote(footnote)
                } else if let error = launchAtLogin.lastErrorMessage {
                    SettingsFootnote(error)
                } else {
                    SettingsFootnote("Opens quietly in the background — no window until you click the menu bar icon or a recording starts.")
                }
            }
            .onAppear { launchAtLogin.refresh() }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }
}
