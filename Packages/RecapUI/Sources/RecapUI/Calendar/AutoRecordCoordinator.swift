import Foundation
import Observation
import RecapAudio
import RecapCore

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

/// Calendar auto-record policy + the "Meeting started?" nudge (design mock
/// 9b): calendar watcher, call-audio monitor, and the nudge center/panel
/// pair. Extracted from `AppStores`, which exposes it as `stores.autoRecord`
/// and keeps thin forwarders (`applyCalendarAutoRecordSetting`,
/// `calendarAccessDenied`) for existing call sites.
@MainActor
@Observable
public final class AutoRecordCoordinator {
    /// True when calendar auto-record is enabled in Settings but macOS
    /// calendar access was denied — surfaced as a warning there.
    public private(set) var calendarAccessDenied = false

    @ObservationIgnored private var calendarWatcher: MeetingEventWatching?
    /// Factory for the calendar seam, defaulting to the real type in the
    /// production path; tests substitute a fake via the injected init.
    @ObservationIgnored private let makeCalendarWatcher: (@escaping @MainActor (CalendarEventSnapshot) -> Void) -> MeetingEventWatching

    /// The "Meeting started?" nudge — trigger/dedupe brain plus its
    /// top-right slide-in panel. Built lazily by
    /// `applyCalendarAutoRecordSetting()` the first time policy != `.off`,
    /// and torn down (monitor stopped, panel dismissed) when it flips back
    /// to `.off`.
    @ObservationIgnored private var nudgeCenter: MeetingNudgeCenter?
    @ObservationIgnored private var nudgePanel: MeetingNudgePanelController?
    @ObservationIgnored private var callStartNotifier: CallStartNotifying?
    /// Factory for the call-start system-notification seam: builds a real
    /// `CallStartNotifier` wired to the shared `NotificationRouter` in the
    /// production graph, `nil` in fixtures/soak/preview and the test init's
    /// default (mirrors `makeCallAudioMonitor`'s no-op-gracefully-on-nil
    /// shape). Takes the same `recordTapped`/`onDismissed` closures
    /// `ensureNudgeCenter()` wires the panel to, so both surfaces share one
    /// action path.
    @ObservationIgnored private let makeCallStartNotifier: (
        _ recordTapped: @escaping @MainActor (MeetingNudge) -> Void,
        _ onDismissed: @escaping @MainActor () -> Void
    ) -> CallStartNotifying?
    @ObservationIgnored private var callAudioMonitor: CallAudioMonitoring?
    /// Factory for the call-audio monitor seam: `ProcessAudioMonitor` in the
    /// production graph, `{ nil }` in fixtures/soak/preview and the test
    /// init's default — the wiring no-ops gracefully on nil.
    @ObservationIgnored private let makeCallAudioMonitor: () -> CallAudioMonitoring?
    /// Injectable source of "today's remaining calendar events", used by the
    /// nudge center to find a calendar match for a call-audio trigger.
    @ObservationIgnored private let todayEventsProvider: @MainActor (Date) -> [CalendarEventSnapshot]
    /// Test-only hook: when set, `presentNudge` calls this instead of
    /// driving a real `NSPanel`, so tests can assert on presented nudges
    /// without a panel ever appearing on screen.
    @ObservationIgnored var onNudgePresented: ((MeetingNudge) -> Void)?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let session: MeetingSessionStore
    /// Recording hooks into `RecordingController`, injected as closures to
    /// keep the coordinators decoupled.
    @ObservationIgnored private let startRecording: @MainActor (String, [String]) -> Void
    @ObservationIgnored private let stopRecording: @MainActor () -> Void

    init(
        settings: SettingsStore,
        session: MeetingSessionStore,
        makeCalendarWatcher: @escaping (@escaping @MainActor (CalendarEventSnapshot) -> Void) -> MeetingEventWatching,
        makeCallAudioMonitor: @escaping () -> CallAudioMonitoring?,
        todayEventsProvider: @escaping @MainActor (Date) -> [CalendarEventSnapshot],
        startRecording: @escaping @MainActor (String, [String]) -> Void,
        stopRecording: @escaping @MainActor () -> Void,
        makeCallStartNotifier: @escaping (
            _ recordTapped: @escaping @MainActor (MeetingNudge) -> Void,
            _ onDismissed: @escaping @MainActor () -> Void
        ) -> CallStartNotifying? = { _, _ in nil }
    ) {
        self.settings = settings
        self.session = session
        self.makeCalendarWatcher = makeCalendarWatcher
        self.makeCallAudioMonitor = makeCallAudioMonitor
        self.todayEventsProvider = todayEventsProvider
        self.startRecording = startRecording
        self.stopRecording = stopRecording
        self.makeCallStartNotifier = makeCallStartNotifier
    }

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
            callStartNotifier?.dismissLastDelivered()
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
    /// entry points. Also builds the call-start system notification (when a
    /// factory is injected) sharing the same `recordTapped` action path, so
    /// the panel's Record button and the notification's Record action both
    /// end up calling `center.recordTapped(for:)`.
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
                self?.startRecording(title, attendees)
            }
        )
        panel.onRecord = { [weak self, weak center] nudge in
            center?.recordTapped(for: nudge)
            self?.callStartNotifier?.dismissLastDelivered()
        }
        panel.onNotNow = { [weak self, weak center] nudge in
            center?.notNowTapped(for: nudge)
            self?.callStartNotifier?.dismissLastDelivered()
        }
        panel.onDontAsk = { [weak self, weak center] appID in
            center?.dontAskTapped(appID: appID) { appID in
                self?.settings.disabledCallAppIDs.insert(appID)
                self?.applyCalendarAutoRecordSetting()
            }
            self?.callStartNotifier?.dismissLastDelivered()
        }
        panel.onStop = { [weak self] in self?.stopRecording() }
        nudgeCenter = center
        nudgePanel = panel
        callStartNotifier = makeCallStartNotifier(
            { [weak center] nudge in center?.recordTapped(for: nudge) },
            { [weak panel] in panel?.dismiss() }
        )
    }

    /// Presents a nudge — through the test hook when one's installed (tests
    /// must never construct a real `NSPanel`), otherwise through the real
    /// panel controller. Also fans out to the call-start system notification
    /// (when one's configured) so a single trigger yields exactly one panel
    /// presentation and one notification — never a double in-app prompt,
    /// since `present` only ever fires once per `MeetingNudgeCenter`
    /// decision (dedup already happened upstream).
    private func presentNudge(_ nudge: MeetingNudge) {
        if let onNudgePresented {
            onNudgePresented(nudge)
        } else {
            nudgePanel?.present(nudge)
        }
        callStartNotifier?.post(nudge)
    }
}
