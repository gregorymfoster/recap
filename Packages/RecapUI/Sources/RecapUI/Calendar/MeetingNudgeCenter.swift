import Foundation
import OSLog
import RecapAudio
import RecapCore

private let nudgeLog = Logger(subsystem: "com.gregfoster.recap", category: "MeetingDetection")

/// The trigger/dedupe brain behind the "Meeting started?" nudge (design mock
/// 9b). Fully testable via closures — no `NSPanel`, no EventKit, no CoreAudio
/// touched directly. Two independent triggers feed the same
/// `MeetingDetectionRules.decision` policy: the calendar clock
/// (`calendarEventStarting`) and call-app audio activity (`callAudioEvent`).
@MainActor
public final class MeetingNudgeCenter {
    private let policy: () -> MeetingDetectionRules.Policy
    private let isRecording: () -> Bool
    private let disabledAppIDs: () -> Set<String>
    private let todayEvents: (Date) -> [CalendarEventSnapshot]
    private let present: (MeetingNudge) -> Void
    private let startRecording: (String, [String]) -> Void
    private let now: () -> Date

    /// Keys already acted on so a trigger doesn't re-nudge for the same
    /// thing. Calendar triggers key by event id (stable, one-shot per
    /// event); audio triggers with no calendar match key by `"app:<id>"` so
    /// a single sustained call-audio session only nudges once — cleared on
    /// `.appStoppedAudio` so the *next* session can nudge again.
    private var handledKeys: Set<String> = []

    /// The last nudge presented, so action entry points (`recordTapped`,
    /// `notNowTapped`) know what they're acting on without the caller having
    /// to thread it back through.
    private var lastPresented: MeetingNudge?

    public init(
        policy: @escaping () -> MeetingDetectionRules.Policy,
        isRecording: @escaping () -> Bool,
        disabledAppIDs: @escaping () -> Set<String>,
        todayEvents: @escaping (Date) -> [CalendarEventSnapshot],
        present: @escaping (MeetingNudge) -> Void,
        startRecording: @escaping (String, [String]) -> Void,
        now: @escaping () -> Date = { .now }
    ) {
        self.policy = policy
        self.isRecording = isRecording
        self.disabledAppIDs = disabledAppIDs
        self.todayEvents = todayEvents
        self.present = present
        self.startRecording = startRecording
        self.now = now
    }

    // MARK: Calendar-clock trigger

    /// Fired once per calendar event as its start time arrives (design mock
    /// 9a's clock watcher). Meeting-shaped filtering already happened
    /// upstream (`CalendarWatcher.poll`) — this just runs the shared
    /// decision and dedupes by event id.
    public func calendarEventStarting(_ event: CalendarEventSnapshot) {
        nudgeLog.info("Calendar trigger received")
        let decision = MeetingDetectionRules.decision(
            policy: policy(),
            isRecording: isRecording(),
            appEnabled: true,
            alreadyHandled: handled(event.id),
            match: event
        )
        act(on: decision, triggerKey: event.id, fallbackAppName: nil)
    }

    // MARK: Call-audio trigger

    /// Fired on call-app audio activity changes (design mock 9b's other
    /// trigger). Unknown bundle ids are ignored outright — the audio
    /// monitor only ever reports ids from `CallAppCatalog`, but a defensive
    /// guard costs nothing.
    public func callAudioEvent(_ event: CallAudioEvent) {
        switch event {
        case .appStartedAudio(let bundleID):
            guard let app = CallAppCatalog.app(forBundleID: bundleID) else {
                nudgeLog.info("Audio trigger for unknown bundle id \(bundleID, privacy: .public); ignoring")
                return
            }
            nudgeLog.info("Audio trigger received for \(app.id, privacy: .public)")
            let appEnabled = !disabledAppIDs().contains(app.id)
            let match = MeetingDetectionRules.matchEvent(in: todayEvents(now()), now: now())
            let key = match?.id ?? "app:" + app.id
            let decision = MeetingDetectionRules.decision(
                policy: policy(),
                isRecording: isRecording(),
                appEnabled: appEnabled,
                alreadyHandled: handled(key),
                match: match
            )
            act(on: decision, triggerKey: key, fallbackAppName: app.name, fallbackAppID: app.id)
        case .appStoppedAudio(let bundleID):
            guard let app = CallAppCatalog.app(forBundleID: bundleID) else { return }
            // Clear only the app-only key — a real calendar-event key stays
            // handled forever (that event already happened), but an
            // app-only session ending means the *next* session should be
            // able to nudge again.
            handledKeys.remove("app:" + app.id)
        }
    }

    // MARK: Shared decision handling

    private func act(
        on decision: MeetingDetectionRules.Decision,
        triggerKey: String,
        fallbackAppName: String?,
        fallbackAppID: String? = nil
    ) {
        switch decision {
        case .none:
            nudgeLog.info("Decision: none")
        case .ask(let match):
            nudgeLog.info("Decision: ask")
            markHandled(triggerKey)
            let nudge = MeetingNudge.ask(appID: fallbackAppID, appName: fallbackAppName, match: match)
            lastPresented = nudge
            present(nudge)
        case .autoRecord(let event):
            nudgeLog.info("Decision: autoRecord")
            markHandled(triggerKey)
            startRecording(event.title, event.otherAttendees)
            let missed = max(0, Int(now().timeIntervalSince(event.start)))
            let nudge = MeetingNudge.recordingStarted(event: event, missedSeconds: missed)
            lastPresented = nudge
            present(nudge)
        }
    }

    private func handled(_ key: String) -> Bool {
        handledKeys.contains(key)
    }

    private func markHandled(_ key: String) {
        handledKeys.insert(key)
    }

    // MARK: Panel actions

    /// The panel's Record button. `nudge` is the one currently shown (passed
    /// back explicitly so the panel — not this center — owns "what's on
    /// screen right now").
    public func recordTapped(for nudge: MeetingNudge) {
        nudgeLog.info("Action: record")
        switch nudge {
        case .ask(_, let appName, let match):
            if let match {
                startRecording(match.title, match.otherAttendees)
            } else {
                startRecording("\(appName ?? "Call") call", [])
            }
        case .recordingStarted:
            break
        }
    }

    /// The panel's "Not now" — the trigger already marked its key handled at
    /// present time, so this is just a dismissal signal for the caller (the
    /// panel controller) to act on.
    public func notNowTapped(for nudge: MeetingNudge) {
        nudgeLog.info("Action: not now")
    }

    /// The panel's "Don't ask for ‹app›" — routed back to `AppStores` via an
    /// injected closure so it's the one place that also restarts the audio
    /// monitor with the updated disabled set.
    public func dontAskTapped(appID: String, disableApp: (String) -> Void) {
        nudgeLog.info("Action: don't ask for \(appID, privacy: .public)")
        disableApp(appID)
    }
}
