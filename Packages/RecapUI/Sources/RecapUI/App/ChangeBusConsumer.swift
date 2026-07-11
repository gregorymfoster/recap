import Foundation
import RecapCore

/// The one long-lived task that watches every library change and re-runs
/// the folder-mirror backup for the affected meeting, debounced per meeting
/// ID. This is what makes notes edited *after* processing (the mirror
/// otherwise only fires at pipeline completion) still reach the backup
/// folder. Extracted from `AppStores`, which constructs it only when
/// disk-backed storage exists. The actual mirror plus the toggle/path guard
/// live on `BackupStatusStore.mirrorMeeting(_:)` now, so this type's only
/// job is the debounce and looking the meeting up fresh from disk.
@MainActor
final class ChangeBusConsumer {
    private let changeBus: LibraryChangeBus
    private let storage: LibraryStorage
    private let backup: BackupStatusStore
    /// Resolves a meeting's folder from the in-memory library (MainActor hop)
    /// — nil when the meeting was trashed since the change was posted.
    private let folderURL: @MainActor (UUID) -> URL?
    /// Per-meeting debounce: each `.meetingChanged` cancels and restarts a
    /// debounce sleep (5s in production) before the mirror backup actually
    /// runs, so rapid edits coalesce into one export instead of one per
    /// keystroke-flush.
    private let exportDebounce: Duration
    private var exportDebounceTasks: [UUID: Task<Void, Never>] = [:]
    private var consumerTask: Task<Void, Never>?

    init(
        changeBus: LibraryChangeBus, storage: LibraryStorage, backup: BackupStatusStore,
        exportDebounce: Duration, folderURL: @escaping @MainActor (UUID) -> URL?
    ) {
        self.changeBus = changeBus
        self.storage = storage
        self.backup = backup
        self.exportDebounce = exportDebounce
        self.folderURL = folderURL
    }

    /// Starts the long-lived consumer task. Called once, right after
    /// construction, by the graphs that want re-export-on-change.
    func start() {
        consumerTask = Task { [weak self] in
            guard let self else { return }
            for await change in self.changeBus.changes() {
                guard case .meetingChanged(let id) = change else { continue }
                self.scheduleDebouncedExport(for: id)
            }
        }
    }

    private func scheduleDebouncedExport(for meetingID: UUID) {
        exportDebounceTasks[meetingID]?.cancel()
        let exportDebounce = exportDebounce
        exportDebounceTasks[meetingID] = Task { [weak self] in
            try? await Task.sleep(for: exportDebounce)
            guard !Task.isCancelled, let self else { return }
            self.exportDebounceTasks.removeValue(forKey: meetingID)
            self.runEnabledExporters(for: meetingID)
        }
    }

    /// Re-runs the mirror backup for one meeting, looked up fresh from disk.
    /// Best-effort and detached — mirrors
    /// `MeetingProcessor.exportToConfiguredDestinations`, but is driven by
    /// the change bus instead of pipeline completion. The toggle/path guard
    /// now lives in `BackupStatusStore.mirrorMeeting(_:)`.
    private func runEnabledExporters(for meetingID: UUID) {
        let storage = storage
        let backup = backup
        let folder = folderURL(meetingID)
        Task.detached(priority: .utility) {
            guard let folder, let record = storage.loadRecord(inFolder: folder) else { return }
            await MainActor.run { backup.mirrorMeeting(record) }
        }
    }
}
