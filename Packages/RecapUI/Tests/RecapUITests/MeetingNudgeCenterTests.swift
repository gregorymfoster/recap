import Foundation
import RecapAudio
import RecapCore
import Testing
@testable import RecapUI

/// Drives `MeetingNudgeCenter` entirely through closures — no `NSPanel`, no
/// `CalendarWatcher`, no real audio monitor ever touched.
@MainActor
@Suite struct MeetingNudgeCenterTests {
    private static let now = Date(timeIntervalSinceReferenceDate: 2_000_000)

    /// Records every call made to the closures the center drives, so tests
    /// can assert on both "what got presented" and "what side effect fired".
    @MainActor
    private final class Spy {
        var policy: MeetingDetectionRules.Policy = .prompt
        var isRecording = false
        var disabledAppIDs: Set<String> = []
        var events: [CalendarEventSnapshot] = []
        private(set) var presented: [MeetingNudge] = []
        private(set) var startRecordingCalls: [(title: String, attendees: [String])] = []
        var now = MeetingNudgeCenterTests.now

        func makeCenter() -> MeetingNudgeCenter {
            MeetingNudgeCenter(
                policy: { [weak self] in self?.policy ?? .off },
                isRecording: { [weak self] in self?.isRecording ?? false },
                disabledAppIDs: { [weak self] in self?.disabledAppIDs ?? [] },
                todayEvents: { [weak self] _ in self?.events ?? [] },
                present: { [weak self] nudge in self?.presented.append(nudge) },
                startRecording: { [weak self] title, attendees in
                    self?.startRecordingCalls.append((title, attendees))
                },
                now: { [weak self] in self?.now ?? MeetingNudgeCenterTests.now }
            )
        }
    }

    private func meetingShapedEvent(
        id: String = "event-1", title: String = "Standup", start: Date? = nil, end: Date? = nil,
        attendees: [String] = ["Maya"]
    ) -> CalendarEventSnapshot {
        CalendarEventSnapshot(
            id: id, title: title,
            start: start ?? Self.now, end: end ?? Self.now.addingTimeInterval(1800),
            otherAttendees: attendees, hasConferenceURL: true
        )
    }

    // MARK: Calendar trigger

    @Test func calendarTriggerPromptPresentsAskWithMatchOnce() {
        let spy = Spy()
        spy.policy = .prompt
        let center = spy.makeCenter()
        let event = meetingShapedEvent()

        center.calendarEventStarting(event)
        #expect(spy.presented == [.ask(appID: nil, appName: nil, match: event)])

        // Second call for the same event: already handled, nothing new.
        center.calendarEventStarting(event)
        #expect(spy.presented.count == 1)
    }

    @Test func calendarTriggerAutoStartsRecordingAndPresentsRecordingStarted() {
        let spy = Spy()
        spy.policy = .auto
        spy.now = Self.now.addingTimeInterval(12)
        let center = spy.makeCenter()
        let event = meetingShapedEvent(title: "Roadmap review", start: Self.now, attendees: ["Jordan"])

        center.calendarEventStarting(event)

        #expect(spy.startRecordingCalls.count == 1)
        #expect(spy.startRecordingCalls.first?.title == "Roadmap review")
        #expect(spy.startRecordingCalls.first?.attendees == ["Jordan"])
        #expect(spy.presented == [.recordingStarted(event: event, missedSeconds: 12)])
    }

    @Test func calendarTriggerAutoClampsNegativeMissedSecondsToZero() {
        let spy = Spy()
        spy.policy = .auto
        // now before the event start (clock skew / early fire) — missed
        // seconds must clamp to 0, never go negative.
        spy.now = Self.now.addingTimeInterval(-5)
        let center = spy.makeCenter()
        let event = meetingShapedEvent(start: Self.now)

        center.calendarEventStarting(event)

        #expect(spy.presented == [.recordingStarted(event: event, missedSeconds: 0)])
    }

    // MARK: Audio trigger

    @Test func audioTriggerUnknownBundleDoesNothing() {
        let spy = Spy()
        let center = spy.makeCenter()

        center.callAudioEvent(.appStartedAudio(bundleID: "com.example.unknown"))

        #expect(spy.presented.isEmpty)
        #expect(spy.startRecordingCalls.isEmpty)
    }

    @Test func audioTriggerDisabledAppDoesNothing() {
        let spy = Spy()
        spy.policy = .prompt
        spy.disabledAppIDs = ["us.zoom.xos"]
        let center = spy.makeCenter()

        center.callAudioEvent(.appStartedAudio(bundleID: "us.zoom.xos"))

        #expect(spy.presented.isEmpty)
    }

    @Test func audioTriggerWithCalendarMatchCarriesIt() {
        let spy = Spy()
        spy.policy = .prompt
        let event = meetingShapedEvent(start: Self.now.addingTimeInterval(-30))
        spy.events = [event]
        let center = spy.makeCenter()

        center.callAudioEvent(.appStartedAudio(bundleID: "us.zoom.xos"))

        #expect(spy.presented == [.ask(appID: "us.zoom.xos", appName: "Zoom", match: event)])
    }

    @Test func audioTriggerWithNoMatchAsksAppOnly() {
        let spy = Spy()
        spy.policy = .prompt
        spy.events = []
        let center = spy.makeCenter()

        center.callAudioEvent(.appStartedAudio(bundleID: "us.zoom.xos"))

        #expect(spy.presented == [.ask(appID: "us.zoom.xos", appName: "Zoom", match: nil)])
    }

    @Test func audioTriggerAutoRecordUsesMatchStartForMissedSeconds() {
        let spy = Spy()
        spy.policy = .auto
        spy.now = Self.now
        let event = meetingShapedEvent(start: Self.now.addingTimeInterval(-45))
        spy.events = [event]
        let center = spy.makeCenter()

        center.callAudioEvent(.appStartedAudio(bundleID: "us.zoom.xos"))

        #expect(spy.presented == [.recordingStarted(event: event, missedSeconds: 45)])
        #expect(spy.startRecordingCalls.count == 1)
    }

    @Test func appOnlyDedupeUntilAppStoppedAudio() {
        let spy = Spy()
        spy.policy = .prompt
        spy.events = []
        let center = spy.makeCenter()

        center.callAudioEvent(.appStartedAudio(bundleID: "us.zoom.xos"))
        #expect(spy.presented.count == 1)

        // Same session continuing (another started-audio ping): still
        // deduped, no second nudge.
        center.callAudioEvent(.appStartedAudio(bundleID: "us.zoom.xos"))
        #expect(spy.presented.count == 1)

        // Audio stops: clears the app-only handled key.
        center.callAudioEvent(.appStoppedAudio(bundleID: "us.zoom.xos"))

        // A new session can nudge again.
        center.callAudioEvent(.appStartedAudio(bundleID: "us.zoom.xos"))
        #expect(spy.presented.count == 2)
    }

    @Test func appStoppedAudioForUnknownBundleIsIgnored() {
        let spy = Spy()
        let center = spy.makeCenter()
        // Must not crash for an id the catalog doesn't recognize.
        center.callAudioEvent(.appStoppedAudio(bundleID: "com.example.unknown"))
        #expect(spy.presented.isEmpty)
    }

    // MARK: recordTapped

    @Test func recordTappedWithMatchUsesMatchTitleAndAttendees() {
        let spy = Spy()
        let center = spy.makeCenter()
        let event = meetingShapedEvent(title: "Design crit", attendees: ["Priya", "Sam"])
        let nudge = MeetingNudge.ask(appID: "us.zoom.xos", appName: "Zoom", match: event)

        center.recordTapped(for: nudge)

        #expect(spy.startRecordingCalls.count == 1)
        #expect(spy.startRecordingCalls.first?.title == "Design crit")
        #expect(spy.startRecordingCalls.first?.attendees == ["Priya", "Sam"])
    }

    @Test func recordTappedAppOnlyFallsBackToAppCallTitle() {
        let spy = Spy()
        let center = spy.makeCenter()
        let nudge = MeetingNudge.ask(appID: "com.microsoft.teams2", appName: "Microsoft Teams", match: nil)

        center.recordTapped(for: nudge)

        #expect(spy.startRecordingCalls.count == 1)
        #expect(spy.startRecordingCalls.first?.title == "Microsoft Teams call")
        #expect(spy.startRecordingCalls.first?.attendees == [])
    }

    @Test func recordTappedOnRecordingStartedNudgeDoesNothing() {
        let spy = Spy()
        let center = spy.makeCenter()
        let event = meetingShapedEvent()
        let nudge = MeetingNudge.recordingStarted(event: event, missedSeconds: 0)

        center.recordTapped(for: nudge)

        #expect(spy.startRecordingCalls.isEmpty)
    }

    // MARK: dontAskTapped

    @Test func dontAskTappedRoutesAppIDToDisableApp() {
        let spy = Spy()
        let center = spy.makeCenter()
        var disabledID: String?

        center.dontAskTapped(appID: "us.zoom.xos") { id in disabledID = id }

        #expect(disabledID == "us.zoom.xos")
    }
}
