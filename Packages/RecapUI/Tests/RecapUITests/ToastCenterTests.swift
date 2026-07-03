import Testing
@testable import RecapUI

@Suite struct ToastCenterTests {
    @MainActor
    @Test func showPresentsImmediatelyWhenIdle() {
        let center = ToastCenter()
        center.show("Hello")
        #expect(center.current?.message == "Hello")
    }

    @MainActor
    @Test func secondToastQueuesBehindTheFirst() {
        let center = ToastCenter()
        center.show("First")
        center.show("Second")
        #expect(center.current?.message == "First")
    }

    @MainActor
    @Test func dismissCurrentAdvancesToNextQueued() {
        let center = ToastCenter()
        center.show("First")
        center.show("Second")
        center.dismissCurrent()
        #expect(center.current?.message == "Second")
    }

    @MainActor
    @Test func dismissWithEmptyQueueClearsCurrent() {
        let center = ToastCenter()
        center.show("Only one")
        center.dismissCurrent()
        #expect(center.current == nil)
    }

    @MainActor
    @Test func autoDismissesAfterTheConfiguredDelay() async throws {
        let center = ToastCenter(dismissDelay: .milliseconds(30))
        center.show("Fleeting")
        #expect(center.current?.message == "Fleeting")
        try await Task.sleep(for: .milliseconds(120))
        #expect(center.current == nil)
    }

    @MainActor
    @Test func autoDismissAdvancesQueueToNextToast() async throws {
        let center = ToastCenter(dismissDelay: .milliseconds(60))
        center.show("First")
        center.show("Second")
        // Wait past the first toast's dismissal but well before the
        // second's, so only the advance has had a chance to happen.
        try await Task.sleep(for: .milliseconds(90))
        #expect(center.current?.message == "Second")
    }

    @MainActor
    @Test func actionHandlerFiresWhenInvoked() {
        let center = ToastCenter()
        var actionFired = false
        center.show("Needs action", actionTitle: "Do it") { actionFired = true }
        center.current?.action?.handler()
        #expect(actionFired)
    }

    @MainActor
    @Test func convenienceShowWithoutActionHasNilAction() {
        let center = ToastCenter()
        center.show("Plain message")
        #expect(center.current?.action == nil)
    }

    @MainActor
    @Test func actionToastDoesNotAutoDismiss() async throws {
        let center = ToastCenter(dismissDelay: .milliseconds(30))
        center.show("Needs action", actionTitle: "Do it") {}
        try await Task.sleep(for: .milliseconds(120))
        #expect(center.current?.message == "Needs action")
    }

    @MainActor
    @Test func plainToastStillAutoDismissesWhenQueuedBehindAnActionToast() async throws {
        let center = ToastCenter(dismissDelay: .milliseconds(30))
        center.show("Needs action", actionTitle: "Do it") {}
        center.show("Plain follow-up")
        // The action toast never auto-dismisses, so manually dismiss it to
        // advance the queue, then confirm the plain one still times out.
        center.dismissCurrent()
        #expect(center.current?.message == "Plain follow-up")
        try await Task.sleep(for: .milliseconds(120))
        #expect(center.current == nil)
    }
}
