import SwiftUI

/// General tab: launch at login + the background capsule style shown while
/// recording with Recap in the background (design handoff #7a/#7c).
struct SettingsGeneralTab: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(LaunchAtLoginController.self) private var launchAtLogin

    var body: some View {
        @Bindable var settings = settings
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

            Section {
                Picker("Background capsule", selection: $settings.floatingCapsuleStyle) {
                    Text("Off").tag(FloatingCapsuleStyle.off)
                    Text("Minimal").tag(FloatingCapsuleStyle.minimal)
                    Text("Full").tag(FloatingCapsuleStyle.full)
                }
                .axID(.settingsFloatingCapsulePicker)
                SettingsFootnote("Shows a small always-on-top status while recording in the background. \"Minimal\" is just the dot and timer; \"Full\" adds a waveform. Click it anytime to bring Recap forward.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }
}
