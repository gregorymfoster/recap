import Foundation
import RecapCore
import Testing
@testable import RecapUI

/// Covers `UpcomingStore` (today's remaining calendar events, feeding the
/// Library's `NextMeetingBanner`, design mock 10a/11c) and its
/// `imminentEvent` helper.
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

    // MARK: imminentEvent (NextMeetingBanner, design mock 10a/11c)

    @Test func imminentEventReturnsTheFixtureImminentEvent() {
        let store = UpcomingStore.fixture(now: now)
        #expect(store.imminentEvent(now: now)?.id == "fixture-upcoming-imminent")
    }

    @Test func imminentEventIsNilWhenUnavailable() {
        let events = [event(id: "soon", startOffset: 600)]
        let store = UpcomingStore(calendar: calendar, availability: { false }, provider: { _ in events })
        store.refresh(now: now)
        #expect(store.imminentEvent(now: now) == nil)
    }

    @Test func imminentEventIsNilWhenNothingIsWithinThreshold() {
        let events = [event(id: "later", startOffset: 3600)]
        let store = UpcomingStore(calendar: calendar, availability: { true }, provider: { _ in events })
        store.refresh(now: now)
        #expect(store.imminentEvent(now: now) == nil)
    }

    @Test func pureImminentEventFilterMatchesStaticHelper() {
        let imminent = event(id: "imminent", startOffset: 600)
        let later = event(id: "later", startOffset: 3600)
        #expect(UpcomingStore.imminentEvent(in: [later, imminent], now: now)?.id == "imminent")
    }

    @Test func pureImminentEventFilterReturnsNilWithNoCandidates() {
        let later = event(id: "later", startOffset: 3600)
        #expect(UpcomingStore.imminentEvent(in: [later], now: now) == nil)
    }
}
