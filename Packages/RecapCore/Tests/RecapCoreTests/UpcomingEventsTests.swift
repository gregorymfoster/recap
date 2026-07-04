import Foundation
import Testing
@testable import RecapCore

/// Covers `UpcomingEvents`, the pure filtering/sorting behind the Library's
/// "Upcoming" section (design mock 9a): today's remaining meeting-shaped
/// events, soonest first, plus the imminent-event boundary used to switch a
/// row into its highlighted (blue) treatment.
@Suite struct UpcomingEventsTests {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private let calendar = Calendar(identifier: .gregorian)

    private func event(
        id: String = "e1",
        title: String = "Sync",
        startOffset: TimeInterval,
        duration: TimeInterval = 1800,
        attendees: [String] = ["Maya"],
        conferenceURL: Bool = false,
        allDay: Bool = false
    ) -> CalendarEventSnapshot {
        CalendarEventSnapshot(
            id: id, title: title,
            start: now.addingTimeInterval(startOffset),
            end: now.addingTimeInterval(startOffset + duration),
            otherAttendees: attendees, hasConferenceURL: conferenceURL, isAllDay: allDay
        )
    }

    // MARK: todayRemaining

    @Test func includesMeetingShapedEventLaterToday() {
        let e = event(startOffset: 3600)
        #expect(UpcomingEvents.todayRemaining([e], now: now, calendar: calendar) == [e])
    }

    @Test func excludesNonMeetingShapedEvent() {
        // No attendees, no conference URL — a solo block.
        let e = event(startOffset: 3600, attendees: [])
        #expect(UpcomingEvents.todayRemaining([e], now: now, calendar: calendar).isEmpty)
    }

    @Test func excludesAllDayEvent() {
        let e = event(startOffset: 3600, duration: 86400, allDay: true)
        #expect(UpcomingEvents.todayRemaining([e], now: now, calendar: calendar).isEmpty)
    }

    @Test func excludesPastEvent() {
        let e = event(startOffset: -60)
        #expect(UpcomingEvents.todayRemaining([e], now: now, calendar: calendar).isEmpty)
    }

    @Test func excludesEventStartingExactlyNow() {
        let e = event(startOffset: 0)
        #expect(UpcomingEvents.todayRemaining([e], now: now, calendar: calendar).isEmpty)
    }

    @Test func excludesEventTomorrow() {
        let e = event(startOffset: 24 * 3600 + 60)
        #expect(UpcomingEvents.todayRemaining([e], now: now, calendar: calendar).isEmpty)
    }

    @Test func dedupesByID() {
        let a = event(id: "dup", title: "First copy", startOffset: 1800)
        let b = event(id: "dup", title: "Second copy", startOffset: 3600)
        let result = UpcomingEvents.todayRemaining([a, b], now: now, calendar: calendar)
        #expect(result.count == 1)
        #expect(result.first?.title == "First copy")
    }

    @Test func sortsByStartAscending() {
        let later = event(id: "later", startOffset: 7200)
        let sooner = event(id: "sooner", startOffset: 1800)
        let result = UpcomingEvents.todayRemaining([later, sooner], now: now, calendar: calendar)
        #expect(result.map(\.id) == ["sooner", "later"])
    }

    // MARK: isImminent

    @Test func imminentAtZeroSecondsIsNotImminent() {
        // Boundary: an event starting exactly now (0s until start) is not
        // "later today" material in the first place, but isImminent itself
        // should still treat 0 as not-imminent (strictly > 0 required).
        let e = event(startOffset: 0)
        #expect(!UpcomingEvents.isImminent(e, now: now))
    }

    @Test func imminentAt29Minutes59SecondsIsImminent() {
        let e = event(startOffset: 29 * 60 + 59)
        #expect(UpcomingEvents.isImminent(e, now: now))
    }

    @Test func imminentAt30MinutesIsImminent() {
        let e = event(startOffset: 30 * 60)
        #expect(UpcomingEvents.isImminent(e, now: now))
    }

    @Test func imminentAt31MinutesIsNotImminent() {
        let e = event(startOffset: 31 * 60)
        #expect(!UpcomingEvents.isImminent(e, now: now))
    }

    @Test func imminentInThePastIsNotImminent() {
        let e = event(startOffset: -60)
        #expect(!UpcomingEvents.isImminent(e, now: now))
    }
}
