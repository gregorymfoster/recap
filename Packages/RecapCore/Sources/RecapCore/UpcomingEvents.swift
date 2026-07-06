import Foundation

/// Pure selection logic for the Library's "Upcoming" section (design mock
/// 9a): today's remaining meeting-shaped events, soonest first. Extracted so
/// the filtering is testable without EventKit.
public enum UpcomingEvents {
    /// Meeting-shaped events still relevant today: anything starting later
    /// today, PLUS a meeting that's already started but hasn't ended yet —
    /// so a user who opens Recap mid-meeting still sees it and can hit
    /// Record, rather than the agenda silently skipping straight to
    /// whatever's next. An event that already started sorts first (it's the
    /// most actionable), same as the nudge's own priority. Deliberately
    /// narrow: this does NOT pull in the general "started" nudge logic or
    /// widen to all-day/non-meeting events — see `MeetingEventDetection
    /// .isMeetingShaped`.
    public static func todayRemaining(
        _ events: [CalendarEventSnapshot], now: Date, calendar: Calendar
    ) -> [CalendarEventSnapshot] {
        var seen = Set<String>()
        return events
            .filter { event in
                MeetingEventDetection.isMeetingShaped(event)
                    && event.end > now
                    && calendar.isDate(event.start, inSameDayAs: now)
                    && seen.insert(event.id).inserted
            }
            .sorted { lhs, rhs in
                let lhsStarted = lhs.start <= now
                let rhsStarted = rhs.start <= now
                if lhsStarted != rhsStarted { return lhsStarted }
                return lhs.start < rhs.start
            }
    }

    /// Imminent (< 30 minutes out) events get the highlighted treatment:
    /// blue tint, countdown, solid Record button.
    public static func isImminent(
        _ event: CalendarEventSnapshot, now: Date, threshold: TimeInterval = 30 * 60
    ) -> Bool {
        let untilStart = event.start.timeIntervalSince(now)
        return untilStart > 0 && untilStart <= threshold
    }
}
