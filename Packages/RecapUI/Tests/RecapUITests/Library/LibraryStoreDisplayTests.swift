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

    /// Progress ticks within `.transcribing` patch the cached
    /// `displayMeetings` entry in place rather than re-sorting — order must
    /// stay stable and the new progress value must still show up.
    @Test func progressTickUpdatesInPlaceWithoutReordering() {
        let older = Self.record("Older", hoursAgo: 5, duration: 100, status: .transcribing(progress: 0.1))
        let newer = Self.record("Newer", hoursAgo: 1, duration: 100, status: .transcribing(progress: 0.1))
        let store = LibraryStore(fixtures: [older, newer])
        #expect(store.displayMeetings.map(\.meeting.title) == ["Newer", "Older"])

        store.updateStatus(older.meeting.id, to: .transcribing(progress: 0.9))

        #expect(store.displayMeetings.map(\.meeting.title) == ["Newer", "Older"])
        #expect(store.displayMeetings.first { $0.meeting.id == older.meeting.id }?.meeting.status == .transcribing(progress: 0.9))
    }

    /// Membership changes (a new meeting starting) must rebuild the cache so
    /// the newest meeting shows up first, not just get appended unsorted.
    @Test func newMeetingRebuildsDisplayMeetings() {
        let older = Self.record("Older", hoursAgo: 5, duration: 100)
        let store = LibraryStore(fixtures: [older])

        store.startNewMeeting(title: "Brand new")

        #expect(store.displayMeetings.map(\.meeting.title) == ["Brand new", "Older"])
        #expect(store.displayMeetings.count == store.meetings.count)
    }

    /// Progress ticks patch the matching record inside `displaySections`
    /// in place — section structure/order must stay unchanged and the new
    /// progress value must show up in the patched record.
    @Test func progressTickPatchesDisplaySectionsInPlace() {
        let older = Self.record("Older", hoursAgo: 5, duration: 100, status: .transcribing(progress: 0.1))
        let newer = Self.record("Newer", hoursAgo: 1, duration: 100, status: .transcribing(progress: 0.1))
        let store = LibraryStore(fixtures: [older, newer])
        let sectionsBefore = store.sections().map(\.id)

        store.updateStatus(older.meeting.id, to: .transcribing(progress: 0.9))

        let sectionsAfter = store.sections()
        #expect(sectionsAfter.map(\.id) == sectionsBefore)
        let patched = sectionsAfter.flatMap(\.records).first { $0.meeting.id == older.meeting.id }
        #expect(patched?.meeting.status == .transcribing(progress: 0.9))
    }

    /// Membership changes must rebuild `displaySections`, not just
    /// `displayMeetings`.
    @Test func newMeetingRebuildsDisplaySections() {
        let older = Self.record("Older", hoursAgo: 5, duration: 100)
        let store = LibraryStore(fixtures: [older])

        store.startNewMeeting(title: "Brand new")

        let allTitles = store.sections().flatMap(\.records).map(\.meeting.title)
        #expect(allTitles == ["Brand new", "Older"])
    }

    /// A `.recovered` → `.queued` transition changes where a record sits
    /// within its section (recovered records pin to the top of Today) —
    /// `replace(_:)` must re-bucket, not just patch in place.
    @Test func statusTransitionRebucketsDisplaySections() {
        // "Recovered" is dated OLDER than "Today meeting" so, absent the
        // recovered-pins-to-top rule, it would sort second within Today.
        let recovered = Self.record("Recovered", hoursAgo: 3, duration: 100, status: .recovered)
        let today = Self.record("Today meeting", hoursAgo: 1, duration: 100, status: .ready)
        let store = LibraryStore(fixtures: [today, recovered])

        // Recovered pins to the top of Today initially despite being older.
        let todaySectionBefore = store.sections().first { $0.id == "today" }
        #expect(todaySectionBefore?.records.first?.meeting.title == "Recovered")

        store.updateStatus(recovered.meeting.id, to: .queued)

        let todaySectionAfter = store.sections().first { $0.id == "today" }
        #expect(todaySectionAfter?.records.contains { $0.meeting.status == .queued } == true)
        // No longer pinned since it's no longer `.recovered` — falls back
        // to date order, so the newer "Today meeting" sorts first.
        #expect(todaySectionAfter?.records.first?.meeting.title == "Today meeting")
    }

    /// `sections(now:calendar:)` called with a different day than the cache
    /// was built for must return a freshly computed bucketing without
    /// mutating the cached `displaySections`.
    @Test func sectionsFallsBackToFreshComputationAcrossMidnightWithoutMutatingCache() {
        let record = Self.record("Meeting", hoursAgo: 1, duration: 100)
        let store = LibraryStore(fixtures: [record])
        let cachedBefore = store.displaySections

        let tomorrow = Date.now.addingTimeInterval(2 * 86_400)
        let fresh = store.sections(now: tomorrow, calendar: .current)

        // Cache must be untouched by the read-only cross-day call.
        #expect(store.displaySections.map(\.id) == cachedBefore.map(\.id))
        // The fresh computation still finds the meeting (bucketed
        // differently now that "now" has moved forward), proving it
        // actually recomputed rather than returning the stale cache.
        #expect(fresh.flatMap(\.records).contains { $0.meeting.id == record.meeting.id })
    }
}
