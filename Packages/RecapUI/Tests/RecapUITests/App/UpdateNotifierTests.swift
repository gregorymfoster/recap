import Testing
@testable import RecapUI

/// `UpdateNotifier`'s pure/testable seams: copy formatting, tap routing
/// through `NotificationRouter`, and the version-dedupe decision. Never
/// touches `UNUserNotificationCenter.current()` — that crashes without a
/// real app bundle — so `postUpdateAvailable`/`removeDelivered` themselves
/// aren't exercised here.
@MainActor
@Suite struct UpdateNotifierTests {
    @Test func titleIncludesVersionWhenKnown() {
        #expect(UpdateNotifier.title(version: "1.4.0") == "Recap 1.4.0 is available")
    }

    @Test func titleFallsBackWhenVersionUnknown() {
        #expect(UpdateNotifier.title(version: nil) == "A Recap update is available")
    }

    @Test func bodyIsFixedCopy() {
        #expect(UpdateNotifier.body() == "Click to install.")
    }

    @Test func tapRoutesToOnInstall() {
        let router = NotificationRouter()
        var installCount = 0
        var activateCount = 0
        // `activateApp` is injected so this drives a real tap through the
        // router without touching the real `NSApp` (nil, and a force-unwrap
        // crash, in this headless test host).
        let notifier = UpdateNotifier(
            router: router,
            onInstall: { installCount += 1 },
            activateApp: { activateCount += 1 }
        )
        _ = notifier

        router.dispatchForTesting(
            category: UpdateNotifier.category,
            response: .init(notificationIdentifier: UpdateNotifier.category, actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier")
        )

        #expect(installCount == 1)
        #expect(activateCount == 1)
    }

    @Test func shouldNotifyWhenNeverNotifiedBefore() {
        #expect(UpdateNotifier.shouldNotify(version: "1.4.0", lastNotified: nil))
        #expect(UpdateNotifier.shouldNotify(version: nil, lastNotified: nil))
    }

    @Test func shouldNotNotifyForSameVersionAlreadyNotified() {
        #expect(UpdateNotifier.shouldNotify(version: "1.4.0", lastNotified: .some("1.4.0")) == false)
        #expect(UpdateNotifier.shouldNotify(version: nil, lastNotified: .some(nil)) == false)
    }

    @Test func shouldNotifyForADifferentVersionThanLastNotified() {
        #expect(UpdateNotifier.shouldNotify(version: "1.5.0", lastNotified: .some("1.4.0")))
        #expect(UpdateNotifier.shouldNotify(version: "1.4.0", lastNotified: .some(nil)))
        #expect(UpdateNotifier.shouldNotify(version: nil, lastNotified: .some("1.4.0")))
    }
}
