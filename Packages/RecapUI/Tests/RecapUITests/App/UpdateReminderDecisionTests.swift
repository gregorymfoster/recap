import Testing
@testable import RecapUI

/// Full 2×2 matrix for `UpdateReminderDecision.decide(...)`.
@Suite struct UpdateReminderDecisionTests {
    @Test func userInitiatedWithSparkleDialogTakesNoLayeredAction() {
        let actions = UpdateReminderDecision.decide(sparkleWillShowDialog: true, userInitiated: true)
        #expect(actions == .init(markAvailable: false, postNotification: false))
    }

    @Test func userInitiatedWithoutSparkleDialogTakesNoLayeredAction() {
        let actions = UpdateReminderDecision.decide(sparkleWillShowDialog: false, userInitiated: true)
        #expect(actions == .init(markAvailable: false, postNotification: false))
    }

    @Test func scheduledWithSparkleDialogMarksAvailableOnly() {
        let actions = UpdateReminderDecision.decide(sparkleWillShowDialog: true, userInitiated: false)
        #expect(actions == .init(markAvailable: true, postNotification: false))
    }

    @Test func scheduledWithSuppressedDialogAlsoPostsNotification() {
        let actions = UpdateReminderDecision.decide(sparkleWillShowDialog: false, userInitiated: false)
        #expect(actions == .init(markAvailable: true, postNotification: true))
    }
}
