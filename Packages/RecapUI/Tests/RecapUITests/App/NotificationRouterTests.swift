import Testing
@testable import RecapUI

/// `NotificationRouter` dispatches a delivered/tapped notification's
/// `didReceive`/`willPresent` to whichever handler registered for its
/// category — the seam that lets `CompletionNotifier` and
/// `CallStartNotifier` share the single `UNUserNotificationCenterDelegate`
/// slot without touching a real `UNUserNotificationCenter` in tests.
@MainActor
@Suite struct NotificationRouterTests {
    @Test func dispatchesToTheHandlerRegisteredForItsCategory() {
        let router = NotificationRouter()
        var receivedByA: [String] = []
        var receivedByB: [String] = []
        router.register(category: "A", handler: .init(didReceive: { receivedByA.append($0.notificationIdentifier) }))
        router.register(category: "B", handler: .init(didReceive: { receivedByB.append($0.notificationIdentifier) }))

        router.dispatchForTesting(category: "A", response: .init(notificationIdentifier: "id-1", actionIdentifier: "tap"))

        #expect(receivedByA == ["id-1"])
        #expect(receivedByB.isEmpty)
    }

    @Test func unregisteredCategoryIsIgnoredWithoutCrashing() {
        let router = NotificationRouter()
        var received: [String] = []
        router.register(category: "A", handler: .init(didReceive: { received.append($0.notificationIdentifier) }))

        router.dispatchForTesting(category: "unknown", response: .init(notificationIdentifier: "id-1", actionIdentifier: "tap"))

        #expect(received.isEmpty)
    }

    @Test func registeringTwiceForTheSameCategoryReplacesTheHandler() {
        let router = NotificationRouter()
        var firstCalls = 0
        var secondCalls = 0
        router.register(category: "A", handler: .init(didReceive: { _ in firstCalls += 1 }))
        router.register(category: "A", handler: .init(didReceive: { _ in secondCalls += 1 }))

        router.dispatchForTesting(category: "A", response: .init(notificationIdentifier: "id-1", actionIdentifier: "tap"))

        #expect(firstCalls == 0)
        #expect(secondCalls == 1)
    }

    @Test func willPresentDefaultsToBannerAndSoundWhenNoHandlerRegistered() {
        let router = NotificationRouter()
        #expect(router.willPresentForTesting(category: "unregistered") == [.banner, .sound])
    }
}
