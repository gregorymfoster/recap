import AppKit
import SwiftUI

/// The Settings section: save location, recording sources, processing.
struct SettingsView: View {
    @Environment(AppStores.self) private var stores: AppStores?
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
                LabeledContent("Start or stop recording anywhere", value: "⌥⌘R")
                Text("Works even when Recap isn't the active app — also available from the menu bar icon.")
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.textTertiary)
            }

            Section("Calendar") {
                Picker("When a calendar meeting starts", selection: $settings.calendarAutoRecord) {
                    Text("Do nothing").tag(CalendarAutoRecordMode.off)
                    Text("Ask to record").tag(CalendarAutoRecordMode.prompt)
                    Text("Record automatically").tag(CalendarAutoRecordMode.auto)
                }
                .onChange(of: settings.calendarAutoRecord) {
                    stores?.applyCalendarAutoRecordSetting()
                }
                if stores?.calendarAccessDenied == true {
                    Text("Calendar access is off. Allow it in System Settings → Privacy & Security → Calendars.")
                        .font(Tokens.caption)
                        .foregroundStyle(Tokens.warningAmberText)
                } else {
                    Text("Detects events with a video-call link or invitees. The recording is titled after the event, with attendees attached.")
                        .font(Tokens.caption)
                        .foregroundStyle(Tokens.textTertiary)
                }
            }

            Section("Sync") {
                Toggle("Copy finished meetings into an Obsidian vault", isOn: $settings.syncsToObsidian)
                    .onChange(of: settings.syncsToObsidian) {
                        if settings.syncsToObsidian {
                            if settings.obsidianVaultPath.isEmpty { pickVaultFolder() }
                            stores?.exportAllReadyMeetingsToObsidian()
                        }
                    }
                if settings.syncsToObsidian {
                    LabeledContent("Vault folder") {
                        HStack(spacing: 10) {
                            Text(settings.obsidianVaultPath.isEmpty
                                ? "None selected"
                                : tildePath(settings.obsidianVaultPath))
                                .font(Tokens.meta)
                                .foregroundStyle(Tokens.textSecondary)
                            Button("Change…") { pickVaultFolder() }
                                .controlSize(.small)
                        }
                    }
                }
                Text("Each meeting becomes one Markdown note — enhanced notes plus the speaker-labeled transcript. Notes are copies; the meetings folder stays the source of truth.")
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
                Toggle("Label speakers in transcripts", isOn: $settings.labelsSpeakers)
                Text("Tells apart who spoke, on-device. The first labeled transcript downloads a small model (~50 MB); if it isn't available yet, transcripts are simply unlabeled.")
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.textTertiary)
            }
        }
        .formStyle(.grouped)
    }

    private func pickVaultFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Choose a folder inside your Obsidian vault"
        if panel.runModal() == .OK, let url = panel.url {
            settings.obsidianVaultPath = url.path
            stores?.exportAllReadyMeetingsToObsidian()
        }
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
