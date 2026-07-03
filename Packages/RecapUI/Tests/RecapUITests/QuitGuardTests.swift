import Testing
@testable import RecapUI

/// `QuitGuard.decide` — the pure ⌘Q-while-recording branch (design spec 8f):
/// no active recording quits immediately; an active recording routes through
/// the confirmation alert instead.
@Suite struct QuitGuardTests {
    @Test func terminatesImmediatelyWhenNotRecording() {
        let decision = QuitGuard.decide(isRecording: false, title: "Weekly standup", elapsedLabel: "12:41")
        #expect(decision == .terminateNow)
    }

    @Test func confirmsBeforeTerminatingWhenRecording() {
        let decision = QuitGuard.decide(isRecording: true, title: "Weekly standup", elapsedLabel: "12:41")
        #expect(decision == .confirmBeforeTerminating(title: "Weekly standup", elapsedLabel: "12:41"))
    }

    @Test func passesTitleAndElapsedLabelThroughUnmodified() {
        let decision = QuitGuard.decide(isRecording: true, title: "1:1 with Sam", elapsedLabel: "1:02:34")
        #expect(decision == .confirmBeforeTerminating(title: "1:1 with Sam", elapsedLabel: "1:02:34"))
    }
}
