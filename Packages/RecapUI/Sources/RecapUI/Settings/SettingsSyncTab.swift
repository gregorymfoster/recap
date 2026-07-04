import AppKit
import SwiftUI

/// Sync tab: Obsidian vault mirroring, the finished-meeting webhook, and the
/// one-way folder backup mirror.
struct SettingsSyncTab: View {
    @Environment(AppStores.self) private var stores: AppStores?
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
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
                SettingsFootnote("Each meeting becomes one Markdown note — enhanced notes plus the speaker-labeled transcript. Notes are copies; the meetings folder stays the source of truth.")
            }

            Section {
                TextField("Webhook URL", text: $settings.webhookURL, prompt: Text("https://example.com/hook"))
                    .textFieldStyle(.roundedBorder)
                    .font(Tokens.meta)
                SettingsFootnote("Finished meetings are also POSTed to this URL as JSON (title, notes, transcript). Leave empty to disable.")
            }

            Section {
                Toggle("Back up meeting folders to another location", isOn: $settings.mirrorBackupEnabled)
                    .onChange(of: settings.mirrorBackupEnabled) {
                        if settings.mirrorBackupEnabled {
                            if settings.mirrorFolderPath.isEmpty { pickMirrorFolder() }
                            stores?.backfillMirrorBackup()
                        }
                    }
                if settings.mirrorBackupEnabled {
                    LabeledContent("Backup folder") {
                        HStack(spacing: 10) {
                            Text(settings.mirrorFolderPath.isEmpty
                                ? "None selected"
                                : tildePath(settings.mirrorFolderPath))
                                .font(Tokens.meta)
                                .foregroundStyle(Tokens.textSecondary)
                            Button("Change…") { pickMirrorFolder() }
                                .controlSize(.small)
                        }
                    }
                }
                SettingsFootnote("A complete, one-way copy of each meeting folder — including audio — is kept in sync here. Picking a folder inside iCloud Drive keeps an extra copy in iCloud automatically.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Sync")
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

    private func pickMirrorFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Choose a backup destination folder"
        if panel.runModal() == .OK, let url = panel.url {
            settings.mirrorFolderPath = url.path
            stores?.backfillMirrorBackup()
        }
    }

    private func tildePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
