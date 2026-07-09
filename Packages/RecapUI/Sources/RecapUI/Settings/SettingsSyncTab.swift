import AppKit
import SwiftUI

/// Sync tab: the one-way folder backup mirror.
struct SettingsSyncTab: View {
    @Environment(AppStores.self) private var stores: AppStores?
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Back up meeting folders to another location", isOn: $settings.mirrorBackupEnabled)
                    .axID(.settingsMirrorBackupToggle)
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
                                .axID(.settingsMirrorFolderChangeButton)
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
