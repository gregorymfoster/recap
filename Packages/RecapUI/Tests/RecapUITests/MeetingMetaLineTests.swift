import Foundation
import RecapCore
import Testing
@testable import RecapUI

/// `Meeting.metaLine` (StatusViews.swift) — the "Jun 30 · 24 min · 3 speakers"
/// row subtitle. Uses a fixed date so the formatted-date segment is
/// deterministic regardless of when the test runs.
@Suite struct MeetingMetaLineTests {
    private func meeting(duration: TimeInterval = 0, attendees: [String] = []) -> Meeting {
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 30
        components.hour = 12
        let date = Calendar(identifier: .gregorian).date(from: components)!
        return Meeting(title: "Test meeting", date: date, duration: duration, attendees: attendees)
    }

    @Test func dateOnlyWhenNoDurationOrAttendees() {
        let line = meeting().metaLine
        #expect(line == "Jun 30")
    }

    @Test func includesDurationWhenPositive() {
        let line = meeting(duration: 1_453).metaLine  // ~24 min
        #expect(line.hasPrefix("Jun 30 · "))
        #expect(line.contains("24"))
        #expect(!line.contains("speakers"))
    }

    @Test func zeroDurationIsOmitted() {
        let line = meeting(duration: 0, attendees: ["Sam"]).metaLine
        #expect(line == "Jun 30 · 2 speakers")
    }

    @Test func attendeeCountIsAttendeesPlusOneForTheRecordingUser() {
        let line = meeting(attendees: ["Maya", "Sam"]).metaLine
        #expect(line.hasSuffix("3 speakers"))
    }

    @Test func noAttendeesOmitsSpeakerCount() {
        let line = meeting(duration: 900, attendees: []).metaLine
        #expect(!line.contains("speakers"))
    }

    @Test func allThreePartsJoinInOrder() {
        let line = meeting(duration: 900, attendees: ["Maya"]).metaLine
        let parts = line.components(separatedBy: " · ")
        #expect(parts.count == 3)
        #expect(parts[0] == "Jun 30")
        #expect(parts[2] == "2 speakers")
    }
}
