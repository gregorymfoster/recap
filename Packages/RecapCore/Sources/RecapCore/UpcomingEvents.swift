import Foundation

/// Pure selection logic for the Library's "Upcoming" section (design mock
/// 9a): today's remaining meeting-shaped events, soonest first. Extracted so
/// the filtering is testable without EventKit.
public enum UpcomingEvents {
    /// Meeting-shaped events that start later today (strictly after `now` —
    /// an event that already started is the nudge's job, not this section's).
    public static func todayRemaining(
        _ events: [CalendarEventSnapshot], now: Date, calendar: Calendar
    ) -> [CalendarEventSnapshot] {
        var seen = Set<String>()
        return events
            .filter { event in
                MeetingEventDetection.isMeetingShaped(event)
                    && event.start > now
                    && calendar.isDate(event.start, inSameDayAs: now)
                    && seen.insert(event.id).inserted
            }
            .sorted { $0.start < $1.start }
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
