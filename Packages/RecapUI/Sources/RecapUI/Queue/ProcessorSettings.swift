import Foundation

/// Sendable snapshot of the settings the processing pipeline reads. Taken
/// fresh per use (settings can change while a job is queued), via the
/// provider closure injected into MeetingProcessor/QueueStore.
struct ProcessorSettings: Sendable {
    var mirrorBackupEnabled: Bool
    var mirrorFolderPath: String
}

extension SettingsStore {
    var processorSettings: ProcessorSettings {
        ProcessorSettings(
            mirrorBackupEnabled: mirrorBackupEnabled,
            mirrorFolderPath: mirrorFolderPath
        )
    }
}
