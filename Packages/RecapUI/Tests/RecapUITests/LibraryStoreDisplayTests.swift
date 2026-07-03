import Foundation
import Testing
@testable import RecapCore
@testable import RecapUI

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

    @Test func newestSortOrdersByDateDescending() {
        let older = Self.record("Older", hoursAgo: 5, duration: 100)
        let newer = Self.record("Newer", hoursAgo: 1, duration: 100)
        let store = LibraryStore(fixtures: [older, newer])
        store.sort = .newest
        #expect(store.displayMeetings.map(\.meeting.title) == ["Newer", "Older"])
    }

    @Test func oldestSortOrdersByDateAscending() {
        let older = Self.record("Older", hoursAgo: 5, duration: 100)
        let newer = Self.record("Newer", hoursAgo: 1, duration: 100)
        let store = LibraryStore(fixtures: [newer, older])
        store.sort = .oldest
        #expect(store.displayMeetings.map(\.meeting.title) == ["Older", "Newer"])
    }

    @Test func longestSortOrdersByDurationDescending() {
        let short = Self.record("Short", hoursAgo: 1, duration: 300)
        let long = Self.record("Long", hoursAgo: 5, duration: 3_600)
        let medium = Self.record("Medium", hoursAgo: 2, duration: 900)
        let store = LibraryStore(fixtures: [short, long, medium])
        store.sort = .longest
        #expect(store.displayMeetings.map(\.meeting.title) == ["Long", "Medium", "Short"])
    }

    @Test func meetingsStaysUnfilteredSourceOfTruth() {
        let short = Self.record("Short", hoursAgo: 1, duration: 300)
        let long = Self.record("Long", hoursAgo: 5, duration: 3_600)
        let store = LibraryStore(fixtures: [long, short])
        store.filter = LibraryFilter(minDuration: 900)
        #expect(store.meetings.count == 2)
        #expect(store.displayMeetings.map(\.meeting.title) == ["Long"])
    }

    @Test func readyOnlyFilterExcludesNonReadyMeetings() {
        let ready = Self.record("Ready", hoursAgo: 1, duration: 300, status: .ready)
        let queued = Self.record("Queued", hoursAgo: 2, duration: 300, status: .queued)
        let store = LibraryStore(fixtures: [ready, queued])
        store.filter = LibraryFilter(readyOnly: true)
        #expect(store.displayMeetings.map(\.meeting.title) == ["Ready"])
    }

    @Test func minDurationAndReadyOnlyComposeAsAnAnd() {
        let readyLong = Self.record("ReadyLong", hoursAgo: 1, duration: 3_600, status: .ready)
        let readyShort = Self.record("ReadyShort", hoursAgo: 2, duration: 100, status: .ready)
        let queuedLong = Self.record("QueuedLong", hoursAgo: 3, duration: 3_600, status: .queued)
        let store = LibraryStore(fixtures: [readyLong, readyShort, queuedLong])
        store.filter = LibraryFilter(minDuration: 900, readyOnly: true)
        #expect(store.displayMeetings.map(\.meeting.title) == ["ReadyLong"])
    }

    @Test func inactiveFilterKeepsEverything() {
        let a = Self.record("A", hoursAgo: 1, duration: 100)
        let b = Self.record("B", hoursAgo: 2, duration: 5_000)
        let store = LibraryStore(fixtures: [a, b])
        #expect(store.filter.isActive == false)
        #expect(store.displayMeetings.count == 2)
    }

    @Test func sortPersistsAcrossInstancesViaUserDefaults() {
        let suite = UserDefaults(suiteName: "recap.tests.librarysort")!
        suite.removePersistentDomain(forName: "recap.tests.librarysort")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RecapTests-\(UUID().uuidString)")
        let storage = LibraryStorage(rootURL: root)
        let changeBus = LibraryChangeBus()
        let index = try! SearchIndex()

        let store = LibraryStore(storage: storage, index: index, changeBus: changeBus, defaults: suite)
        #expect(store.sort == .newest)
        store.sort = .longest

        let reopened = LibraryStore(storage: storage, index: index, changeBus: changeBus, defaults: suite)
        #expect(reopened.sort == .longest)
    }
}
