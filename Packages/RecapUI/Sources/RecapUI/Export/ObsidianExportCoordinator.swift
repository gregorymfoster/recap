import Foundation
import RecapCore

/// Obsidian vault sync backfill. Extracted from `AppStores`, which exposes
/// it as `stores.obsidianExport` and keeps a thin
/// `exportAllReadyMeetingsToObsidian` forwarder for existing call sites.
@MainActor
public final class ObsidianExportCoordinator {
    private let settings: SettingsStore
    private let library: LibraryStore
    /// nil in fixture/preview graphs, where nothing touches disk.
    private let storage: LibraryStorage?

    init(settings: SettingsStore, library: LibraryStore, storage: LibraryStorage?) {
        self.settings = settings
        self.library = library
        self.storage = storage
    }

    /// Backfills the vault with every finished meeting. Called when sync is
    /// switched on so the vault doesn't start with only future meetings.
    public func exportAllReadyMeetings() {
        guard settings.syncsToObsidian, !settings.obsidianVaultPath.isEmpty,
              let storage else { return }
        let exporter = ObsidianExporter(
            vaultFolderURL: URL(fileURLWithPath: settings.obsidianVaultPath)
        )
        let ready = library.meetings.filter { $0.meeting.status == .ready }
        Task.detached(priority: .utility) {
            for record in ready {
                try? exporter.export(
                    record,
                    notes: try? storage.loadNotes(in: record),
                    enhanced: (try? storage.loadEnhancedNotes(in: record)) ?? nil,
                    transcript: try? storage.loadTranscript(in: record),
                    speakerNames: ((try? storage.loadSpeakerNames(in: record)) ?? SpeakerNames()).names
                )
            }
        }
    }
}
