import Foundation
import Testing
@testable import RecapCore

@Suite struct MeetingDetectionRulesTests {
    private static let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func meetingShapedEvent(
        id: String = "e1", start: Date? = nil, end: Date? = nil
    ) -> CalendarEventSnapshot {
        CalendarEventSnapshot(
            id: id, title: "Sync",
            start: start ?? Self.now, end: end ?? Self.now.addingTimeInterval(1800),
            otherAttendees: ["Maya"], hasConferenceURL: true
        )
    }

    private func nonMeetingShapedEvent(id: String = "solo", start: Date? = nil) -> CalendarEventSnapshot {
        CalendarEventSnapshot(
            id: id, title: "Focus block",
            start: start ?? Self.now, end: (start ?? Self.now).addingTimeInterval(1800)
        )
    }

    // MARK: decision — off policy always no-ops

    @Test(
        arguments: [
            (isRecording: false, appEnabled: false, alreadyHandled: false, hasMatch: false),
            (isRecording: true, appEnabled: true, alreadyHandled: false, hasMatch: true),
            (isRecording: false, appEnabled: true, alreadyHandled: true, hasMatch: true),
        ]
    )
    func offPolicyAlwaysNone(
        isRecording: Bool, appEnabled: Bool, alreadyHandled: Bool, hasMatch: Bool
    ) {
        let match = hasMatch ? meetingShapedEvent() : nil
        let decision = MeetingDetectionRules.decision(
            policy: .off, isRecording: isRecording, appEnabled: appEnabled,
            alreadyHandled: alreadyHandled, match: match
        )
        #expect(decision == .none)
    }

    // MARK: decision — the three "stay quiet" gates apply regardless of policy

    @Test(arguments: [MeetingDetectionRules.Policy.prompt, .auto])
    func alreadyRecordingAlwaysNone(policy: MeetingDetectionRules.Policy) {
        let decision = MeetingDetectionRules.decision(
            policy: policy, isRecording: true, appEnabled: true, alreadyHandled: false,
            match: meetingShapedEvent()
        )
        #expect(decision == .none)
    }

    @Test(arguments: [MeetingDetectionRules.Policy.prompt, .auto])
    func appDisabledAlwaysNone(policy: MeetingDetectionRules.Policy) {
        let decision = MeetingDetectionRules.decision(
            policy: policy, isRecording: false, appEnabled: false, alreadyHandled: false,
            match: meetingShapedEvent()
        )
        #expect(decision == .none)
    }

    @Test(arguments: [MeetingDetectionRules.Policy.prompt, .auto])
    func alreadyHandledAlwaysNone(policy: MeetingDetectionRules.Policy) {
        let decision = MeetingDetectionRules.decision(
            policy: policy, isRecording: false, appEnabled: true, alreadyHandled: true,
            match: meetingShapedEvent()
        )
        #expect(decision == .none)
    }

    // MARK: decision — prompt policy always asks (match or not) once gates clear

    @Test func promptWithMatchAsksCarryingMatch() {
        let event = meetingShapedEvent()
        let decision = MeetingDetectionRules.decision(
            policy: .prompt, isRecording: false, appEnabled: true, alreadyHandled: false, match: event
        )
        #expect(decision == .ask(match: event))
    }

    @Test func promptWithNoMatchAsksWithNilMatch() {
        let decision = MeetingDetectionRules.decision(
            policy: .prompt, isRecording: false, appEnabled: true, alreadyHandled: false, match: nil
        )
        #expect(decision == .ask(match: nil))
    }

    // MARK: decision — auto policy auto-records only with a match, else downgrades to ask

    @Test func autoWithMatchAutoRecords() {
        let event = meetingShapedEvent()
        let decision = MeetingDetectionRules.decision(
            policy: .auto, isRecording: false, appEnabled: true, alreadyHandled: false, match: event
        )
        #expect(decision == .autoRecord(event))
    }

    @Test func autoWithNoMatchDowngradesToAsk() {
        let decision = MeetingDetectionRules.decision(
            policy: .auto, isRecording: false, appEnabled: true, alreadyHandled: false, match: nil
        )
        #expect(decision == .ask(match: nil))
    }

    // MARK: matchEvent — picking

    @Test func matchEventPicksOngoingEvent() {
        let event = meetingShapedEvent(start: Self.now.addingTimeInterval(-600), end: Self.now.addingTimeInterval(600))
        let match = MeetingDetectionRules.matchEvent(in: [event], now: Self.now)
        #expect(match == event)
    }

    @Test func matchEventPicksEventStartingWithinNineMinutes() {
        let event = meetingShapedEvent(
            start: Self.now.addingTimeInterval(9 * 60), end: Self.now.addingTimeInterval(9 * 60 + 1800)
        )
        let match = MeetingDetectionRules.matchEvent(in: [event], now: Self.now)
        #expect(match == event)
    }

    @Test func matchEventExcludesEventStartingInElevenMinutes() {
        let event = meetingShapedEvent(
            start: Self.now.addingTimeInterval(11 * 60), end: Self.now.addingTimeInterval(11 * 60 + 1800)
        )
        let match = MeetingDetectionRules.matchEvent(in: [event], now: Self.now)
        #expect(match == nil)
    }

    @Test func matchEventExcludesEndedEvent() {
        let event = meetingShapedEvent(
            start: Self.now.addingTimeInterval(-3600), end: Self.now.addingTimeInterval(-60)
        )
        let match = MeetingDetectionRules.matchEvent(in: [event], now: Self.now)
        #expect(match == nil)
    }

    @Test func matchEventPicksClosestStartWhenMultipleQualify() {
        let far = meetingShapedEvent(
            id: "far", start: Self.now.addingTimeInterval(-500), end: Self.now.addingTimeInterval(1000)
        )
        let close = meetingShapedEvent(
            id: "close", start: Self.now.addingTimeInterval(-30), end: Self.now.addingTimeInterval(1000)
        )
        let match = MeetingDetectionRules.matchEvent(in: [far, close], now: Self.now)
        #expect(match == close)
    }

    @Test func matchEventExcludesNonMeetingShapedEvent() {
        let event = nonMeetingShapedEvent(start: Self.now)
        let match = MeetingDetectionRules.matchEvent(in: [event], now: Self.now)
        #expect(match == nil)
    }
}
