import EventKit
import Foundation
import OSLog
import RecapCore

private let calendarLog = Logger(subsystem: "com.gregfoster.recap", category: "CalendarWatcher")

/// Pure selection logic for the menu bar dropdown's "Up next" row (design
/// mock 8a): the single soonest meeting-shaped event starting within the
/// next `withinHours`, or nil if there isn't one. Extracted so the picking
/// rule is testable without `EKEventStore`.
public enum UpNextEvent {
    /// - Parameters:
    ///   - events: Candidate events, in any order — needn't be pre-filtered
    ///     or pre-sorted.
    ///   - now: Injected for deterministic tests.
    ///   - withinHours: How far ahead to look; events further out (or
    ///     already started) don't count as "up next".
    public static func choose(
        from events: [CalendarEventSnapshot], now: Date = .now, withinHours: TimeInterval = 8
    ) -> CalendarEventSnapshot? {
        let horizon = now.addingTimeInterval(withinHours * 3600)
        return events
            .filter { event in
                event.start > now
                    && event.start <= horizon
                    && MeetingEventDetection.isMeetingShaped(event)
            }
            .min { $0.start < $1.start }
    }

    /// "1:00 PM · in 19m" style relative-time line for the up-next row.
    /// `referenceDate` is injected for deterministic tests.
    public static func timeLine(for event: CalendarEventSnapshot, now: Date = .now) -> String {
        let clockTime = event.start.formatted(.dateTime.hour().minute())
        let minutesUntil = max(0, Int(event.start.timeIntervalSince(now) / 60))
        let relative: String
        if minutesUntil < 1 {
            relative = "starting now"
        } else if minutesUntil < 60 {
            relative = "in \(minutesUntil)m"
        } else {
            let hours = minutesUntil / 60
            let minutes = minutesUntil % 60
            relative = minutes == 0 ? "in \(hours)h" : "in \(hours)h \(minutes)m"
        }
        return "\(clockTime) · \(relative)"
    }
}

/// Watches the calendar for meeting-shaped events that are starting and
/// fires once per event. Polling (every 30 s over a ±90 s window) rather
/// than EKEventStore change notifications: we care about the clock reaching
/// an event's start time, not about edits.
@MainActor
public final class CalendarWatcher {
    private let store = EKEventStore()
    private var pollTask: Task<Void, Never>?
    private var firedEventIDs: Set<String> = []
    private let onMeetingStarting: @MainActor (CalendarEventSnapshot) -> Void

    public init(onMeetingStarting: @escaping @MainActor (CalendarEventSnapshot) -> Void) {
        self.onMeetingStarting = onMeetingStarting
    }

    public var isWatching: Bool { pollTask != nil }

    /// Requests calendar access if needed and begins watching.
    /// Returns false when the user has denied access.
    @discardableResult
    public func start() async -> Bool {
        guard pollTask == nil else { return true }
        let authorized: Bool
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            authorized = true
        case .notDetermined:
            authorized = (try? await store.requestFullAccessToEvents()) ?? false
        default:
            authorized = false
        }
        guard authorized else {
            calendarLog.info("Calendar access unavailable; auto-record stays off")
            return false
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        calendarLog.info("Watching calendar for starting meetings")
        return true
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Whether calendar access is already granted — checked synchronously
    /// (no prompt) so callers can decide whether it's safe to query at all.
    public static var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// The next meeting-shaped event in the next 8 hours, for the menu bar
    /// dropdown's "Up next" row. Only queries `EKEventStore` when access is
    /// already granted — **never** triggers a permission prompt, since this
    /// runs from a menu bar popover `onAppear` where a system dialog would
    /// be surprising and easy to dismiss into permanent denial.
    public func upNext(now: Date = .now) -> CalendarEventSnapshot? {
        guard Self.isAuthorized else { return nil }
        let horizon = now.addingTimeInterval(8 * 3600)
        let predicate = store.predicateForEvents(withStart: now, end: horizon, calendars: nil)
        let snapshots = store.events(matching: predicate).map(Self.snapshot(of:))
        return UpNextEvent.choose(from: snapshots, now: now)
    }

    private func poll() {
        let now = Date.now
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-90), end: now.addingTimeInterval(90), calendars: nil
        )
        for event in store.events(matching: predicate) {
            let snapshot = Self.snapshot(of: event)
            guard
                !firedEventIDs.contains(snapshot.id),
                MeetingEventDetection.isMeetingShaped(snapshot),
                // Fire in a window around the start: up to 45 s late (poll
                // cadence) or 75 s early (join-a-minute-early habit).
                snapshot.start.timeIntervalSince(now) < 75,
                now.timeIntervalSince(snapshot.start) < 45
            else { continue }
            firedEventIDs.insert(snapshot.id)
            calendarLog.info("Meeting starting: \(snapshot.title, privacy: .private)")
            onMeetingStarting(snapshot)
        }
    }

    static func snapshot(of event: EKEvent) -> CalendarEventSnapshot {
        let others = (event.attendees ?? [])
            .filter { !$0.isCurrentUser && $0.participantType == .person }
            .compactMap(\.name)
        let urlText = [
            event.url?.absoluteString, event.location, event.notes,
        ].compactMap(\.self).joined(separator: " ")
        return CalendarEventSnapshot(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: event.title ?? "Meeting",
            start: event.startDate,
            end: event.endDate,
            otherAttendees: others,
            hasConferenceURL: MeetingEventDetection.containsConferenceURL(urlText),
            isAllDay: event.isAllDay
        )
    }
}
