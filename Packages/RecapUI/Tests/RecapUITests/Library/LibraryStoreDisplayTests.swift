import Foundation
import Testing
@testable import RecapCore
@testable import RecapUI

/// `LibraryStore.displayMeetings` — the redesign (design mock 10a/11c)
/// dropped the user-facing sort/filter UI in favor of one fixed ordering, so
/// this only covers that ordering now.
@MainActor
@Suite struct LibraryStoreDisplayTests {
    static func record(_ title: String, hoursAgo: Double, duration: TimeInterval, status: MeetingStatus = .ready) -> MeetingRecord {
        MeetingRecord(
            meeting: Meeting(
                title: title, date: Date.now.addingTimeInterval(-hoursAgo * 3_600),
                duration: duration, status: status
            ),
            folderURL: URL(filePath: "/dev/null")
        )
    }

    @Test func displayMeetingsOrdersNewestFirst() {
        let older = Self.record("Older", hoursAgo: 5, duration: 100)
        let newer = Self.record("Newer", hoursAgo: 1, duration: 100)
        let store = LibraryStore(fixtures: [older, newer])
        #expect(store.displayMeetings.map(\.meeting.title) == ["Newer", "Older"])
    }

    @Test func meetingsStaysUnfilteredSourceOfTruth() {
        let short = Self.record("Short", hoursAgo: 1, duration: 300)
        let long = Self.record("Long", hoursAgo: 5, duration: 3_600)
        let store = LibraryStore(fixtures: [long, short])
        #expect(store.meetings.count == 2)
        #expect(store.displayMeetings.count == 2)
    }
}
