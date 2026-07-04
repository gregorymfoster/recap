import Foundation
import RecapCore
import Testing
@testable import RecapUI

/// Covers `UpcomingStore` (the Library's "Upcoming" section state, design
/// mock 9a) and the pure display helpers in `UpcomingSection.swift`.
@MainActor
@Suite struct UpcomingStoreTests {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private let calendar = Calendar(identifier: .gregorian)

    private func event(
        id: String, startOffset: TimeInterval, attendees: [String] = ["Maya"]
    ) -> CalendarEventSnapshot {
        CalendarEventSnapshot(
            id: id, title: "Event \(id)",
            start: now.addingTimeInterval(startOffset),
            end: now.addingTimeInterval(startOffset + 1800),
            otherAttendees: attendees
        )
    }

    // MARK: refresh

    @Test func refreshPopulatesFromProviderAndAppliesFiltering() {
        let events = [
            event(id: "later", startOffset: 3600),
            // A solo block (no attendees, no conference URL) isn't
            // meeting-shaped — `todayRemaining` should filter it out.
            event(id: "solo", startOffset: 1800, attendees: []),
            event(id: "sooner", startOffset: 900),
        ]
        let store = UpcomingStore(calendar: calendar, availability: { true }, provider: { _ in events })

        store.refresh(now: now)

        #expect(store.isAvailable)
        #expect(store.events.map(\.id) == ["sooner", "later"])
    }

    @Test func unavailableClearsEventsAndFlagsUnavailable() {
        let events = [event(id: "e1", startOffset: 3600)]
        let store = UpcomingStore(calendar: calendar, availability: { false }, provider: { _ in events })

        store.refresh(now: now)

        #expect(!store.isAvailable)
        #expect(store.events.isEmpty)
    }

    /// `@MainActor` reference box so the availability flag can be flipped
    /// between `refresh()` calls without mutating a local var captured by a
    /// `Sendable` closure (a Swift 6 strict-concurrency warning).
    @MainActor
    private final class AvailabilityBox {
        var value = true
    }

    @Test func becomingUnavailableClearsPreviouslyPopulatedEvents() {
        let events = [event(id: "e1", startOffset: 3600)]
        let availability = AvailabilityBox()
        let store = UpcomingStore(calendar: calendar, availability: { availability.value }, provider: { _ in events })

        store.refresh(now: now)
        #expect(!store.events.isEmpty)

        availability.value = false
        store.refresh(now: now)
        #expect(store.events.isEmpty)
        #expect(!store.isAvailable)
    }

    // MARK: fixture()

    @Test func fixtureRendersTwoEventsWithExpectedIDsAndOrder() {
        let store = UpcomingStore.fixture(now: now)

        #expect(store.isAvailable)
        #expect(store.events.map(\.id) == ["fixture-upcoming-imminent", "fixture-upcoming-later"])
        #expect(store.events.first?.title == "Design crit — mobile")
        #expect(store.events.last?.title == "Meridian renewal check-in")
    }

    @Test func fixtureImminentEventIsWithinImminentThreshold() {
        let store = UpcomingStore.fixture(now: now)
        let imminent = store.events.first { $0.id == "fixture-upcoming-imminent" }
        #expect(imminent != nil)
        #expect(UpcomingEvents.isImminent(imminent!, now: now))
    }

    @Test func fixtureLaterEventIsNotImminent() {
        let store = UpcomingStore.fixture(now: now)
        let later = store.events.first { $0.id == "fixture-upcoming-later" }
        #expect(later != nil)
        #expect(!UpcomingEvents.isImminent(later!, now: now))
    }
}

// MARK: - UpcomingRowFormatting

@Suite struct UpcomingRowFormattingTests {
    private let calendar = Calendar(identifier: .gregorian)

    private func date(month: Int, day: Int, hour: Int = 9) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = month
        components.day = day
        components.hour = hour
        return calendar.date(from: components)!
    }

    @Test func monthAbbreviationIsUppercase() {
        let jan9 = date(month: 1, day: 9)
        #expect(UpcomingRowFormatting.monthAbbreviation(for: jan9, calendar: calendar) == "JAN")
    }

    @Test func dayNumberMatchesCalendarDay() {
        let jul3 = date(month: 7, day: 3)
        #expect(UpcomingRowFormatting.dayNumber(for: jul3, calendar: calendar) == "3")
    }

    private func event(otherAttendees: [String]) -> CalendarEventSnapshot {
        CalendarEventSnapshot(
            id: "e1", title: "Sync", start: .now, end: .now.addingTimeInterval(1800),
            otherAttendees: otherAttendees
        )
    }

    @Test func attendeeSummaryIsNilWithNoOtherAttendees() {
        #expect(UpcomingRowFormatting.attendeeSummary(for: event(otherAttendees: [])) == nil)
    }

    @Test func attendeeSummaryCountsSelfPlusOthers() {
        #expect(UpcomingRowFormatting.attendeeSummary(for: event(otherAttendees: ["Maya"])) == "2 attendees")
        #expect(UpcomingRowFormatting.attendeeSummary(for: event(otherAttendees: ["Maya", "Sam", "Priya"])) == "4 attendees")
    }

    @Test func metaLineComponentsOmitsNilSegments() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let bare = CalendarEventSnapshot(
            id: "e1", title: "Sync", start: now.addingTimeInterval(600), end: now.addingTimeInterval(2400),
            otherAttendees: []
        )
        let components = UpcomingRowFormatting.metaLineComponents(for: bare, now: now)
        // Only clock time + relative time — no conference provider, no attendees.
        #expect(components.count == 2)
    }

    @Test func metaLineComponentsIncludesConferenceProviderAndAttendees() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let full = CalendarEventSnapshot(
            id: "e1", title: "Sync", start: now.addingTimeInterval(600), end: now.addingTimeInterval(2400),
            otherAttendees: ["Maya"], hasConferenceURL: true, conferenceProvider: "Zoom"
        )
        let components = UpcomingRowFormatting.metaLineComponents(for: full, now: now)
        #expect(components.count == 4)
        #expect(components.contains("Zoom"))
        #expect(components.contains("2 attendees"))
    }
}
