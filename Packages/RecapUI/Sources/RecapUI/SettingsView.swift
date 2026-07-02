import AppKit
import SwiftUI

/// The Settings section: save location, recording sources, processing.
struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(QueueStore.self) private var queue: QueueStore?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Storage") {
                LabeledContent("Meetings folder") {
                    HStack(spacing: 10) {
                        Text(tildePath(settings.saveRootPath))
                            .font(Tokens.meta)
                            .foregroundStyle(Tokens.textSecondary)
                        Button("Change…") { pickFolder() }
                            .controlSize(.small)
                    }
                }
                Text("Notes and audio are plain files — Markdown, JSON, and m4a — readable by any app. A new folder takes effect the next time Recap opens.")
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.textTertiary)
            }

            Section("Recording") {
                Toggle("Capture system audio (other participants)", isOn: $settings.includeSystemAudio)
                Text("Uses macOS's System Audio Recording permission. Turn off to record only your microphone.")
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.textTertiary)
            }

            Section("Processing") {
                Toggle("Pause transcription on battery", isOn: $settings.pausesOnBattery)
                    .onChange(of: settings.pausesOnBattery) {
                        queue?.setPausesOnBattery(settings.pausesOnBattery)
                    }
                Text("Transcription and note enhancement always run at low priority; on battery they wait until you're plugged in.")
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.textTertiary)
            }
        }
        .formStyle(.grouped)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveRootURL
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveRootPath = url.path
        }
    }

    private func tildePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
