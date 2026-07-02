import EventKit
import Foundation
import OSLog
import RecapCore

private let calendarLog = Logger(subsystem: "com.gregfoster.recap", category: "CalendarWatcher")

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
