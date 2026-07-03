import AppKit
import Carbon.HIToolbox
import Foundation
import OSLog
import RecapAudio
import RecapCore
import RecapTranscription

private let storesLog = Logger(subsystem: "com.gregfoster.recap", category: "AppStores")

/// Seam over `CalendarWatcher`, matching its real `start()`/`stop()` shape.
/// `CalendarWatcher` conforms below; tests inject a fake to drive
/// `meetingEventStarting` without EventKit permissions.
@MainActor
public protocol MeetingEventWatching: AnyObject {
    /// Requests calendar access if needed and begins watching. Returns false
    /// when the user has denied access.
    @discardableResult
    func start() async -> Bool
    func stop()
}

/// Seam over `RecordPrompter`, matching its real shape. Tests inject a fake
/// to observe prompt calls without posting real notifications.
@MainActor
public protocol RecordPrompting: AnyObject {
    func promptToRecord(_ event: CalendarEventSnapshot)
}

extension CalendarWatcher: MeetingEventWatching {}
extension RecordPrompter: RecordPrompting {}

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
    /// In-app "update available" indicator state. Driven by the app target's
    /// Sparkle owner (`UpdaterModel`); read by the sidebar and menu bar.
    public let updateStatus = UpdateStatus()
    /// nil in fixture/preview graphs, where nothing touches disk.
    private let storage: LibraryStorage?
    /// Fan-out of library changes to mirror/sync consumers. Constructed once
    /// per process, even in the fixtures graph (harmless there).
    private let changeBus: LibraryChangeBus

    /// ⌥⌘R anywhere toggles recording. nil when another app owns the combo.
    @ObservationIgnored private var recordHotKey: GlobalHotKey?
    @ObservationIgnored private var calendarWatcher: MeetingEventWatching?
    @ObservationIgnored private var recordPrompter: RecordPrompting?
    /// Factories for the calendar seam, defaulting to the real types in the
    /// production path; tests substitute fakes via the injected init.
    @ObservationIgnored private let makeCalendarWatcher: (@escaping @MainActor (CalendarEventSnapshot) -> Void) -> MeetingEventWatching
    @ObservationIgnored private let makeRecordPrompter: (@escaping @MainActor (CalendarEventSnapshot) -> Void) -> RecordPrompting
    /// True when calendar auto-record is enabled in Settings but macOS
    /// calendar access was denied — surfaced as a warning there.
    public private(set) var calendarAccessDenied = false
    /// Per-meeting debounce for the change-bus-driven re-export consumer:
    /// each `.meetingChanged` cancels and restarts a debounce sleep
    /// (`exportDebounce`, 5s in production) before the enabled exporters
    /// actually run, so rapid edits coalesce into one export instead of one
    /// per keystroke-flush.
    /// True from a start trigger until its preflight + start settle; see
    /// `startRecording` for why `session.isRecording` alone isn't enough.
    @ObservationIgnored private var recordingStartInFlight = false
    @ObservationIgnored private var exportDebounceTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var changeBusConsumerTask: Task<Void, Never>?
    @ObservationIgnored private let exportDebounce: Duration

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
            exportDebounce = .seconds(5)
            makeCalendarWatcher = { CalendarWatcher(onMeetingStarting: $0) }
            makeRecordPrompter = { RecordPrompter(onRecord: $0) }
        } else if ProcessInfo.processInfo.arguments.contains("-soak") {
            // Soak-test graph: real recording pipeline (mixer, writer, clock,
            // menu bar) driven by synthetic zero-hardware audio sources, no
            // transcription engine, no queue. Disk-backed under a throwaway
            // temp root so `Scripts/soak-test.sh` can sample the real app's
            // CPU/memory for a runaway main-thread loop without touching mic
            // or system-audio TCC permissions. See `SyntheticAudioSource`.
            settings = .ephemeralOnboarded()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("RecapSoak-\(UUID().uuidString)")
            let storage = LibraryStorage(rootURL: root)
            let index = (try? SearchIndex()) ?? (try! SearchIndex())
            let changeBus = LibraryChangeBus()
            let library = LibraryStore(storage: storage, index: index, changeBus: changeBus)
            let models = WhisperModelManager()
            self.library = library
            self.models = models
            self.storage = storage
            self.changeBus = changeBus
            session = MeetingSessionStore(makeRecorder: {
                MeetingRecorder(mic: SyntheticMicSource(), makeSystemTap: { SyntheticSystemAudioSource() })
            })
            queue = nil
            exportDebounce = .seconds(5)
            makeCalendarWatcher = { CalendarWatcher(onMeetingStarting: $0) }
            makeRecordPrompter = { RecordPrompter(onRecord: $0) }
            let session = self.session
            Task { @MainActor in
                guard let record = library.startNewMeeting(title: "Soak recording") else { return }
                await session.start(record: record, engine: nil, includeSystemAudio: true, includeMic: true)
            }
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
            exportDebounce = .seconds(5)
            makeCalendarWatcher = { CalendarWatcher(onMeetingStarting: $0) }
            makeRecordPrompter = { RecordPrompter(onRecord: $0) }
            let toasts = toasts
            queue = QueueStore(
                library: library, storage: storage, models: models, changeBus: changeBus,
                settings: settings,
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
        exportDebounce = .seconds(5)
        makeCalendarWatcher = { CalendarWatcher(onMeetingStarting: $0) }
        makeRecordPrompter = { RecordPrompter(onRecord: $0) }
    }

    /// Test/fixture seam: every dependency injectable, side-effectful
    /// registrations (hot key, calendar watcher) optional. The disk-backed
    /// `init()` above keeps its own construction (it needs the hot-key and
    /// `onAutoStop` wiring the production path relies on) but shares this
    /// initializer's storage/behavior contract — the change-bus consumer
    /// runs here too whenever `storage != nil`, which is what `AppStoresTests`
    /// exercises.
    init(
        settings: SettingsStore,
        storage: LibraryStorage?,
        library: LibraryStore,
        models: WhisperModelManager,
        session: MeetingSessionStore,
        queue: QueueStore?,
        changeBus: LibraryChangeBus,
        registersHotKey: Bool = false,
        exportDebounce: Duration = .seconds(5),
        makeCalendarWatcher: @escaping (@escaping @MainActor (CalendarEventSnapshot) -> Void) -> MeetingEventWatching = { CalendarWatcher(onMeetingStarting: $0) },
        makeRecordPrompter: @escaping (@escaping @MainActor (CalendarEventSnapshot) -> Void) -> RecordPrompting = { RecordPrompter(onRecord: $0) }
    ) {
        self.settings = settings
        self.storage = storage
        self.library = library
        self.models = models
        self.session = session
        self.queue = queue
        self.changeBus = changeBus
        self.exportDebounce = exportDebounce
        self.makeCalendarWatcher = makeCalendarWatcher
        self.makeRecordPrompter = makeRecordPrompter

        if registersHotKey {
            recordHotKey = GlobalHotKey(keyCode: kVK_ANSI_R, modifiers: cmdKey | optionKey) { [weak self] in
                self?.toggleRecording()
            }
            if recordHotKey == nil {
                storesLog.error("⌥⌘R global hot key registration failed (taken by another app?)")
            } else {
                storesLog.info("⌥⌘R global hot key registered")
            }
            applyCalendarAutoRecordSetting()
            let toasts = toasts
            let session = session
            session.onAutoStop = { [weak self] in
                if let message = session.recordingFailureMessage {
                    toasts.show(message)
                }
                self?.stopRecording()
            }
        }
        if storage != nil {
            startChangeBusConsumer()
        }
    }

    // MARK: Recording control

    /// The one start-recording flow, shared by the Record button, the menu
    /// bar extra, the global hot key, and calendar auto-record.
    public func startRecording(title: String = "Untitled meeting", attendees: [String] = []) {
        // `session.isRecording` only flips once capture is actually running,
        // but preflight below can stay suspended for seconds (mic prompt,
        // tap probe + TCC prompt). Without this latch, a second trigger in
        // that window would run a whole second preflight/start in parallel.
        guard !session.isRecording, !recordingStartInFlight else { return }
        recordingStartInFlight = true
        // Keep the light streaming model topped up in the background — first
        // recording on a fresh install won't have it yet, and this makes
        // sure it's there for the next one even if this one starts without it.
        models.ensureStreamingModelDownloading()
        Task {
            defer { recordingStartInFlight = false }
            let (outcome, probeResult) = await session.preflight(
                includeSystemAudio: settings.includeSystemAudio,
                lastTapFailed: settings.lastSystemAudioTapFailed
            )
            if let probeResult {
                settings.lastSystemAudioTapFailed = (probeResult != .captured)
            }
            switch outcome {
            case .blocked:
                // No usable audio source — don't create a meeting record at
                // all; there's nothing worth transcribing.
                toasts.show(
                    RecapCopy.noAudioAccessMessage, actionTitle: "Open Settings"
                ) { [weak self] in
                    self?.router.section = .settings
                    PrivacyPane.open(PrivacyPane.microphone)
                }
            case .proceed(let includeMic, let includeSystemAudio):
                guard let record = library.startNewMeeting(title: title, attendees: attendees) else { return }
                await session.start(
                    record: record,
                    engine: models.streamingEngine(language: settings.transcriptionLanguage),
                    includeSystemAudio: includeSystemAudio,
                    includeMic: includeMic,
                    preferredInputUID: settings.preferredInputUID
                )
                if session.isRecording {
                    // Jump straight to the live meeting so the live transcript
                    // pane (on by default for live meetings) is visible from
                    // the first second of recording.
                    showMeeting(record.meeting.id)
                }
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
                } else if session.micUnavailable {
                    // Recording is running system-audio only; the pill shows the
                    // "mic off" badge, and this offers the fix.
                    toasts.show(
                        "Microphone access off — recording system audio only",
                        actionTitle: "Open Settings"
                    ) { [weak self] in
                        self?.router.section = .settings
                        PrivacyPane.open(PrivacyPane.microphone)
                    }
                } else if session.systemAudioUnavailable {
                    settings.lastSystemAudioTapFailed = true
                    toasts.show(
                        RecapCopy.systemAudioUnavailableMessage, actionTitle: "Open Settings"
                    ) { [weak self] in
                        self?.router.section = .settings
                        PrivacyPane.open(PrivacyPane.systemAudio)
                    }
                } else if includeSystemAudio {
                    settings.lastSystemAudioTapFailed = false
                }
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
            calendarWatcher = makeCalendarWatcher { [weak self] event in
                self?.meetingEventStarting(event)
            }
        }
        if recordPrompter == nil {
            recordPrompter = makeRecordPrompter { [weak self] event in
                self?.startRecording(for: event)
            }
        }
        Task {
            let granted = await calendarWatcher?.start() ?? false
            calendarAccessDenied = !granted
        }
    }

    /// Internal (not private) so tests can invoke it directly without going
    /// through the real `CalendarWatcher`'s EventKit polling.
    func meetingEventStarting(_ event: CalendarEventSnapshot) {
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
