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
}
