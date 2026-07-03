import Testing
@testable import RecapUI

/// Serialized because the auto-dismiss timing assertions are sensitive to CPU
/// contention: under the RecapUI target's default cross-suite parallelism on a
/// loaded CI runner, the internal dismissal timer and a test's own wait race
/// and stretch non-proportionally. Serialization plus `waitUntil` polling (vs.
/// fixed-margin sleep-then-assert) removes both sources of flakiness.
@Suite(.serialized) struct ToastCenterTests {
    /// Polls `condition` until it holds or the timeout elapses. Robust to CI
    /// schedulers that stretch timer scheduling, unlike a single fixed sleep.
    @MainActor
    private func waitUntil(
        _ timeout: Duration = .seconds(2),
        _ condition: () -> Bool
    ) async {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < timeout {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

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
        await waitUntil { center.current == nil }
        #expect(center.current == nil)
    }

    @MainActor
    @Test func autoDismissAdvancesQueueToNextToast() async throws {
        let center = ToastCenter(dismissDelay: .milliseconds(30))
        center.show("First")
        // The second is an action toast so it never auto-dismisses: once the
        // first times out and the queue advances, "Second" stays current with
        // no upper time bound. This avoids a two-sided timing race (first gone
        // AND second not yet gone) that flaked under CI test-parallelism, where
        // the two independent timers don't stretch together under load.
        center.show("Second", actionTitle: "Act") {}
        await waitUntil { center.current?.message == "Second" }
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
        await waitUntil { center.current == nil }
        #expect(center.current == nil)
    }
}
