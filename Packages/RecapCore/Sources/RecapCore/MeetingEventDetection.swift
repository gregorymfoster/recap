import Foundation

/// A calendar event reduced to the fields meeting detection needs —
/// plain values so the heuristics stay testable without EventKit.
public struct CalendarEventSnapshot: Equatable, Sendable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    /// Display names of attendees other than the user.
    public var otherAttendees: [String]
    public var hasConferenceURL: Bool
    public var isAllDay: Bool
    /// Display name of the video-call service ("Zoom", "Teams"…) when one
    /// was recognized in the event's URL/location/notes. Meta-line garnish
    /// only — never used for detection decisions.
    public var conferenceProvider: String?

    public init(
        id: String,
        title: String,
        start: Date,
        end: Date,
        otherAttendees: [String] = [],
        hasConferenceURL: Bool = false,
        isAllDay: Bool = false,
        conferenceProvider: String? = nil
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.otherAttendees = otherAttendees
        self.hasConferenceURL = hasConferenceURL
        self.isAllDay = isAllDay
        self.conferenceProvider = conferenceProvider
    }
}

/// Heuristics for "is this calendar event a meeting worth recording?"
public enum MeetingEventDetection {
    /// Meeting-shaped: a timed event under 4 hours that either carries a
    /// video-call link or has other people invited. All-day events, solo
    /// blocks ("Focus time"), and multi-hour holds don't qualify.
    public static func isMeetingShaped(_ event: CalendarEventSnapshot) -> Bool {
        guard !event.isAllDay else { return false }
        let duration = event.end.timeIntervalSince(event.start)
        guard duration > 0, duration <= 4 * 3600 else { return false }
        return event.hasConferenceURL || !event.otherAttendees.isEmpty
    }

    /// Hosts of the common video-call services (with display names), matched
    /// against any URLs in an event's URL field, location, or notes.
    private static let conferenceHosts: [(host: String, name: String)] = [
        ("zoom.us", "Zoom"), ("meet.google.com", "Meet"),
        ("teams.microsoft.com", "Teams"), ("teams.live.com", "Teams"),
        ("webex.com", "Webex"), ("whereby.com", "Whereby"),
        ("meet.jit.si", "Jitsi"), ("around.co", "Around"),
        ("gather.town", "Gather"), ("chime.aws", "Chime"),
        ("vc.ringcentral.com", "RingCentral"), ("gotomeeting.com", "GoToMeeting"),
    ]

    public static func containsConferenceURL(_ text: String) -> Bool {
        conferenceProviderName(in: text) != nil
    }

    /// Display name of the first video-call service found in `text`
    /// ("Zoom", "Teams"…), or nil when no real host match exists.
    public static func conferenceProviderName(in text: String) -> String? {
        let lowered = text.lowercased()
        return conferenceHosts.first { host, _ in
            guard let range = lowered.range(of: host) else { return false }
            // Require a real host match ("recap.zoom.us/j/…"), not a mention
            // inside a word ("nozoom.usual").
            let after = lowered[range.upperBound...]
            let boundaryAfter = after.first.map { "/?:& \n".contains($0) } ?? true
            let before = lowered[..<range.lowerBound]
            let boundaryBefore = before.last.map { !$0.isLetter && !$0.isNumber } ?? true
            return boundaryAfter && boundaryBefore
        }?.name
    }
}
