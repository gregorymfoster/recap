import AppKit
import Foundation
import RecapAudio
import RecapCore
import RecapTranscription
import Testing
@testable import RecapUI

/// Fake mic/system-audio sources for the `startRecording` preflight-gate
/// tests below, so a `MeetingRecorder` can actually run `start()`/`stop()`
/// without touching real hardware.
@MainActor
private final class FakeMicSourceForGateTest: MicCapturing {
    var preferredInputUID: String?
    var onRebuild: (@MainActor (String) -> Void)?
    var activeDeviceName: String? = "Fake Mic"
    private var continuation: AsyncStream<[Float]>.Continuation?

    func start() throws -> AsyncStream<[Float]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [Float].self)
        self.continuation = continuation
        return stream
    }

    func stop() {
        continuation?.finish()
        continuation = nil
    }
}

@MainActor
private final class FakeSystemAudioSourceForGateTest: SystemAudioCapturing {
    private var continuation: AsyncStream<[Float]>.Continuation?

    func start() async throws -> AsyncStream<[Float]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [Float].self)
        self.continuation = continuation
        return stream
    }

    func stop() {
        continuation?.finish()
        continuation = nil
    }
}

/// Fake `MeetingEventWatching`: `start()` returns a configurable grant
/// result and never touches EventKit; `fire(_:)` lets tests simulate a
/// meeting-shaped event starting.
@MainActor
private final class FakeCalendarWatcher: MeetingEventWatching {
    var grantsAccess = true
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private let onMeetingStarting: (CalendarEventSnapshot) -> Void

    init(onMeetingStarting: @escaping (CalendarEventSnapshot) -> Void) {
        self.onMeetingStarting = onMeetingStarting
    }

    func start() async -> Bool {
        startCallCount += 1
        return grantsAccess
    }

    func stop() {
        stopCallCount += 1
    }

    func fire(_ event: CalendarEventSnapshot) {
        onMeetingStarting(event)
    }
}

// Serialized: these tests exercise real elapsed-time behavior (debounce
// windows, change-bus subscription races) via ContinuousClock/Task.sleep.
// Swift Testing parallelizes every @Test in a suite by default, and on a
// shared/CPU-constrained CI runner that contention can stretch Task.sleep
// scheduling by 2x+ (observed: nominal 60s retry budgets manifesting as
// ~120-270s of real wall-clock time in CI logs) — enough to blow through
// even generous internal timeouts. Running this suite's tests one at a
// time removes that contention at the source, which is more robust than
// continuing to raise timeout constants to chase an inflating multiplier.
@MainActor
@Suite(.serialized) struct AppStoresTests {
    private func makeStorage() -> LibraryStorage {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStoresTests-\(UUID().uuidString)")
        return LibraryStorage(rootURL: root)
    }

    private func makeSettings() -> SettingsStore {
        let suite = UserDefaults(suiteName: "recap.tests.appstores.\(UUID().uuidString)")!
        suite.removePersistentDomain(forName: suite.dictionaryRepresentation().description)
        return SettingsStore(defaults: suite)
    }

    private func makeIndex() -> SearchIndex {
        try! SearchIndex()
    }

    /// Session whose preflight always proceeds mic-only, without touching
    /// real mic permission or the system-audio tap — the default for
    /// `makeStores()` scenarios that don't care about audio-gate behavior
    /// (calendar auto-record, exports, etc.) and just need `startRecording`
    /// to actually create a library meeting.
    private func makeAlwaysProceedsSession() -> MeetingSessionStore {
        MeetingSessionStore(
            makeRecorder: { MeetingRecorder(mic: FakeMicSourceForGateTest(), makeSystemTap: { FakeSystemAudioSourceForGateTest() }) },
            requestMicPermission: { true },
            probeSystemAudio: { .captured }
        )
    }

    /// Full graph with real disk-backed storage, matching what `AppStoresTests`
    /// scenarios need (export/backfill behavior requires `storage != nil`).
    /// Always wires `onNudgePresented` to a capture array — real `NSPanel`s
    /// must never appear during `swift test`, so every scenario that reaches
    /// `presentNudge` needs this hook installed before `applyCalendarAutoRecordSetting()`
    /// is called.
    private func makeStores(
        settings: SettingsStore? = nil,
        storage: LibraryStorage? = nil,
        session: MeetingSessionStore? = nil,
        exportDebounce: Duration = .milliseconds(50),
        makeCalendarWatcher: ((@escaping @MainActor (CalendarEventSnapshot) -> Void) -> MeetingEventWatching)? = nil,
        presentedNudges: PresentedNudges? = nil
    ) -> (AppStores, LibraryStorage, SettingsStore, LibraryChangeBus) {
        let settings = settings ?? makeSettings()
        let storage = storage ?? makeStorage()
        let session = session ?? makeAlwaysProceedsSession()
        let changeBus = LibraryChangeBus()
        let index = makeIndex()
        let library = LibraryStore(storage: storage, index: index, changeBus: changeBus)

        let stores: AppStores
        if let makeCalendarWatcher {
            stores = AppStores(
                settings: settings, storage: storage, library: library,
                models: WhisperModelManager(), session: session, queue: nil,
                changeBus: changeBus, exportDebounce: exportDebounce,
                makeCalendarWatcher: makeCalendarWatcher
            )
        } else {
            stores = AppStores(
                settings: settings, storage: storage, library: library,
                models: WhisperModelManager(), session: session, queue: nil,
                changeBus: changeBus, exportDebounce: exportDebounce
            )
        }
        if let presentedNudges {
            stores.onNudgePresented = { nudge in presentedNudges.nudges.append(nudge) }
        }
        return (stores, storage, settings, changeBus)
    }

    /// Test-only capture box for nudges presented via `AppStores.onNudgePresented`
    /// — a class so the closure above and the test assertion share the same
    /// storage without fighting Swift's value-capture rules.
    @MainActor
    private final class PresentedNudges {
        var nudges: [MeetingNudge] = []
    }

    private func makeReadyMeeting(in storage: LibraryStorage, title: String = "Standup") throws -> MeetingRecord {
        try storage.create(Meeting(title: title, date: .now, status: .ready))
    }

    /// Polls for a directory to appear with at least one entry, up to
    /// `timeout`. Exports run on detached background tasks after the
    /// debounce window, so a single fixed sleep is prone to flaking under
    /// parallel test load — poll instead of guessing one wait long enough.
    /// The default is generous (well beyond what a healthy machine needs)
    /// because Swift Testing runs every `@Test` in this file concurrently,
    /// and a shared, CPU-constrained CI runner can stretch `Task.sleep`
    /// scheduling by an order of magnitude under that contention.
    private func waitForNonEmptyDirectory(
        at url: URL, timeout: Duration = .seconds(30)
    ) async throws -> [String] {
        try await waitForDirectory(at: url, timeout: timeout) { !$0.isEmpty }
    }

    private func waitForDirectory(
        at url: URL, timeout: Duration = .seconds(30),
        until predicate: ([String]) -> Bool
    ) async throws -> [String] {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: url.path), predicate(entries) {
                return entries
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
    }

    /// Posts `change` on `changeBus`, then keeps re-posting it (spaced
    /// `retryInterval` apart, which must be longer than the store's
    /// `exportDebounce` or every retry would cancel the previous post's
    /// still-pending debounce Task before it can fire) until `vaultDir`
    /// gets an entry or `timeout` elapses. Guards against the very first
    /// post landing before the change-bus consumer's `Task` has actually
    /// been scheduled and subscribed — `LibraryChangeBus.post` silently
    /// drops changes with no live subscriber, and under CI-runner
    /// contention a freshly spawned `Task` can take well over a few tens of
    /// milliseconds to run its first iteration.
    private func withRetriedPost(
        _ changeBus: LibraryChangeBus, _ change: LibraryChange, until vaultDir: URL,
        retryInterval: Duration = .seconds(1), timeout: Duration = .seconds(60)
    ) async throws -> [String] {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            changeBus.post(change)
            let entries = try await waitForDirectory(at: vaultDir, timeout: retryInterval) { !$0.isEmpty }
            if !entries.isEmpty {
                return entries
            }
        }
        return (try? FileManager.default.contentsOfDirectory(atPath: vaultDir.path)) ?? []
    }

    /// Blocks until `stores`'s change-bus consumer `Task` (spawned in
    /// `init`) has demonstrably subscribed, by posting a throwaway change
    /// for an unrelated meeting and waiting for its mirror-backup export to
    /// land in a scratch directory — then cleans up (resets the mirror
    /// toggle) so it doesn't share mutable settings state with a caller
    /// that's mid-way through asserting export timing at a different
    /// destination: `runEnabledExporters` reads `settings` live at fire time,
    /// so flipping a shared `mirrorFolderPath` back and forth while a canary
    /// debounce Task might still be in flight is itself a race. Tests that
    /// assert timing around a real post (e.g. "no export before the debounce
    /// window elapses") need the consumer warmed up first without the
    /// warm-up racing the assertion; a fixed sleep isn't reliable under
    /// CI-runner contention where the consumer's Task may not run its first
    /// loop iteration for a while.
    private func waitForConsumerSubscribed(
        stores: AppStores, changeBus: LibraryChangeBus, storage: LibraryStorage, settings: SettingsStore
    ) async throws {
        let canaryDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Canary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: canaryDir) }
        precondition(!settings.mirrorBackupEnabled, "warm-up uses the mirror toggle; caller must not also use it")
        settings.mirrorBackupEnabled = true
        settings.mirrorFolderPath = canaryDir.path
        let canary = try makeReadyMeeting(in: storage, title: "Canary")
        _ = try await withRetriedPost(changeBus, .meetingChanged(canary.meeting.id), until: canaryDir)
        settings.mirrorBackupEnabled = false
        settings.mirrorFolderPath = ""
        // Give any debounce Task that was mid-flight when the last
        // successful poll observed the export a moment to actually finish
        // and get removed from exportDebounceTasks, so it can't race a
        // later post for a different meeting ID (each meeting has its own
        // debounce entry, so this is a belt-and-suspenders margin, not a
        // strict requirement).
        try await Task.sleep(for: .milliseconds(50))
    }

    // MARK: 1. Change-bus debounced export

    @Test func changeBusPostDebouncesThenExportsMirrorBackup() async throws {
        let mirrorDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MirrorBackup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: mirrorDir) }

        let (stores, storage, settings, changeBus) = makeStores()
        settings.mirrorBackupEnabled = true
        settings.mirrorFolderPath = mirrorDir.path

        let record = try makeReadyMeeting(in: storage)
        _ = stores // keep the consumer task alive via the strong reference below

        // The change-bus consumer subscribes from a freshly spawned Task in
        // `init`, and `LibraryChangeBus.post` doesn't buffer for late
        // subscribers — a post before the consumer's `for await` loop has
        // actually started running is silently dropped. A fixed sleep
        // before the first post isn't reliable on a loaded CI runner (the
        // Task may not get scheduled for a while), so re-post on an interval
        // shorter than the export debounce until the export lands or we
        // time out; once the consumer is subscribed, one of these posts is
        // guaranteed to be seen.
        let exported = try await withRetriedPost(
            changeBus, .meetingChanged(record.meeting.id), until: mirrorDir
        )
        #expect(!exported.isEmpty)
    }

    @Test func rapidChangeBusPostsCoalesceIntoOneExportWindow() async throws {
        let mirrorDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MirrorBackup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: mirrorDir) }

        // A generous debounce (vs. the 50ms used elsewhere) gives wide
        // margins around the mid-sequence checks below, so CPU contention
        // under parallel test execution can't shrink the gap between "second
        // post lands" and "debounce would have elapsed" into noise.
        let debounce = Duration.milliseconds(500)
        let (stores, storage, settings, changeBus) = makeStores(exportDebounce: debounce)
        let record = try makeReadyMeeting(in: storage)
        _ = stores // keep the consumer task alive via the strong reference

        // Warm up the consumer against a throwaway destination first — before
        // pointing the mirror at mirrorDir below — so the timed sequence
        // isn't itself racing the consumer's Task getting scheduled, and so
        // the warm-up's own export can't land in mirrorDir (see
        // waitForConsumerSubscribed).
        try await waitForConsumerSubscribed(stores: stores, changeBus: changeBus, storage: storage, settings: settings)

        settings.mirrorBackupEnabled = true
        settings.mirrorFolderPath = mirrorDir.path

        changeBus.post(.meetingChanged(record.meeting.id))
        // Posted again well inside the debounce window: this should cancel
        // and restart the sleep, so nothing has exported yet shortly after.
        try await Task.sleep(for: debounce / 4)
        changeBus.post(.meetingChanged(record.meeting.id))

        // Checked at roughly half the (restarted) window — comfortably
        // before it can have elapsed even under heavy scheduling jitter.
        try await Task.sleep(for: debounce / 2)
        #expect(!FileManager.default.fileExists(atPath: mirrorDir.path))

        let exported = try await waitForNonEmptyDirectory(at: mirrorDir)
        #expect(exported.count == 1)
    }

    // MARK: 2. backfillMirrorBackup only exports ready meetings

    @Test func backfillMirrorBackupExportsOnlyReadyOnes() async throws {
        let mirrorDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MirrorBackup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: mirrorDir) }

        let (stores, storage, settings, _) = makeStores()
        settings.mirrorBackupEnabled = true
        settings.mirrorFolderPath = mirrorDir.path

        _ = try storage.create(Meeting(title: "Ready one", date: .now, status: .ready))
        _ = try storage.create(Meeting(title: "Ready two", date: .now, status: .ready))
        _ = try storage.create(Meeting(title: "Still recording", date: .now, status: .recording))
        stores.library.reload()

        stores.backfillMirrorBackup()

        let exported = try await waitForDirectory(at: mirrorDir) { $0.count == 2 }
        #expect(exported.count == 2)
    }

    @Test func backfillMirrorBackupNoOpWhenDisabledOrPathEmpty() async throws {
        let (stores, storage, settings, _) = makeStores()
        settings.mirrorBackupEnabled = false
        settings.mirrorFolderPath = ""
        _ = try storage.create(Meeting(title: "Ready one", date: .now, status: .ready))
        stores.library.reload()

        // Should not crash and should not attempt any export (no folder path
        // to check — absence of a crash and immediate return is the contract).
        stores.backfillMirrorBackup()
        try await Task.sleep(for: .milliseconds(100))
    }

    @Test func backfillMirrorBackupMirrorsReadyMeetings() async throws {
        let mirrorDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MirrorBackup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: mirrorDir) }

        let (stores, storage, settings, _) = makeStores()
        settings.mirrorBackupEnabled = true
        settings.mirrorFolderPath = mirrorDir.path

        _ = try storage.create(Meeting(title: "Ready one", date: .now, status: .ready))
        stores.library.reload()

        stores.backfillMirrorBackup()

        let mirrored = try await waitForNonEmptyDirectory(at: mirrorDir)
        #expect(!mirrored.isEmpty)
    }

    // MARK: 4. Calendar auto-record modes

    @Test func promptModeCallsPrompterWhenEventStarts() throws {
        var fakeWatcher: FakeCalendarWatcher?
        let presentedNudges = PresentedNudges()
        let (stores, _, settings, _) = makeStores(
            makeCalendarWatcher: { onStarting in
                let watcher = FakeCalendarWatcher(onMeetingStarting: onStarting)
                fakeWatcher = watcher
                return watcher
            },
            presentedNudges: presentedNudges
        )
        settings.calendarAutoRecord = .prompt
        stores.applyCalendarAutoRecordSetting()
        _ = fakeWatcher

        let event = CalendarEventSnapshot(id: "1", title: "Standup", start: .now, end: .now.addingTimeInterval(1_800))
        stores.meetingEventStarting(event)

        #expect(presentedNudges.nudges == [.ask(appID: nil, appName: nil, match: event)])
    }

    @Test func autoModeCreatesLibraryMeetingWithEventTitle() async throws {
        let presentedNudges = PresentedNudges()
        let (stores, _, settings, _) = makeStores(
            makeCalendarWatcher: { onStarting in FakeCalendarWatcher(onMeetingStarting: onStarting) },
            presentedNudges: presentedNudges
        )
        settings.calendarAutoRecord = .auto
        stores.applyCalendarAutoRecordSetting()

        let event = CalendarEventSnapshot(
            id: "2", title: "Roadmap review", start: .now, end: .now.addingTimeInterval(1_800),
            otherAttendees: ["Maya"]
        )
        stores.meetingEventStarting(event)

        // startRecording's preflight now runs on an async Task before the
        // meeting record is created — poll rather than asserting synchronously.
        let deadline = ContinuousClock.now + .seconds(5)
        while !stores.library.meetings.contains(where: { $0.meeting.title == "Roadmap review" }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(stores.library.meetings.contains { $0.meeting.title == "Roadmap review" })
        // Auto-record also surfaces the recording-started confirmation nudge.
        #expect(presentedNudges.nudges.count == 1)
        if case .recordingStarted(let presentedEvent, _) = presentedNudges.nudges.first {
            #expect(presentedEvent.id == "2")
        } else {
            Issue.record("Expected a .recordingStarted nudge, got \(String(describing: presentedNudges.nudges.first))")
        }
    }

    @Test func offModeIgnoresStartingEvents() throws {
        let presentedNudges = PresentedNudges()
        let (stores, _, settings, _) = makeStores(
            makeCalendarWatcher: { onStarting in FakeCalendarWatcher(onMeetingStarting: onStarting) },
            presentedNudges: presentedNudges
        )
        settings.calendarAutoRecord = .off

        let meetingCountBefore = stores.library.meetings.count
        let event = CalendarEventSnapshot(id: "3", title: "Ignored", start: .now, end: .now.addingTimeInterval(1_800))
        stores.meetingEventStarting(event)

        #expect(presentedNudges.nudges.isEmpty)
        #expect(stores.library.meetings.count == meetingCountBefore)
    }

    @Test func alreadyRecordingIgnoresStartingEvents() async throws {
        let presentedNudges = PresentedNudges()
        let (stores, _, settings, _) = makeStores(
            makeCalendarWatcher: { onStarting in FakeCalendarWatcher(onMeetingStarting: onStarting) },
            presentedNudges: presentedNudges
        )
        settings.calendarAutoRecord = .prompt
        stores.applyCalendarAutoRecordSetting()

        stores.startRecording(title: "In progress")
        // startRecording now runs preflight then start() on an async Task —
        // poll for isRecording rather than guessing a fixed settle time.
        let deadline = ContinuousClock.now + .seconds(5)
        while !stores.session.isRecording, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        let event = CalendarEventSnapshot(id: "4", title: "Should be ignored", start: .now, end: .now.addingTimeInterval(1_800))
        stores.meetingEventStarting(event)

        #expect(presentedNudges.nudges.isEmpty)
    }

    @Test func applyCalendarAutoRecordSettingSurfacesAccessDenied() async throws {
        let (stores, _, settings, _) = makeStores(
            makeCalendarWatcher: { onStarting in
                let watcher = FakeCalendarWatcher(onMeetingStarting: onStarting)
                watcher.grantsAccess = false
                return watcher
            },
            presentedNudges: PresentedNudges()
        )
        settings.calendarAutoRecord = .prompt
        stores.applyCalendarAutoRecordSetting()

        try await Task.sleep(for: .milliseconds(100))
        #expect(stores.calendarAccessDenied == true)

        settings.calendarAutoRecord = .off
        stores.applyCalendarAutoRecordSetting()
        #expect(stores.calendarAccessDenied == false)
    }

    // MARK: 5. showMeeting

    @Test func showMeetingRoutesSectionAndSelection() throws {
        let (stores, _, _, _) = makeStores()
        let id = UUID()
        stores.showMeeting(id)
        #expect(stores.router.section == .library)
        #expect(stores.library.selectedMeetingID == id)
    }

    // MARK: 5b. Upcoming agenda refresh-on-foreground

    /// `@MainActor` reference box counting `UpcomingStore.refresh()` calls —
    /// lets the test assert the foreground observer actually re-queries
    /// without touching real EventKit.
    @MainActor
    private final class RefreshCounter {
        var count = 0
    }

    /// Covers the "app foreground → recalendar refresh" wiring
    /// (`AppStores.observeAppForegroundRefresh()`): posting the real
    /// `NSApplication.didBecomeActiveNotification` (the same notification
    /// macOS posts when Recap regains focus) must call through to
    /// `upcoming.refresh()`, so a user who grants calendar access in System
    /// Settings and switches back to Recap doesn't stay stuck on a stale
    /// "Connect your calendar" agenda until the next 30s poll.
    @Test func appBecomingActiveRefreshesUpcoming() {
        let counter = RefreshCounter()
        let upcoming = UpcomingStore(availability: { true }, provider: { _ in
            counter.count += 1
            return []
        })
        let library = LibraryStore.fixture()
        let stores = AppStores(
            settings: makeSettings(), storage: nil, library: library,
            models: WhisperModelManager(), session: makeAlwaysProceedsSession(), queue: nil,
            changeBus: LibraryChangeBus(), upcoming: upcoming,
            registersForegroundRefresh: true
        )
        _ = stores

        let before = counter.count
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(counter.count == before + 1)
    }

    @Test func withoutRegisteringForegroundRefreshNotificationIsIgnored() {
        let counter = RefreshCounter()
        let upcoming = UpcomingStore(availability: { true }, provider: { _ in
            counter.count += 1
            return []
        })
        let library = LibraryStore.fixture()
        let stores = AppStores(
            settings: makeSettings(), storage: nil, library: library,
            models: WhisperModelManager(), session: makeAlwaysProceedsSession(), queue: nil,
            changeBus: LibraryChangeBus(), upcoming: upcoming,
            registersForegroundRefresh: false
        )
        _ = stores

        let before = counter.count
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(counter.count == before)
    }

    // MARK: 6. importAudioFiles no-op in fixture graph

    @Test func importAudioFilesNoOpWithNilStorageOrQueue() throws {
        let library = LibraryStore.fixture()
        let stores = AppStores(library: library)
        let before = stores.library.meetings.count

        stores.importAudioFiles([URL(fileURLWithPath: "/dev/null/does-not-exist.m4a")])

        #expect(stores.library.meetings.count == before)
    }

    // MARK: 7. startRecording preflight gate

    @Test func startRecordingBlockedPreflightCreatesNoMeetingAndShowsToast() async throws {
        let settings = makeSettings()
        let storage = makeStorage()
        let changeBus = LibraryChangeBus()
        let library = LibraryStore(storage: storage, index: makeIndex(), changeBus: changeBus)
        let session = MeetingSessionStore(
            makeRecorder: { MeetingRecorder() },
            requestMicPermission: { false },
            probeSystemAudio: { .denied }
        )
        let stores = AppStores(
            settings: settings, storage: storage, library: library,
            models: WhisperModelManager(), session: session, queue: nil,
            changeBus: changeBus
        )
        settings.includeSystemAudio = true
        settings.lastSystemAudioTapFailed = nil
        let countBefore = stores.library.meetings.count

        stores.startRecording(title: "Should not be created")

        // preflight runs on an async Task inside startRecording; poll for
        // the toast rather than guessing a fixed sleep.
        let deadline = ContinuousClock.now + .seconds(5)
        while stores.toasts.current == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(stores.toasts.current?.message == RecapCopy.noAudioAccessMessage)
        #expect(stores.library.meetings.count == countBefore)
        #expect(!stores.session.isRecording)
    }

    @Test func startRecordingProceedingPreflightCreatesMeeting() async throws {
        let settings = makeSettings()
        let storage = makeStorage()
        let changeBus = LibraryChangeBus()
        let library = LibraryStore(storage: storage, index: makeIndex(), changeBus: changeBus)
        let session = MeetingSessionStore(
            makeRecorder: {
                MeetingRecorder(
                    mic: FakeMicSourceForGateTest(),
                    makeSystemTap: { FakeSystemAudioSourceForGateTest() }
                )
            },
            requestMicPermission: { true },
            probeSystemAudio: { .captured }
        )
        let stores = AppStores(
            settings: settings, storage: storage, library: library,
            models: WhisperModelManager(), session: session, queue: nil,
            changeBus: changeBus
        )
        settings.includeSystemAudio = false
        settings.lastSystemAudioTapFailed = nil

        stores.startRecording(title: "Should be created")

        let deadline = ContinuousClock.now + .seconds(5)
        while stores.library.meetings.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(stores.library.meetings.contains { $0.meeting.title == "Should be created" })

        stores.stopRecording()
    }
}
