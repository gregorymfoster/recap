import Foundation
import Testing
@testable import RecapCore

@Suite struct MeetingEventDetectionTests {
    private func event(
        duration: TimeInterval = 1800,
        attendees: [String] = [],
        conferenceURL: Bool = false,
        allDay: Bool = false
    ) -> CalendarEventSnapshot {
        CalendarEventSnapshot(
            id: "e1", title: "Sync", start: .now, end: .now.addingTimeInterval(duration),
            otherAttendees: attendees, hasConferenceURL: conferenceURL, isAllDay: allDay
        )
    }

    @Test func conferenceLinkQualifies() {
        #expect(MeetingEventDetection.isMeetingShaped(event(conferenceURL: true)))
    }

    @Test func attendeesQualify() {
        #expect(MeetingEventDetection.isMeetingShaped(event(attendees: ["Maya"])))
    }

    @Test func soloTimedBlockDoesNotQualify() {
        #expect(!MeetingEventDetection.isMeetingShaped(event()))
    }

    @Test func allDayEventDoesNotQualify() {
        #expect(!MeetingEventDetection.isMeetingShaped(
            event(duration: 86400, attendees: ["Maya"], allDay: true)))
    }

    @Test func multiHourHoldDoesNotQualify() {
        #expect(!MeetingEventDetection.isMeetingShaped(
            event(duration: 6 * 3600, attendees: ["Maya"])))
    }

    @Test func detectsCommonConferenceURLs() {
        #expect(MeetingEventDetection.containsConferenceURL("https://acme.zoom.us/j/123?pwd=x"))
        #expect(MeetingEventDetection.containsConferenceURL("join at meet.google.com/abc-defg-hij"))
        #expect(MeetingEventDetection.containsConferenceURL(
            "https://teams.microsoft.com/l/meetup-join/xyz"))
    }

    @Test func ignoresLookalikeText() {
        #expect(!MeetingEventDetection.containsConferenceURL("nozoom.usual suspects"))
        #expect(!MeetingEventDetection.containsConferenceURL("Meeting notes and agenda"))
    }
}
