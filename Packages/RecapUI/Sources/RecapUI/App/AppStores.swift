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

extension CalendarWatcher: MeetingEventWatching {}

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
    /// Today's remaining calendar events for the Library's Upcoming section
    /// (design mock 9a). Fixture-seeded in the fixtures graph.
    public let upcoming: UpcomingStore
    public let router = AppRouter()
    public let toasts = ToastCenter()
    /// Posts "‹meeting› is ready" notifications (design spec 8f). `nil` in
    /// fixtures/soak graphs — nothing there ever reaches a real `.ready`
    /// transition through a real queue, so there's nothing to notify about.
    @ObservationIgnored private var completionNotifier: CompletionNotifier?
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
    /// Factory for the calendar seam, defaulting to the real type in the
    /// production path; tests substitute a fake via the injected init.
    @ObservationIgnored private let makeCalendarWatcher: (@escaping @MainActor (CalendarEventSnapshot) -> Void) -> MeetingEventWatching
    /// True when calendar auto-record is enabled in Settings but macOS
    /// calendar access was denied — surfaced as a warning there.
    public private(set) var calendarAccessDenied = false

    /// The "Meeting started?" nudge (design mock 9b) — trigger/dedupe brain
    /// plus its top-right slide-in panel. Built lazily by
    /// `applyCalendarAutoRecordSetting()` the first time policy != `.off`,
    /// and torn down (monitor stopped, panel dismissed) when it flips back
    /// to `.off`.
    @ObservationIgnored private var nudgeCenter: MeetingNudgeCenter?
    @ObservationIgnored private var nudgePanel: MeetingNudgePanelController?
    @ObservationIgnored private var callAudioMonitor: CallAudioMonitoring?
    /// Factory for the call-audio monitor seam: `ProcessAudioMonitor` in the
    /// production graph, `{ nil }` in fixtures/soak/preview and the test
    /// init's default — the wiring no-ops gracefully on nil.
    @ObservationIgnored private let makeCallAudioMonitor: () -> CallAudioMonitoring?
    /// Injectable source of "today's remaining calendar events", used by the
    /// nudge center to find a calendar match for a call-audio trigger.
    /// Defaults to `{ _ in [] }`; the production `init()` path builds it
    /// from a dedicated `CalendarWatcher` query instance.
    @ObservationIgnored private let todayEventsProvider: @MainActor (Date) -> [CalendarEventSnapshot]
    /// Test-only hook: when set, `presentNudge` calls this instead of
    /// driving a real `NSPanel`, so tests can assert on presented nudges
    /// without a panel ever appearing on screen.
    @ObservationIgnored var onNudgePresented: ((MeetingNudge) -> Void)?
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

    // MARK: Inert launch-argument carriers (parsed, not yet consumed)

    /// The fixture scenario from `-fixtures <name>` ("default" when bare).
    /// Only "default" behavior exists today — carried for the
    /// fixture-scenarios work. `nil` outside the fixtures graph.
    public let fixtureScenario: String?
    /// The route from `-open <route>`, not yet applied anywhere — carried
    /// for the launch-routing work.
    public let launchRoute: Route?
    /// The directory from `-seed-dir <path>`, not yet consumed — carried
    /// for the seeded-state work.
    public let launchSeedDir: URL?

    /// The launch graph used by the app, selected by the parsed launch
    /// configuration: `.normal` is disk-backed; `.fixtures` swaps in sample
    /// data for UI work and screenshots (no queue — fixtures never process);
    /// `.soak` is the synthetic-audio soak harness.
    public init(configuration: LaunchConfiguration) {
        launchRoute = configuration.route
        launchSeedDir = configuration.seedDir
        if case .fixtures(let scenario) = configuration.mode {
            fixtureScenario = scenario
        } else {
            fixtureScenario = nil
        }
        if case .fixtures = configuration.mode {
            let scenario = FixtureScenario(rawScenario: fixtureScenario ?? "default")
            settings = .ephemeralOnboarded()
            library = scenario.library
            models = WhisperModelManager()
            session = MeetingSessionStore()
            queue = nil
            storage = nil
            changeBus = LibraryChangeBus()
            upcoming = scenario.upcoming
            exportDebounce = .seconds(5)
            makeCalendarWatcher = { CalendarWatcher(onMeetingStarting: $0) }
            makeCallAudioMonitor = { nil }
            todayEventsProvider = { _ in [] }
        } else if configuration.mode == .soak {
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
            upcoming = .live()
            exportDebounce = .seconds(5)
            makeCalendarWatcher = { CalendarWatcher(onMeetingStarting: $0) }
            makeCallAudioMonitor = { nil }
            todayEventsProvider = { _ in [] }
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
            upcoming = .live()
            exportDebounce = .seconds(5)
            makeCalendarWatcher = { CalendarWatcher(onMeetingStarting: $0) }
            makeCallAudioMonitor = { ProcessAudioMonitor() }
            let calendarQuery = CalendarWatcher(onMeetingStarting: { _ in })
            todayEventsProvider = { calendarQuery.todayEvents(now: $0) }
            let toasts = toasts
            let router = router
            let notifier = CompletionNotifier(
                onOpenMeeting: { [weak library] id in
                    // Mirrors `AppStores.showMeeting(_:)`, inlined: `self`
                    // isn't fully initialized yet at this point in `init`.
                    router.section = .library
                    library?.selectedMeetingID = id
                    NSApp.activate(ignoringOtherApps: true)
                },
                isMeetingCurrentlyVisible: { [weak library] in
                    NSApp.isActive && router.section == .library && library?.selectedMeetingID == $0
                }
            )
            completionNotifier = notifier
            queue = QueueStore(
                library: library, storage: storage, models: models, changeBus: changeBus,
                settings: settings,
                onError: { message in toasts.show(message) },
                onMeetingReady: { [weak library] id in
                    guard let library,
                          let record = library.meetings.first(where: { $0.meeting.id == id })
                    else { return }
                    let enhancedNotes = (try? storage.loadEnhancedNotes(in: record)) ?? nil
                    let hasEnhancedNotes = !(enhancedNotes ?? "").isEmpty
                    notifier.meetingStatusChanged(
                        meetingID: id, title: record.meeting.title, duration: record.meeting.duration,
                        hasEnhancedNotes: hasEnhancedNotes, to: .ready
                    )
                }
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
            session.onInputRebuilt = { [weak self] reason, deviceName in
                self?.toasts.show(MicLossToast.message(reason: reason, deviceName: deviceName), style: .warning, actionTitle: "Change…") {
                    SettingsOpener.open()
                }
            }
            startChangeBusConsumer()
        }
    }

    /// Preview graph around the given library.
    init(library: LibraryStore) {
        fixtureScenario = nil
        launchRoute = nil
        launchSeedDir = nil
        settings = .ephemeralOnboarded()
        self.library = library
        models = WhisperModelManager()
        session = MeetingSessionStore()
        queue = nil
        storage = nil
        changeBus = LibraryChangeBus()
        upcoming = .fixture()
        exportDebounce = .seconds(5)
        makeCalendarWatcher = { CalendarWatcher(onMeetingStarting: $0) }
        makeCallAudioMonitor = { nil }
        todayEventsProvider = { _ in [] }
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
        upcoming: UpcomingStore = .fixture(),
        registersHotKey: Bool = false,
        exportDebounce: Duration = .seconds(5),
        makeCalendarWatcher: @escaping (@escaping @MainActor (CalendarEventSnapshot) -> Void) -> MeetingEventWatching = { CalendarWatcher(onMeetingStarting: $0) },
        makeCallAudioMonitor: @escaping () -> CallAudioMonitoring? = { nil },
        todayEventsProvider: @escaping @MainActor (Date) -> [CalendarEventSnapshot] = { _ in [] }
    ) {
        fixtureScenario = nil
        launchRoute = nil
        launchSeedDir = nil
        self.settings = settings
        self.storage = storage
        self.library = library
        self.models = models
        self.session = session
        self.queue = queue
        self.changeBus = changeBus
        self.upcoming = upcoming
        self.exportDebounce = exportDebounce
        self.makeCalendarWatcher = makeCalendarWatcher
        self.makeCallAudioMonitor = makeCallAudioMonitor
        self.todayEventsProvider = todayEventsProvider

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
            session.onInputRebuilt = { reason, deviceName in
                toasts.show(MicLossToast.message(reason: reason, deviceName: deviceName), style: .warning, actionTitle: "Change…") {
                    SettingsOpener.open()
                }
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
                ) {
                    SettingsOpener.open()
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
                    ) {
                        SettingsOpener.open()
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
                    ) {
                        SettingsOpener.open()
                        PrivacyPane.open(PrivacyPane.microphone)
                    }
                } else if session.systemAudioUnavailable {
                    settings.lastSystemAudioTapFailed = true
                    toasts.show(
                        RecapCopy.systemAudioUnavailableMessage, actionTitle: "Open Settings"
                    ) {
                        SettingsOpener.open()
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

    /// Moves a meeting to Trash and cancels any still-pending queue work for
    /// it — the library row's "Move to Trash" context-menu action. Mirrors
    /// the `stopRecording`/`importAudioFiles` shape: `AppStores` is the one
    /// place that sees both `library` and `queue`, so it's the seam that
    /// keeps them in sync rather than teaching `LibraryStore` about the
    /// queue. `queue` is nil in the fixtures graph, where trashing already
    /// no-ops (no real folder to trash for a `/dev/null` fixture record).
    public func moveToTrash(_ record: MeetingRecord) {
        library.moveToTrash(record)
        queue?.cancel(meetingID: record.meeting.id)
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

    // MARK: Calendar auto-record + Meeting nudge (design mock 9b)

    /// Starts or stops the calendar watcher, the call-audio monitor, and the
    /// nudge center/panel to match Settings. Called at launch and whenever
    /// the setting (or `disabledCallAppIDs`) changes — a change to the
    /// disabled set must restart the monitor with the new bundle-id set, so
    /// this always tears down and rebuilds the monitor's watched set rather
    /// than only acting on a `.off` transition.
    public func applyCalendarAutoRecordSetting() {
        guard settings.calendarAutoRecord != .off else {
            calendarWatcher?.stop()
            calendarAccessDenied = false
            callAudioMonitor?.stop()
            nudgePanel?.dismiss()
            return
        }
        if calendarWatcher == nil {
            calendarWatcher = makeCalendarWatcher { [weak self] event in
                self?.meetingEventStarting(event)
            }
        }
        ensureNudgeCenter()
        Task {
            let granted = await calendarWatcher?.start() ?? false
            calendarAccessDenied = !granted
        }

        if callAudioMonitor == nil {
            callAudioMonitor = makeCallAudioMonitor()
        }
        let bundleIDs = CallAppCatalog.enabledBundleIDs(disabledAppIDs: settings.disabledCallAppIDs)
        callAudioMonitor?.start(bundleIDs: bundleIDs) { [weak self] event in
            self?.nudgeCenter?.callAudioEvent(event)
        }
    }

    /// Internal (not private) so tests can invoke it directly without going
    /// through the real `CalendarWatcher`'s EventKit polling.
    func meetingEventStarting(_ event: CalendarEventSnapshot) {
        ensureNudgeCenter()
        nudgeCenter?.calendarEventStarting(event)
    }

    /// Builds the nudge center + panel once, wiring the center's closures to
    /// live settings/session state and the panel to the center's action
    /// entry points.
    private func ensureNudgeCenter() {
        guard nudgeCenter == nil else { return }
        let panel = MeetingNudgePanelController()
        let center = MeetingNudgeCenter(
            policy: { [weak self] in
                MeetingDetectionRules.Policy(rawValue: self?.settings.calendarAutoRecord.rawValue ?? "off") ?? .off
            },
            isRecording: { [weak self] in self?.session.isRecording ?? false },
            disabledAppIDs: { [weak self] in self?.settings.disabledCallAppIDs ?? [] },
            todayEvents: { [weak self] date in self?.todayEventsProvider(date) ?? [] },
            present: { [weak self] nudge in self?.presentNudge(nudge) },
            startRecording: { [weak self] title, attendees in
                self?.startRecording(title: title, attendees: attendees)
            }
        )
        panel.onRecord = { [weak center] nudge in center?.recordTapped(for: nudge) }
        panel.onNotNow = { [weak center] nudge in center?.notNowTapped(for: nudge) }
        panel.onDontAsk = { [weak self, weak center] appID in
            center?.dontAskTapped(appID: appID) { appID in
                self?.settings.disabledCallAppIDs.insert(appID)
                self?.applyCalendarAutoRecordSetting()
            }
        }
        panel.onStop = { [weak self] in self?.stopRecording() }
        nudgeCenter = center
        nudgePanel = panel
    }

    /// Presents a nudge — through the test hook when one's installed (tests
    /// must never construct a real `NSPanel`), otherwise through the real
    /// panel controller.
    private func presentNudge(_ nudge: MeetingNudge) {
        if let onNudgePresented {
            onNudgePresented(nudge)
        } else {
            nudgePanel?.present(nudge)
        }
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
                    transcript: try? storage.loadTranscript(in: record),
                    speakerNames: ((try? storage.loadSpeakerNames(in: record)) ?? SpeakerNames()).names
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
