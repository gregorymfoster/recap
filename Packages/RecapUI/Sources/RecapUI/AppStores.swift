import AppKit
import Carbon.HIToolbox
import Foundation
import OSLog
import RecapCore
import RecapTranscription

private let storesLog = Logger(subsystem: "com.gregfoster.recap", category: "AppStores")

/// App-lifetime store graph, constructed exactly once (held by the App struct).
///
/// SwiftUI re-initializes view values freely, so building stores in a view's
/// `init` creates transient duplicates whose side effects are still live: every
/// extra QueueStore re-enqueued unfinished meetings, and the resulting
/// concurrent WhisperKit loads starved CoreML of file handles (model reads
/// failed, transcripts came back empty, and WhisperModelManager.refresh()
/// would then clear the active model). Owning the graph here guarantees one
/// instance of each store per process.
@MainActor
@Observable
public final class AppStores {
    public let settings: SettingsStore
    public let library: LibraryStore
    public let models: WhisperModelManager
    public let session: MeetingSessionStore
    public let queue: QueueStore?
    public let router = AppRouter()
    public let toasts = ToastCenter()
    /// nil in fixture/preview graphs, where nothing touches disk.
    private let storage: LibraryStorage?
    /// Fan-out of library changes to mirror/sync consumers. Constructed once
    /// per process, even in the fixtures graph (harmless there).
    private let changeBus: LibraryChangeBus

    /// ⌥⌘R anywhere toggles recording. nil when another app owns the combo.
    @ObservationIgnored private var recordHotKey: GlobalHotKey?
    @ObservationIgnored private var calendarWatcher: CalendarWatcher?
    @ObservationIgnored private var recordPrompter: RecordPrompter?
    /// True when calendar auto-record is enabled in Settings but macOS
    /// calendar access was denied — surfaced as a warning there.
    public private(set) var calendarAccessDenied = false
    /// Per-meeting debounce for the change-bus-driven re-export consumer:
    /// each `.meetingChanged` cancels and restarts a ~5s sleep before the
    /// enabled exporters actually run, so rapid edits coalesce into one
    /// export instead of one per keystroke-flush.
    @ObservationIgnored private var exportDebounceTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var changeBusConsumerTask: Task<Void, Never>?

    /// Disk-backed graph used by the app. `-fixtures` swaps in sample data
    /// for UI work and screenshots (no queue — fixtures never process).
    public init() {
        if ProcessInfo.processInfo.arguments.contains("-fixtures") {
            settings = .ephemeralOnboarded()
            library = .fixture()
            models = WhisperModelManager()
            session = MeetingSessionStore()
            queue = nil
            storage = nil
            changeBus = LibraryChangeBus()
        } else {
            let settings = SettingsStore()
            let storage = LibraryStorage(rootURL: settings.saveRootURL)
            let index = (try? SearchIndex(databaseURL: SearchIndex.defaultDatabaseURL)) ?? (try! SearchIndex())
            let changeBus = LibraryChangeBus()
            let library = LibraryStore(storage: storage, index: index, changeBus: changeBus)
            let models = WhisperModelManager()
            self.settings = settings
            self.library = library
            self.models = models
            self.storage = storage
            self.changeBus = changeBus
            session = MeetingSessionStore()
            let toasts = toasts
            queue = QueueStore(
                library: library, storage: storage, models: models, changeBus: changeBus,
                onError: { message in toasts.show(message) }
            )
            recordHotKey = GlobalHotKey(keyCode: kVK_ANSI_R, modifiers: cmdKey | optionKey) { [weak self] in
                self?.toggleRecording()
            }
            if recordHotKey == nil {
                storesLog.error("⌥⌘R global hot key registration failed (taken by another app?)")
            } else {
                storesLog.info("⌥⌘R global hot key registered")
            }
            applyCalendarAutoRecordSetting()
            // A recorder-initiated stop (disk full) still runs the normal
            // stop flow so the salvaged audio gets transcribed.
            session.onAutoStop = { [weak self] in
                if let message = self?.session.recordingFailureMessage {
                    self?.toasts.show(message)
                }
                self?.stopRecording()
            }
            startChangeBusConsumer()
        }
    }

    /// Preview graph around the given library.
    init(library: LibraryStore) {
        settings = .ephemeralOnboarded()
        self.library = library
        models = WhisperModelManager()
        session = MeetingSessionStore()
        queue = nil
        storage = nil
        changeBus = LibraryChangeBus()
    }

    // MARK: Recording control

    /// The one start-recording flow, shared by the Record button, the menu
    /// bar extra, the global hot key, and calendar auto-record.
    public func startRecording(title: String = "Untitled meeting", attendees: [String] = []) {
        guard !session.isRecording,
              let record = library.startNewMeeting(title: title, attendees: attendees)
        else { return }
        // Keep the light streaming model topped up in the background — first
        // recording on a fresh install won't have it yet, and this makes
        // sure it's there for the next one even if this one starts without it.
        models.ensureStreamingModelDownloading()
        Task {
            await session.start(
                record: record,
                engine: models.streamingEngine(language: settings.transcriptionLanguage),
                includeSystemAudio: settings.includeSystemAudio,
                preferredInputUID: settings.preferredInputUID
            )
            if session.permissionDenied {
                library.markError(record, message: "Microphone access denied")
                toasts.show(
                    "Microphone access denied", actionTitle: "Open Settings"
                ) { [weak self] in
                    self?.router.section = .settings
                    PrivacyPane.open(PrivacyPane.microphone)
                }
            } else if let message = session.startFailureMessage {
                library.markError(record, message: message)
                toasts.show(message)
            } else if session.systemAudioUnavailable {
                settings.lastSystemAudioTapFailed = true
                toasts.show(
                    RecapCopy.systemAudioUnavailableMessage, actionTitle: "Open Settings"
                ) { [weak self] in
                    self?.router.section = .settings
                }
            } else if settings.includeSystemAudio {
                settings.lastSystemAudioTapFailed = false
            }
        }
    }

    /// The one stop flow: finish the recording and queue transcription.
    public func stopRecording() {
        Task {
            if let (record, duration) = await session.stop() {
                library.finishRecording(record, duration: duration)
                queue?.enqueueTranscription(for: record.meeting.id)
            }
        }
    }

    public func toggleRecording() {
        session.isRecording ? stopRecording() : startRecording()
    }

    /// Pause/resume gate capture without ending the meeting. ⌥⌘P is a local
    /// shortcut only (pill + menu bar extra) — no new GlobalHotKey in v1.
    public func pauseRecording() {
        Task { await session.pause() }
    }

    public func resumeRecording() {
        Task { await session.resume() }
    }

    public func togglePause() {
        session.isPaused ? resumeRecording() : pauseRecording()
    }

    // MARK: Import external audio

    /// Imports external audio files (⌘O panel, drag-drop, Finder Open With):
    /// each file is validated, transcoded to audio.m4a, and fully on disk
    /// before the meeting appears and transcription is enqueued — the
    /// processor must never race a half-written file. One detached utility
    /// task per batch; files import sequentially within it. No-op in the
    /// fixtures/preview graph (no storage or queue).
    public func importAudioFiles(_ urls: [URL]) {
        guard let storage, let queue else { return }
        let importer = AudioImporter(storage: storage)
        let library = library
        let toasts = toasts
        Task.detached(priority: .utility) {
            for url in urls {
                do {
                    let record = try importer.importFile(at: url)
                    await MainActor.run {
                        library.insertImported(record)
                        queue.enqueueTranscription(for: record.meeting.id)
                    }
                } catch {
                    storesLog.error("Import failed for \(url.lastPathComponent, privacy: .public): \(error, privacy: .public)")
                    await MainActor.run {
                        toasts.show("Couldn't import \(url.lastPathComponent) — unreadable audio file")
                    }
                }
            }
        }
    }

    /// Navigates to a meeting (used by the menu bar extra's jump items).
    public func showMeeting(_ id: UUID) {
        router.section = .library
        library.selectedMeetingID = id
    }

    /// Routes to a section and brings the main window forward (recreating it
    /// if it was closed). `openWindow` is a SwiftUI Environment value only
    /// available in a view/scene context, so callers (the ⌘, command, the
    /// menu bar extra) pass theirs in rather than this living on `AppStores`.
    public func openMainWindow(section: SidebarItem? = nil, openWindow: (String) -> Void) {
        if let section {
            router.section = section
        }
        openWindow("main")
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Calendar auto-record

    /// Starts or stops the calendar watcher to match Settings. Called at
    /// launch and whenever the setting changes.
    public func applyCalendarAutoRecordSetting() {
        guard settings.calendarAutoRecord != .off else {
            calendarWatcher?.stop()
            calendarAccessDenied = false
            return
        }
        if calendarWatcher == nil {
            calendarWatcher = CalendarWatcher { [weak self] event in
                self?.meetingEventStarting(event)
            }
        }
        if recordPrompter == nil {
            recordPrompter = RecordPrompter { [weak self] event in
                self?.startRecording(for: event)
            }
        }
        Task {
            let granted = await calendarWatcher?.start() ?? false
            calendarAccessDenied = !granted
        }
    }

    private func meetingEventStarting(_ event: CalendarEventSnapshot) {
        guard !session.isRecording else { return }
        switch settings.calendarAutoRecord {
        case .off:
            break
        case .prompt:
            recordPrompter?.promptToRecord(event)
        case .auto:
            startRecording(for: event)
        }
    }

    private func startRecording(for event: CalendarEventSnapshot) {
        startRecording(title: event.title, attendees: event.otherAttendees)
    }

    // MARK: Obsidian sync

    /// Backfills the vault with every finished meeting. Called when sync is
    /// switched on so the vault doesn't start with only future meetings.
    public func exportAllReadyMeetingsToObsidian() {
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
                    transcript: try? storage.loadTranscript(in: record)
                )
            }
        }
    }

    // MARK: Folder-mirror backup

    /// Mirrors every finished meeting to the configured backup folder.
    /// Called when the backup toggle is switched on, mirroring
    /// `exportAllReadyMeetingsToObsidian()`'s backfill shape.
    public func backfillMirrorBackup() {
        guard settings.mirrorBackupEnabled, !settings.mirrorFolderPath.isEmpty else { return }
        let mirror = FolderMirrorExporter(destinationRootURL: URL(fileURLWithPath: settings.mirrorFolderPath))
        let ready = library.meetings.filter { $0.meeting.status == .ready }
        Task.detached(priority: .utility) {
            for record in ready {
                try? mirror.mirror(record)
            }
        }
    }

    // MARK: Change-bus consumer

    /// Starts the one long-lived task that watches every library change and
    /// re-runs the currently-enabled exporters for the affected meeting,
    /// debounced per meeting ID. This is what makes notes edited *after*
    /// processing (Obsidian export today only fires at completion) still
    /// reach the configured destinations.
    private func startChangeBusConsumer() {
        changeBusConsumerTask = Task { [weak self] in
            guard let self else { return }
            for await change in self.changeBus.changes() {
                guard case .meetingChanged(let id) = change else { continue }
                self.scheduleDebouncedExport(for: id)
            }
        }
    }

    private func scheduleDebouncedExport(for meetingID: UUID) {
        exportDebounceTasks[meetingID]?.cancel()
        exportDebounceTasks[meetingID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
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
        guard let storage else { return }
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
                _ = try? exporter.export(record, notes: notes, enhanced: enhanced, transcript: transcript)
            }
            if mirrorEnabled, !mirrorPath.isEmpty {
                let mirror = FolderMirrorExporter(destinationRootURL: URL(fileURLWithPath: mirrorPath))
                try? mirror.mirror(record)
            }
        }
    }
}
