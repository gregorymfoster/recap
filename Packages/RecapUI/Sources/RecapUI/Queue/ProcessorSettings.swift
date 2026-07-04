import Foundation

/// Sendable snapshot of the settings the processing pipeline reads. Taken
/// fresh per use (settings can change while a job is queued), via the
/// provider closure injected into MeetingProcessor/QueueStore.
struct ProcessorSettings: Sendable {
    var transcriptionLanguage: String?
    var labelsSpeakers: Bool
    var syncsToObsidian: Bool
    var obsidianVaultPath: String
    var mirrorBackupEnabled: Bool
    var mirrorFolderPath: String
    var webhookURL: String
}

extension SettingsStore {
    var processorSettings: ProcessorSettings {
        ProcessorSettings(
            transcriptionLanguage: transcriptionLanguage,
            labelsSpeakers: labelsSpeakers,
            syncsToObsidian: syncsToObsidian,
            obsidianVaultPath: obsidianVaultPath,
            mirrorBackupEnabled: mirrorBackupEnabled,
            mirrorFolderPath: mirrorFolderPath,
            webhookURL: webhookURL
        )
    }
}
