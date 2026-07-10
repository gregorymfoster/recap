import AppKit
import Foundation
import RecapAudio
import RecapCore
import RecapTranscription

/// App-lifetime store graph, constructed exactly once (held by the App struct).
///
/// SwiftUI re-initializes view values freely, so building stores in a view's
/// `init` creates transient duplicates whose side effects are still live: every
/// extra QueueStore re-enqueued unfinished meetings, and the resulting
/// concurrent WhisperKit loads starved CoreML of file handles (model reads
/// failed, transcripts came back empty, and WhisperModelManager.refresh()
/// would then clear the active model). Owning the graph here guarantees one
/// instance of each store per process.
///
/// This is a composition root: it owns the stores and wires the per-subsystem
/// coordinators (`RecordingController`, `ImportCoordinator`,
/// `AutoRecordCoordinator`, `BackupStatusStore`, `ChangeBusConsumer`),
/// keeping thin forwarders for the coordinator entry points views already call.
@MainActor
@Observable
public final class AppStores {
    public let settings: SettingsStore
    public let library: LibraryStore
    public let models: WhisperModelManager
    /// Drives automatic model download/activation from the quality
    /// preference (replaces the manual Models screen). Inert (`.done`,
    /// never downloads) unless `start()` is called — only the normal-mode
    /// graph below does that.
    public let setup: TranscriptionSetupStore
    public let session: MeetingSessionStore
    public let queue: QueueStore?
    /// Today's remaining calendar events for the Library's Upcoming section
    /// (design mock 9a). Fixture-seeded in the fixtures graph.
    public let upcoming: UpcomingStore
    public let router = AppRouter()
    public let toasts = ToastCenter()
    /// The process's sole `UNUserNotificationCenterDelegate`, installed once
    /// here. `CompletionNotifier` and `AutoRecordCoordinator`'s
    /// `CallStartNotifier` both register category handlers with it instead
    /// of touching the delegate slot themselves — see `NotificationRouter`.
    @ObservationIgnored private let notificationRouter = NotificationRouter()
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

    // MARK: Coordinators

    /// Start/stop/pause recording control + the ⌥⌘R hot key.
    public let recording: RecordingController
    /// Audio-file import (⌘O, drag-drop, Finder Open With).
    public let importer: ImportCoordinator
    /// Calendar auto-record policy + the "Meeting started?" nudge.
    public let autoRecord: AutoRecordCoordinator
    /// Aggregate folder-mirror backup status + backfill/retry — absorbed
    /// `BackupMirrorCoordinator` and the mirror half of `ChangeBusConsumer`.
    public let backup: BackupStatusStore
    /// Debounced change-bus re-export consumer; nil when there's no
    /// disk-backed storage to export from (fixtures/preview/soak).
    private let changeBusConsumer: ChangeBusConsumer?
    /// `NSApplication.didBecomeActiveNotification` token for
    /// `observeAppForegroundRefresh()`. Held for the process lifetime (see
    /// `FloatingIndicatorController`'s identical no-deinit-teardown
    /// reasoning) — `AppStores` is owned by the App struct and never
    /// released while the process runs.
    @ObservationIgnored private var foregroundRefreshToken: NSObjectProtocol?

    // MARK: Inert launch-argument carriers (parsed, not yet consumed)

    /// The fixture scenario from `-fixtures <name>` ("default" when bare).
    /// Only "default" behavior exists today — carried for the
    /// fixture-scenarios work. `nil` outside the fixtures graph.
    public let fixtureScenario: String?
    /// The route from `-open <route>`, not yet applied anywhere — carried
    /// for the launch-routing work.
    public let launchRoute: Route?
    /// The directory from `-seed-dir <path>`. Normal-mode only: at init, its
    /// contents are copied into a throwaway temp dir and the real storage
    /// stack (`LibraryStorage`, `SearchIndex`) is rooted there instead of the
    /// user's real library — see the `-seed-dir` handling in `init(configuration:)`.
    /// Ignored in `-fixtures`/`-soak` graphs, which never touch this field.
    public let launchSeedDir: URL?

    /// Fresh, isolated `UserDefaults` for `BackupStatusStore`'s
    /// "stuck since" persistence in fixture/soak graphs — neither ever
    /// wants to read or leave behind state in the user's real defaults.
    private static func ephemeralBackupDefaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: "recap.ephemeral.fixtures.backup") ?? .standard
        suite.removePersistentDomain(forName: "recap.ephemeral.fixtures.backup")
        return suite
    }

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
        let makeCallAudioMonitor: () -> CallAudioMonitoring?
        let todayEventsProvider: @MainActor (Date) -> [CalendarEventSnapshot]
        let makeCallStartNotifier: (
            _ recordTapped: @escaping @MainActor (MeetingNudge) -> Void,
            _ onDismissed: @escaping @MainActor () -> Void
        ) -> CallStartNotifying?
        var fixtureScenarioValue: FixtureScenario?
        let backup: BackupStatusStore
        if case .fixtures = configuration.mode {
            let scenario = FixtureScenario(rawScenario: fixtureScenario ?? "default")
            fixtureScenarioValue = scenario
            settings = .ephemeralOnboarded()
            library = scenario.library
            models = WhisperModelManager()
            setup = TranscriptionSetupStore(models: models, settings: settings)
            // `recording` (Phase 3C) needs a session that actually looks
            // mid-recording so `RecordingView` + the docked `SessionCapsule`
            // have something to render — see `FixtureScenarios.recordingSession(activeIn:)`.
            session = scenario == .recording ? FixtureScenarios.recordingSession(activeIn: library) : MeetingSessionStore()
            queue = nil
            storage = nil
            changeBus = LibraryChangeBus()
            upcoming = scenario.upcoming
            makeCallAudioMonitor = { nil }
            todayEventsProvider = { _ in [] }
            makeCallStartNotifier = { _, _ in nil }
            backup = BackupStatusStore(
                settings: settings, library: library, storage: nil, defaults: Self.ephemeralBackupDefaults()
            )
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
            self.library = library
            models = WhisperModelManager()
            setup = TranscriptionSetupStore(models: models, settings: settings)
            self.storage = storage
            self.changeBus = changeBus
            session = MeetingSessionStore(makeRecorder: {
                MeetingRecorder(mic: SyntheticMicSource(), makeSystemTap: { SyntheticSystemAudioSource() })
            })
            queue = nil
            upcoming = .live()
            makeCallAudioMonitor = { nil }
            todayEventsProvider = { _ in [] }
            makeCallStartNotifier = { _, _ in nil }
            backup = BackupStatusStore(
                settings: settings, library: library, storage: storage, defaults: Self.ephemeralBackupDefaults()
            )
            let session = self.session
            Task { @MainActor in
                guard let record = library.startNewMeeting(title: "Soak recording") else { return }
                await session.start(record: record, engine: nil, includeSystemAudio: true, includeMic: true)
            }
        } else {
            let settings = SettingsStore()
            // `-seed-dir <path>`: copy the given library folder into a
            // throwaway temp dir and root the real storage stack there
            // instead of the user's real library, so a problem library can
            // be reproduced deterministically without ever writing to the
            // source. Falls back to normal storage (real root, real index)
            // when the source is missing/unreadable or the copy fails —
            // `SeedLibrary.prepare` already logs the reason.
            let seededRoot = configuration.seedDir.flatMap { SeedLibrary.prepare(source: $0) }
            let storageRoot = seededRoot ?? settings.saveRootURL
            let storage = LibraryStorage(rootURL: storageRoot)
            let indexDatabaseURL = seededRoot?.appendingPathComponent("index.db") ?? SearchIndex.defaultDatabaseURL
            let index = (try? SearchIndex(databaseURL: indexDatabaseURL)) ?? (try! SearchIndex())
            let changeBus = LibraryChangeBus()
            let library = LibraryStore(storage: storage, index: index, changeBus: changeBus)
            let models = WhisperModelManager()
            self.settings = settings
            self.library = library
            self.models = models
            setup = TranscriptionSetupStore(models: models, settings: settings)
            self.storage = storage
            self.changeBus = changeBus
            session = MeetingSessionStore()
            upcoming = .live()
            makeCallAudioMonitor = { ProcessAudioMonitor() }
            let calendarQuery = CalendarWatcher(onMeetingStarting: { _ in })
            todayEventsProvider = { calendarQuery.todayEvents(now: $0) }
            let toasts = toasts
            let router = router
            notificationRouter.install()
            let notifier = CompletionNotifier(
                router: notificationRouter,
                onOpenMeeting: { [weak library] id in
                    // Mirrors `AppStores.showMeeting(_:)`, inlined: `self`
                    // isn't fully initialized yet at this point in `init`. A
                    // completion notification only ever fires for a meeting
                    // that just finished processing, so it's never the
                    // active recording — always route straight to `.detail`.
                    router.screen = .detail(meetingID: id)
                    library?.selectedMeetingID = id
                    NSApp.activate(ignoringOtherApps: true)
                },
                isMeetingCurrentlyVisible: { [weak library] in
                    NSApp.isActive && router.screen == .detail(meetingID: $0) && library?.selectedMeetingID == $0
                }
            )
            completionNotifier = notifier
            let notificationRouter = notificationRouter
            makeCallStartNotifier = { recordTapped, onDismissed in
                CallStartNotifier(router: notificationRouter, recordTapped: recordTapped, onDismissed: onDismissed)
            }
            let backupStore = BackupStatusStore(settings: settings, library: library, storage: storage)
            backup = backupStore
            queue = QueueStore(
                library: library, storage: storage, models: models, changeBus: changeBus,
                settings: settings, backup: backupStore,
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
        }
        self.backup = backup

        let coordinators = Self.makeCoordinators(
            settings: settings, storage: storage, library: library, models: models,
            session: session, queue: queue, router: router, toasts: toasts,
            makeCalendarWatcher: { CalendarWatcher(onMeetingStarting: $0) },
            makeCallAudioMonitor: makeCallAudioMonitor,
            todayEventsProvider: todayEventsProvider,
            makeCallStartNotifier: makeCallStartNotifier
        )
        recording = coordinators.recording
        importer = coordinators.importer
        autoRecord = coordinators.autoRecord

        if configuration.mode == .normal, let storage {
            changeBusConsumer = ChangeBusConsumer(
                changeBus: changeBus, storage: storage, backup: backup, exportDebounce: .seconds(5)
            )
        } else {
            changeBusConsumer = nil
        }
        // The `backupStuck` fixture scenario has no real backup pipeline
        // behind it — override the derived state directly so the footer
        // renders the stuck variant for screenshots.
        if let fixtureScenarioValue, fixtureScenarioValue == .backupStuck {
            backup.setStateForFixtures(.stuck(reason: .folderUnreachable, since: Date(timeIntervalSinceNow: -2 * 86400)))
        }
        // `recording`: route straight to the full-window recording screen so
        // `-fixtures recording` renders `RecordingView` + the docked
        // `SessionCapsule` immediately instead of landing on the Library
        // screen first. `session.activeRecord` populates asynchronously
        // (`FixtureScenarios.recordingSession(activeIn:)` awaits `session.start`),
        // so `RootView` briefly shows Library before flipping over — same as
        // any real "just started recording" launch.
        if let fixtureScenarioValue, fixtureScenarioValue == .recording {
            router.screen = .recording
        }
        if configuration.mode == .normal {
            recording.registerGlobalControls()
            autoRecord.applyCalendarAutoRecordSetting()
            setup.start()
            changeBusConsumer?.start()
            // Granting calendar access in Settings refreshes `upcoming`
            // itself (`SettingsPrivacyTab`); this covers the other stale-agenda
            // path — switching back to Recap after granting access in the
            // System Settings pane directly, or just after time has passed.
            observeAppForegroundRefresh()
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
        setup = TranscriptionSetupStore(models: models, settings: settings)
        session = MeetingSessionStore()
        queue = nil
        storage = nil
        changeBus = LibraryChangeBus()
        upcoming = .fixture()
        backup = BackupStatusStore(
            settings: settings, library: library, storage: nil, defaults: Self.ephemeralBackupDefaults()
        )
        let coordinators = Self.makeCoordinators(
            settings: settings, storage: nil, library: library, models: models,
            session: session, queue: nil, router: router, toasts: toasts,
            makeCalendarWatcher: { CalendarWatcher(onMeetingStarting: $0) },
            makeCallAudioMonitor: { nil },
            todayEventsProvider: { _ in [] }
        )
        recording = coordinators.recording
        importer = coordinators.importer
        autoRecord = coordinators.autoRecord
        changeBusConsumer = nil
    }

    /// Test/fixture seam: every dependency injectable, side-effectful
    /// registrations (hot key, calendar watcher) optional. The disk-backed
    /// `init(configuration:)` above keeps its own construction (it needs the
    /// hot-key and `onAutoStop` wiring the production path relies on) but
    /// shares this initializer's storage/behavior contract — the change-bus
    /// consumer runs here too whenever `storage != nil`, which is what
    /// `AppStoresTests` exercises.
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
        registersForegroundRefresh: Bool = false,
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
        setup = TranscriptionSetupStore(models: models, settings: settings)
        self.session = session
        self.queue = queue
        self.changeBus = changeBus
        self.upcoming = upcoming
        let backup = BackupStatusStore(settings: settings, library: library, storage: storage)
        self.backup = backup

        let coordinators = Self.makeCoordinators(
            settings: settings, storage: storage, library: library, models: models,
            session: session, queue: queue, router: router, toasts: toasts,
            makeCalendarWatcher: makeCalendarWatcher,
            makeCallAudioMonitor: makeCallAudioMonitor,
            todayEventsProvider: todayEventsProvider
        )
        recording = coordinators.recording
        importer = coordinators.importer
        autoRecord = coordinators.autoRecord

        if registersHotKey {
            recording.registerGlobalControls()
            autoRecord.applyCalendarAutoRecordSetting()
        }
        if let storage {
            let consumer = ChangeBusConsumer(
                changeBus: changeBus, storage: storage, backup: backup, exportDebounce: exportDebounce
            )
            changeBusConsumer = consumer
            consumer.start()
        } else {
            changeBusConsumer = nil
        }
        if registersForegroundRefresh {
            observeAppForegroundRefresh()
        }
    }

    // MARK: Foreground refresh

    /// Re-queries the calendar whenever Recap comes back to the foreground,
    /// so switching back after granting calendar access in System Settings
    /// (rather than through Recap's own Settings, which refreshes directly)
    /// doesn't leave the Library's Upcoming agenda stuck showing
    /// "Connect your calendar" until the next 30s poll. Same
    /// no-deinit-teardown reasoning as `FloatingIndicatorController`:
    /// `AppStores` is owned by the App struct for the whole process
    /// lifetime, so there's no "controller goes away" case to clean up for.
    private func observeAppForegroundRefresh() {
        foregroundRefreshToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.upcoming.refresh()
            }
        }
    }

    /// Builds the per-subsystem coordinators around the store graph — the
    /// one place the coordinator wiring (including the recording hooks the
    /// auto-record coordinator needs) is spelled out, shared by all inits.
    private static func makeCoordinators(
        settings: SettingsStore,
        storage: LibraryStorage?,
        library: LibraryStore,
        models: WhisperModelManager,
        session: MeetingSessionStore,
        queue: QueueStore?,
        router: AppRouter,
        toasts: ToastCenter,
        makeCalendarWatcher: @escaping (@escaping @MainActor (CalendarEventSnapshot) -> Void) -> MeetingEventWatching,
        makeCallAudioMonitor: @escaping () -> CallAudioMonitoring?,
        todayEventsProvider: @escaping @MainActor (Date) -> [CalendarEventSnapshot],
        makeCallStartNotifier: @escaping (
            _ recordTapped: @escaping @MainActor (MeetingNudge) -> Void,
            _ onDismissed: @escaping @MainActor () -> Void
        ) -> CallStartNotifying? = { _, _ in nil }
    ) -> (
        recording: RecordingController, importer: ImportCoordinator, autoRecord: AutoRecordCoordinator
    ) {
        let recording = RecordingController(
            session: session, library: library, models: models, settings: settings,
            toasts: toasts, queue: queue,
            showMeeting: { id in
                // Mirrors `AppStores.showMeeting(_:)` without capturing the
                // not-yet-initialized `AppStores`. `RecordingController`
                // calls this right after a recording starts (routes to the
                // full-window `.recording` placeholder) and right after one
                // stops (by which point `session.activeRecord` is already
                // nil, so it routes to `.detail` of the finished meeting).
                router.screen = session.activeRecord?.meeting.id == id ? .recording : .detail(meetingID: id)
                library.selectedMeetingID = id
            }
        )
        let importer = ImportCoordinator(storage: storage, queue: queue, library: library, toasts: toasts)
        let autoRecord = AutoRecordCoordinator(
            settings: settings, session: session,
            makeCalendarWatcher: makeCalendarWatcher,
            makeCallAudioMonitor: makeCallAudioMonitor,
            todayEventsProvider: todayEventsProvider,
            startRecording: { title, attendees in recording.startRecording(title: title, attendees: attendees) },
            stopRecording: { recording.stopRecording() },
            makeCallStartNotifier: makeCallStartNotifier
        )
        return (recording, importer, autoRecord)
    }

    // MARK: Cross-store seams

    /// Moves a meeting to Trash and cancels any still-pending queue work for
    /// it — the library row's "Move to Trash" context-menu action. `AppStores`
    /// is the one place that sees both `library` and `queue`, so it's the seam
    /// that keeps them in sync rather than teaching `LibraryStore` about the
    /// queue. `queue` is nil in the fixtures graph, where trashing already
    /// no-ops (no real folder to trash for a `/dev/null` fixture record).
    public func moveToTrash(_ record: MeetingRecord) {
        library.moveToTrash(record)
        queue?.cancel(meetingID: record.meeting.id)
    }

    /// Navigates to a meeting (used by the menu bar extra's jump items, and
    /// `SettingsPrivacyTab`'s backup-fix deep link). Routes to the
    /// full-window `.recording` placeholder when `id` is the meeting
    /// currently being recorded, otherwise to its `.detail` screen.
    public func showMeeting(_ id: UUID) {
        router.screen = session.activeRecord?.meeting.id == id ? .recording : .detail(meetingID: id)
        library.selectedMeetingID = id
    }

    /// Brings the main window forward (recreating it if it was closed).
    /// `openWindow` is a SwiftUI Environment value only available in a
    /// view/scene context, so callers (the ⌘, command, the menu bar extra)
    /// pass theirs in rather than this living on `AppStores`.
    public func openMainWindow(openWindow: (String) -> Void) {
        openWindow("main")
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Coordinator forwarders (pre-decomposition public API)

    public func startRecording(title: String = "Untitled meeting", attendees: [String] = []) {
        recording.startRecording(title: title, attendees: attendees)
    }

    public func stopRecording() { recording.stopRecording() }
    public func toggleRecording() { recording.toggleRecording() }
    public func pauseRecording() { recording.pauseRecording() }
    public func resumeRecording() { recording.resumeRecording() }
    public func togglePause() { recording.togglePause() }

    public func importAudioFiles(_ urls: [URL]) { importer.importAudioFiles(urls) }

    public func applyCalendarAutoRecordSetting() { autoRecord.applyCalendarAutoRecordSetting() }

    /// True when calendar auto-record is enabled in Settings but macOS
    /// calendar access was denied — surfaced as a warning there. Tracked on
    /// the (also `@Observable`) coordinator, so reads through this forwarder
    /// still register observation.
    public var calendarAccessDenied: Bool { autoRecord.calendarAccessDenied }

    /// Internal test seam, forwarded (see `AutoRecordCoordinator`).
    func meetingEventStarting(_ event: CalendarEventSnapshot) { autoRecord.meetingEventStarting(event) }

    /// Test-only nudge-presentation hook, forwarded (see `AutoRecordCoordinator`).
    var onNudgePresented: ((MeetingNudge) -> Void)? {
        get { autoRecord.onNudgePresented }
        set { autoRecord.onNudgePresented = newValue }
    }

    public func backfillMirrorBackup() { backup.backfill() }
}
