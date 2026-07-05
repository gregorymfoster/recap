import Foundation
import RecapCore

/// The one long-lived task that watches every library change and re-runs
/// the currently-enabled exporters for the affected meeting, debounced per
/// meeting ID. This is what makes notes edited *after* processing (Obsidian
/// export otherwise only fires at pipeline completion) still reach the
/// configured destinations. Extracted from `AppStores`, which constructs it
/// only when disk-backed storage exists.
@MainActor
final class ChangeBusConsumer {
    private let changeBus: LibraryChangeBus
    private let storage: LibraryStorage
    private let settings: SettingsStore
    /// Per-meeting debounce: each `.meetingChanged` cancels and restarts a
    /// debounce sleep (5s in production) before the enabled exporters
    /// actually run, so rapid edits coalesce into one export instead of one
    /// per keystroke-flush.
    private let exportDebounce: Duration
    private var exportDebounceTasks: [UUID: Task<Void, Never>] = [:]
    private var consumerTask: Task<Void, Never>?

    init(changeBus: LibraryChangeBus, storage: LibraryStorage, settings: SettingsStore, exportDebounce: Duration) {
        self.changeBus = changeBus
        self.storage = storage
        self.settings = settings
        self.exportDebounce = exportDebounce
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

    /// Re-runs every currently-enabled exporter for one meeting, looked up
    /// fresh from disk. Best-effort and detached — mirrors
    /// `MeetingProcessor.exportToConfiguredDestinations`, but is driven by
    /// the change bus instead of pipeline completion.
    private func runEnabledExporters(for meetingID: UUID) {
        let storage = storage
        let obsidianEnabled = settings.syncsToObsidian
        let obsidianPath = settings.obsidianVaultPath
        let mirrorEnabled = settings.mirrorBackupEnabled
        let mirrorPath = settings.mirrorFolderPath
        guard (obsidianEnabled && !obsidianPath.isEmpty) || (mirrorEnabled && !mirrorPath.isEmpty) else { return }

        Task.detached(priority: .utility) {
            guard let record = try? storage.loadAll().first(where: { $0.meeting.id == meetingID }) else { return }
            let notes = try? storage.loadNotes(in: record)
            let enhanced = (try? storage.loadEnhancedNotes(in: record)) ?? nil
            let transcript = try? storage.loadTranscript(in: record)

            if obsidianEnabled, !obsidianPath.isEmpty {
                let exporter = ObsidianExporter(vaultFolderURL: URL(fileURLWithPath: obsidianPath))
                let speakerNames = ((try? storage.loadSpeakerNames(in: record)) ?? SpeakerNames()).names
                _ = try? exporter.export(record, notes: notes, enhanced: enhanced, transcript: transcript, speakerNames: speakerNames)
            }
            if mirrorEnabled, !mirrorPath.isEmpty {
                let mirror = FolderMirrorExporter(destinationRootURL: URL(fileURLWithPath: mirrorPath))
                try? mirror.mirror(record)
            }
        }
    }
}
