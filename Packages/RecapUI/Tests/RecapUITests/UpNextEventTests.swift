import Foundation
import RecapCore
import Testing
@testable import RecapUI

@Suite struct UpNextEventChooseTests {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func event(
        id: String = "e1", title: String = "Sync", startOffset: TimeInterval,
        duration: TimeInterval = 1800, attendees: [String] = ["Maya"], conferenceURL: Bool = false
    ) -> CalendarEventSnapshot {
        let start = now.addingTimeInterval(startOffset)
        return CalendarEventSnapshot(
            id: id, title: title, start: start, end: start.addingTimeInterval(duration),
            otherAttendees: attendees, hasConferenceURL: conferenceURL
        )
    }

    @Test func picksTheSoonestUpcomingMeetingShapedEvent() {
        let soon = event(id: "soon", startOffset: 300)
        let later = event(id: "later", startOffset: 3600)
        let chosen = UpNextEvent.choose(from: [later, soon], now: now)
        #expect(chosen?.id == "soon")
    }

    @Test func ignoresEventsThatAlreadyStarted() {
        let past = event(id: "past", startOffset: -60)
        #expect(UpNextEvent.choose(from: [past], now: now) == nil)
    }

    @Test func ignoresEventsBeyondTheHorizon() {
        let farOut = event(id: "far", startOffset: 9 * 3600)
        #expect(UpNextEvent.choose(from: [farOut], now: now, withinHours: 8) == nil)
    }

    @Test func includesEventsRightAtTheHorizonEdge() {
        let atEdge = event(id: "edge", startOffset: 8 * 3600)
        #expect(UpNextEvent.choose(from: [atEdge], now: now, withinHours: 8)?.id == "edge")
    }

    @Test func skipsEventsThatArentMeetingShaped() {
        let solo = event(id: "solo", startOffset: 300, attendees: [], conferenceURL: false)
        #expect(UpNextEvent.choose(from: [solo], now: now) == nil)
    }

    @Test func returnsNilWhenNoCandidateEventsAtAll() {
        #expect(UpNextEvent.choose(from: [], now: now) == nil)
    }

    @Test func respectsACustomHorizon() {
        let inTwoHours = event(id: "2h", startOffset: 2 * 3600)
        #expect(UpNextEvent.choose(from: [inTwoHours], now: now, withinHours: 1) == nil)
        #expect(UpNextEvent.choose(from: [inTwoHours], now: now, withinHours: 3)?.id == "2h")
    }
}

@Suite struct UpNextEventTimeLineTests {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func event(startOffset: TimeInterval) -> CalendarEventSnapshot {
        let start = now.addingTimeInterval(startOffset)
        return CalendarEventSnapshot(
            id: "e1", title: "Sync", start: start, end: start.addingTimeInterval(1800),
            otherAttendees: ["Maya"]
        )
    }

    @Test func formatsMinutesUntilForSoonEvents() {
        let line = UpNextEvent.timeLine(for: event(startOffset: 19 * 60), now: now)
        #expect(line.hasSuffix("in 19m"))
    }

    @Test func formatsHoursAndMinutesForFartherEvents() {
        let line = UpNextEvent.timeLine(for: event(startOffset: 90 * 60), now: now)
        #expect(line.hasSuffix("in 1h 30m"))
    }

    @Test func formatsWholeHoursWithoutATrailingZeroMinutes() {
        let line = UpNextEvent.timeLine(for: event(startOffset: 120 * 60), now: now)
        #expect(line.hasSuffix("in 2h"))
    }

    @Test func describesAnEventStartingRightNowAsStartingNow() {
        let line = UpNextEvent.timeLine(for: event(startOffset: 0), now: now)
        #expect(line.hasSuffix("starting now"))
    }

    @Test func includesTheClockTimeBeforeTheRelativePart() {
        let line = UpNextEvent.timeLine(for: event(startOffset: 19 * 60), now: now)
        #expect(line.contains(" · "))
    }
}
