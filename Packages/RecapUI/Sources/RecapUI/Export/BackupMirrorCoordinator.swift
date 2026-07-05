import Foundation
import RecapCore

/// Folder-mirror backup backfill. Extracted from `AppStores`, which exposes
/// it as `stores.mirrorBackup` and keeps a thin `backfillMirrorBackup`
/// forwarder for existing call sites.
@MainActor
public final class BackupMirrorCoordinator {
    private let settings: SettingsStore
    private let library: LibraryStore

    init(settings: SettingsStore, library: LibraryStore) {
        self.settings = settings
        self.library = library
    }

    /// Mirrors every finished meeting to the configured backup folder.
    /// Called when the backup toggle is switched on, mirroring
    /// `ObsidianExportCoordinator.exportAllReadyMeetings()`'s backfill shape.
    public func backfill() {
        guard settings.mirrorBackupEnabled, !settings.mirrorFolderPath.isEmpty else { return }
        let mirror = FolderMirrorExporter(destinationRootURL: URL(fileURLWithPath: settings.mirrorFolderPath))
        let ready = library.meetings.filter { $0.meeting.status == .ready }
        Task.detached(priority: .utility) {
            for record in ready {
                try? mirror.mirror(record)
            }
        }
    }
}
