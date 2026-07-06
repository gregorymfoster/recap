import Foundation
import RecapCore
import Testing
@testable import RecapUI

/// Fake `MeetingEventWatching` mirroring the one in `AppStoresTests`, local
/// to this file (both are `private`).
@MainActor
private final class FakeWatcher: MeetingEventWatching {
    var grantsAccess = true
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    func start() async -> Bool {
        startCallCount += 1
        return grantsAccess
    }

    func stop() {
        stopCallCount += 1
    }
}

/// Spy `CallStartNotifying` so tests can assert the system-notification
/// fan-out without ever touching a real `UNUserNotificationCenter`.
@MainActor
private final class SpyCallStartNotifier: CallStartNotifying {
    private(set) var postedNudges: [MeetingNudge] = []
    private(set) var dismissCallCount = 0
    /// The closure `AutoRecordCoordinator` wired as this notifier's "Record
    /// action tapped" route — tests invoke it directly to simulate the user
    /// tapping Record from the notification (rather than the panel).
    let recordTapped: @MainActor (MeetingNudge) -> Void
    let onDismissed: @MainActor () -> Void

    init(recordTapped: @escaping @MainActor (MeetingNudge) -> Void, onDismissed: @escaping @MainActor () -> Void) {
        self.recordTapped = recordTapped
        self.onDismissed = onDismissed
    }

    func post(_ nudge: MeetingNudge) {
        postedNudges.append(nudge)
    }

    func dismissLastDelivered() {
        dismissCallCount += 1
    }
}

/// Coordinator-level tests for the calendar auto-record seam extracted from
/// `AppStores`: the coordinator is constructed directly with closure hooks,
/// no store graph, so recording side effects are asserted as captured calls
/// rather than through a real `MeetingSessionStore` start. The end-to-end
/// wiring (nudge → real `startRecording` → library meeting) stays covered by
/// `AppStoresTests`.
@MainActor
struct AutoRecordCoordinatorTests {
    @MainActor
    private final class Recorded {
        var startCalls: [(title: String, attendees: [String])] = []
        var stopCalls = 0
        var nudges: [MeetingNudge] = []
    }

    private func makeCoordinator(
        makeWatcher: @escaping () -> MeetingEventWatching = { FakeWatcher() }
    ) -> (AutoRecordCoordinator, SettingsStore, Recorded) {
        let settings = SettingsStore.ephemeralOnboarded()
        let recorded = Recorded()
        let coordinator = AutoRecordCoordinator(
            settings: settings,
            session: MeetingSessionStore(),
            makeCalendarWatcher: { _ in makeWatcher() },
            makeCallAudioMonitor: { nil },
            todayEventsProvider: { _ in [] },
            startRecording: { title, attendees in recorded.startCalls.append((title, attendees)) },
            stopRecording: { recorded.stopCalls += 1 }
        )
        coordinator.onNudgePresented = { recorded.nudges.append($0) }
        return (coordinator, settings, recorded)
    }

    /// Holds the spy notifier once `AutoRecordCoordinator` lazily builds it
    /// (on the first `ensureNudgeCenter()` call — construction time is too
    /// early, since the coordinator only builds the nudge center/notifier
    /// pair the first time a trigger fires with a non-`.off` policy).
    @MainActor
    private final class NotifierBox {
        var notifier: SpyCallStartNotifier?
    }

    /// Same as `makeCoordinator`, but also hands back a box that's populated
    /// with the spy notifier once the coordinator builds it (after the first
    /// call to `meetingEventStarting`/`applyCalendarAutoRecordSetting` with a
    /// non-`.off` policy) — tests read `.notifier!` only after triggering
    /// that.
    private func makeCoordinatorWithNotifier(
        makeWatcher: @escaping () -> MeetingEventWatching = { FakeWatcher() }
    ) -> (AutoRecordCoordinator, SettingsStore, Recorded, NotifierBox) {
        let settings = SettingsStore.ephemeralOnboarded()
        let recorded = Recorded()
        let box = NotifierBox()
        let coordinator = AutoRecordCoordinator(
            settings: settings,
            session: MeetingSessionStore(),
            makeCalendarWatcher: { _ in makeWatcher() },
            makeCallAudioMonitor: { nil },
            todayEventsProvider: { _ in [] },
            startRecording: { title, attendees in recorded.startCalls.append((title, attendees)) },
            stopRecording: { recorded.stopCalls += 1 },
            makeCallStartNotifier: { recordTapped, onDismissed in
                let spy = SpyCallStartNotifier(recordTapped: recordTapped, onDismissed: onDismissed)
                box.notifier = spy
                return spy
            }
        )
        coordinator.onNudgePresented = { recorded.nudges.append($0) }
        return (coordinator, settings, recorded, box)
    }

    @Test func promptPolicyPresentsAskNudgeWithoutRecording() {
        let (coordinator, settings, recorded) = makeCoordinator()
        settings.calendarAutoRecord = .prompt

        let event = CalendarEventSnapshot(id: "1", title: "Standup", start: .now, end: .now.addingTimeInterval(1_800))
        coordinator.meetingEventStarting(event)

        #expect(recorded.nudges == [.ask(appID: nil, appName: nil, match: event)])
        #expect(recorded.startCalls.isEmpty)
    }

    @Test func autoPolicyStartsRecordingWithEventTitleAndAttendees() {
        let (coordinator, settings, recorded) = makeCoordinator()
        settings.calendarAutoRecord = .auto

        let event = CalendarEventSnapshot(
            id: "2", title: "Roadmap review", start: .now, end: .now.addingTimeInterval(1_800),
            otherAttendees: ["Maya"]
        )
        coordinator.meetingEventStarting(event)

        #expect(recorded.startCalls.count == 1)
        #expect(recorded.startCalls.first?.title == "Roadmap review")
        #expect(recorded.startCalls.first?.attendees == ["Maya"])
    }

    @Test func offPolicyIgnoresStartingEvents() {
        let (coordinator, settings, recorded) = makeCoordinator()
        settings.calendarAutoRecord = .off

        let event = CalendarEventSnapshot(id: "3", title: "Ignored", start: .now, end: .now.addingTimeInterval(1_800))
        coordinator.meetingEventStarting(event)

        #expect(recorded.nudges.isEmpty)
        #expect(recorded.startCalls.isEmpty)
    }

    @Test func applySurfacesAccessDeniedAndClearsOnOff() async throws {
        var watcher: FakeWatcher?
        let (coordinator, settings, _) = makeCoordinator(makeWatcher: {
            let fake = FakeWatcher()
            fake.grantsAccess = false
            watcher = fake
            return fake
        })
        settings.calendarAutoRecord = .prompt
        coordinator.applyCalendarAutoRecordSetting()

        let deadline = ContinuousClock.now + .seconds(5)
        while !coordinator.calendarAccessDenied, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(coordinator.calendarAccessDenied)
        #expect(watcher?.startCallCount == 1)

        settings.calendarAutoRecord = .off
        coordinator.applyCalendarAutoRecordSetting()
        #expect(!coordinator.calendarAccessDenied)
        #expect(watcher?.stopCallCount == 1)
    }

    // MARK: Call-start notification fan-out

    @Test func askDecisionPresentsBothPanelAndNotificationExactlyOnce() {
        let (coordinator, settings, recorded, box) = makeCoordinatorWithNotifier()
        settings.calendarAutoRecord = .prompt

        let event = CalendarEventSnapshot(id: "1", title: "Standup", start: .now, end: .now.addingTimeInterval(1_800))
        coordinator.meetingEventStarting(event)

        let expectedNudge = MeetingNudge.ask(appID: nil, appName: nil, match: event)
        #expect(recorded.nudges == [expectedNudge])
        #expect(box.notifier?.postedNudges == [expectedNudge])
    }

    @Test func autoRecordDecisionAlsoFansOutToNotification() {
        let (coordinator, settings, recorded, box) = makeCoordinatorWithNotifier()
        settings.calendarAutoRecord = .auto

        let event = CalendarEventSnapshot(id: "2", title: "Roadmap review", start: .now, end: .now.addingTimeInterval(1_800))
        coordinator.meetingEventStarting(event)

        #expect(recorded.nudges.count == 1)
        #expect(box.notifier?.postedNudges.count == 1)
        #expect(recorded.startCalls.count == 1)
    }

    @Test func notificationRecordActionRoutesToStartRecording() throws {
        let (coordinator, settings, recorded, box) = makeCoordinatorWithNotifier()
        settings.calendarAutoRecord = .prompt

        let event = CalendarEventSnapshot(
            id: "3", title: "Design crit", start: .now, end: .now.addingTimeInterval(1_800),
            otherAttendees: ["Priya"]
        )
        coordinator.meetingEventStarting(event)
        #expect(recorded.startCalls.isEmpty)

        // Simulate the user tapping "Record" on the system notification
        // (rather than the in-app panel) — this must route through the same
        // `MeetingNudgeCenter.recordTapped` path the panel button uses.
        let notifier = try #require(box.notifier)
        let nudge = notifier.postedNudges[0]
        notifier.recordTapped(nudge)

        #expect(recorded.startCalls.count == 1)
        #expect(recorded.startCalls.first?.title == "Design crit")
        #expect(recorded.startCalls.first?.attendees == ["Priya"])
    }

    @Test func panelActionDismissesTheCallStartNotification() throws {
        let (coordinator, settings, _, box) = makeCoordinatorWithNotifier()
        settings.calendarAutoRecord = .prompt

        let event = CalendarEventSnapshot(id: "4", title: "1:1", start: .now, end: .now.addingTimeInterval(1_800))
        coordinator.meetingEventStarting(event)
        let notifier = try #require(box.notifier)
        #expect(notifier.dismissCallCount == 0)

        // Turning auto-record off is the coordinator's own dismiss path
        // (mirrors the panel's dismiss on `.off`) and must also clear any
        // outstanding call-start notification.
        settings.calendarAutoRecord = .off
        coordinator.applyCalendarAutoRecordSetting()
        #expect(notifier.dismissCallCount == 1)
    }
}
