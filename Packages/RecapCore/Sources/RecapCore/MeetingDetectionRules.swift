import Foundation

/// Pure decision logic for the "meeting started" nudge (design mock 9b):
/// given the user's policy, what's on the calendar, and what triggered us,
/// decide whether to stay quiet, ask, or record automatically. Every input
/// is a plain value so the whole matrix is unit-testable.
public enum MeetingDetectionRules {
    /// Mirror of the Settings policy ("When a meeting is detected"),
    /// duplicated here so core logic doesn't depend on the UI layer's
    /// `CalendarAutoRecordMode`.
    public enum Policy: String, Sendable {
        case off
        case prompt
        case auto
    }

    public enum Decision: Equatable, Sendable {
        case none
        /// Show the "Meeting started?" nudge. `match` carries the calendar
        /// event when one lines up with the trigger — it pre-fills the copy,
        /// the recording title, and the attendees.
        case ask(match: CalendarEventSnapshot?)
        /// Start recording immediately and show the confirmation nudge
        /// (with its honest missed-lead-in line and one-click Stop).
        case autoRecord(CalendarEventSnapshot)
    }

    /// The one decision point, shared by both triggers (calendar clock and
    /// call-app audio). `auto` only auto-records on a calendar match —
    /// audio activity alone (a Zoom test call, a Slack huddle ping) never
    /// starts a recording unasked; it downgrades to asking.
    public static func decision(
        policy: Policy,
        isRecording: Bool,
        appEnabled: Bool,
        alreadyHandled: Bool,
        match: CalendarEventSnapshot?
    ) -> Decision {
        guard policy != .off, !isRecording, appEnabled, !alreadyHandled else { return .none }
        switch policy {
        case .off:
            return .none
        case .prompt:
            return .ask(match: match)
        case .auto:
            if let match { return .autoRecord(match) }
            return .ask(match: nil)
        }
    }

    /// The calendar event that best explains "call audio just started":
    /// meeting-shaped, already ongoing or starting within `startingWithin`,
    /// not yet over. When several qualify, the one whose start is closest
    /// to now wins.
    public static func matchEvent(
        in events: [CalendarEventSnapshot],
        now: Date,
        startingWithin: TimeInterval = 10 * 60
    ) -> CalendarEventSnapshot? {
        events
            .filter { event in
                MeetingEventDetection.isMeetingShaped(event)
                    && event.start <= now.addingTimeInterval(startingWithin)
                    && event.end > now
            }
            .min {
                abs($0.start.timeIntervalSince(now)) < abs($1.start.timeIntervalSince(now))
            }
    }
}
