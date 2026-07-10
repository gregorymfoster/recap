import Foundation
import Observation
import RecapCore

/// Today's remaining meeting-shaped calendar events for the Library's
/// "Upcoming" section (design mock 9a). A thin `@Observable` cache over an
/// injected provider so the section renders deterministically in fixtures
/// and tests — the live provider queries EventKit, and only when calendar
/// access is already granted (never prompts).
@MainActor
@Observable
public final class UpcomingStore {
    public private(set) var events: [CalendarEventSnapshot] = []
    /// False when calendar permission is missing — the section hides
    /// entirely rather than rendering an empty shell.
    public private(set) var isAvailable = false

    @ObservationIgnored private let availability: @MainActor () -> Bool
    @ObservationIgnored private let provider: @MainActor (Date) -> [CalendarEventSnapshot]
    @ObservationIgnored private let calendar: Calendar

    public init(
        calendar: Calendar = .current,
        availability: @escaping @MainActor () -> Bool,
        provider: @escaping @MainActor (Date) -> [CalendarEventSnapshot]
    ) {
        self.calendar = calendar
        self.availability = availability
        self.provider = provider
    }

    /// Re-queries the provider and re-filters. Cheap enough to call from a
    /// periodic UI tick (the menu bar's Up-next row does the same on appear).
    public func refresh(now: Date = .now) {
        isAvailable = availability()
        guard isAvailable else {
            events = []
            return
        }
        events = UpcomingEvents.todayRemaining(provider(now), now: now, calendar: calendar)
    }

    /// Live EventKit-backed store. Hidden until calendar access is granted
    /// elsewhere (onboarding or Settings → Calendar) — never prompts itself.
    public static func live() -> UpcomingStore {
        let query = CalendarWatcher(onMeetingStarting: { _ in })
        return UpcomingStore(
            availability: { CalendarWatcher.isAuthorized },
            provider: { query.todayEvents(now: $0) }
        )
    }

    /// Fixture store: an imminent event (blue-tint + countdown treatment)
    /// and a later one (quiet text Record), pinned relative to launch.
    public static func fixture(now: Date = .now) -> UpcomingStore {
        let events = [
            CalendarEventSnapshot(
                id: "fixture-upcoming-imminent",
                title: "Design crit — mobile",
                start: now.addingTimeInterval(19 * 60),
                end: now.addingTimeInterval(19 * 60 + 45 * 60),
                otherAttendees: ["Maya Chen", "Priya Patel", "Sam Ortiz", "Jordan Lee"],
                hasConferenceURL: true,
                conferenceProvider: "Zoom"
            ),
            CalendarEventSnapshot(
                id: "fixture-upcoming-later",
                title: "Meridian renewal check-in",
                start: now.addingTimeInterval(2 * 3600 + 49 * 60),
                end: now.addingTimeInterval(3 * 3600 + 19 * 60),
                otherAttendees: ["Alex Kim", "Rowan Diaz"],
                hasConferenceURL: true,
                conferenceProvider: "Meet"
            ),
        ]
        let store = UpcomingStore(availability: { true }, provider: { _ in events })
        store.refresh(now: now)
        return store
    }
}

extension UpcomingStore {
    /// The next event starting within 30 minutes, if calendar access is
    /// authorized — drives `NextMeetingBanner` (replaces the old
    /// always-present "Upcoming" agenda with a single high-signal row,
    /// design mock 10a/11c). `events` is already `UpcomingEvents
    /// .todayRemaining`-filtered and sorts an already-started meeting first,
    /// but `isImminent` only matches events that haven't started yet, so a
    /// plain first-match over `events` is correct without extra sorting.
    public func imminentEvent(now: Date = .now) -> CalendarEventSnapshot? {
        guard isAvailable else { return nil }
        return Self.imminentEvent(in: events, now: now)
    }

    /// Pure filter extracted out of the instance method above so it's
    /// directly unit-testable without constructing a store.
    public static func imminentEvent(in events: [CalendarEventSnapshot], now: Date) -> CalendarEventSnapshot? {
        events.first { UpcomingEvents.isImminent($0, now: now) }
    }
}
