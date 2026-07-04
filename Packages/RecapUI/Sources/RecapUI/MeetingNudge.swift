import Foundation
import RecapCore

/// The "Meeting started?" nudge (design mock 9b): a top-right slide-in panel
/// replacing the old `UNUserNotification`-based prompt. One case per surface
/// the panel can show.
public enum MeetingNudge: Equatable, Sendable {
    /// "Meeting started?" ask. `appID`/`appName` are nil for a pure
    /// calendar-clock trigger (no call-app audio involved); `match` carries
    /// the calendar event when one lines up with the trigger.
    case ask(appID: String?, appName: String?, match: CalendarEventSnapshot?)
    /// Auto-record confirmation: recording already started. `missedSeconds`
    /// is how much of the meeting's actual start we missed before the
    /// trigger fired — 0 when we caught it right at the start.
    case recordingStarted(event: CalendarEventSnapshot, missedSeconds: Int)
}

/// Pure copy-generation for `MeetingNudgeView`, factored out so the wording
/// rules are unit-testable without rendering SwiftUI.
public enum MeetingNudgeCopy {
    /// The nudge's title line.
    public static func title(for nudge: MeetingNudge) -> String {
        switch nudge {
        case .ask:
            return "Meeting started?"
        case .recordingStarted(let event, _):
            return "Recording \u{201C}\(event.title)\u{201D}"
        }
    }

    /// The nudge's body line.
    public static func body(for nudge: MeetingNudge) -> String {
        switch nudge {
        case .ask(let appID, let appName, let match):
            switch (appID != nil ? appName : nil, match) {
            case (let appName?, let match?):
                return "\(appName ?? "") is playing audio \u{2014} looks like \u{201C}\(match.title)\u{201D} just began."
            case (nil, let match?):
                return "\u{201C}\(match.title)\u{201D} is on your calendar and starting now."
            case (let appName?, nil):
                return "\(appName ?? "") is playing call audio."
            case (nil, nil):
                return ""
            }
        case .recordingStarted(_, let missedSeconds):
            var line = "Started from your calendar"
            if missedSeconds > 5 {
                line += " \u{00B7} missed the first \(formattedMissed(missedSeconds))"
            }
            return line
        }
    }

    /// "40s" / "1m 10s" style formatting for the missed lead-in.
    public static func formattedMissed(_ seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds)s"
        }
        let minutes = seconds / 60
        let remainder = seconds % 60
        return remainder == 0 ? "\(minutes)m" : "\(minutes)m \(remainder)s"
    }
}
