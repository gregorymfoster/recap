import Foundation
import OSLog
import UserNotifications

private let routerLog = Logger(subsystem: "com.gregfoster.recap", category: "NotificationRouter")

/// The single `UNUserNotificationCenterDelegate` for the whole process.
///
/// `UNUserNotificationCenter.current().delegate` is one slot — only one
/// object can ever hold it. Rather than let each notifier (`CompletionNotifier`,
/// `CallStartNotifier`) fight over that slot (last writer wins, silently
/// breaking whichever one loses), this router is the *only* thing that ever
/// assigns it, and dispatches by `categoryIdentifier` to per-category
/// handlers registered by whoever cares about that category. Registration
/// order doesn't matter and handlers never see each other's categories.
@MainActor
public final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    /// A tapped/dismissed notification's Sendable essentials — extracted from
    /// the non-Sendable `UNNotificationResponse` before crossing back onto
    /// the main actor, so registered handlers never have to deal with
    /// `nonisolated`/`Sendable` friction themselves.
    public struct Response: Sendable {
        public let notificationIdentifier: String
        public let actionIdentifier: String
    }

    /// A category owner's response to a delivered/tapped notification.
    public struct Handler {
        /// `userNotificationCenter(_:didReceive:)` for this category.
        public let didReceive: @MainActor (Response) -> Void
        /// `userNotificationCenter(_:willPresent:)` for this category —
        /// defaults to showing a banner + sound, which is what every
        /// registrant here wants today.
        public let willPresent: @MainActor () -> UNNotificationPresentationOptions

        public init(
            didReceive: @escaping @MainActor (Response) -> Void,
            willPresent: @escaping @MainActor () -> UNNotificationPresentationOptions = { [.banner, .sound] }
        ) {
            self.didReceive = didReceive
            self.willPresent = willPresent
        }
    }

    private var handlers: [String: Handler] = [:]

    override public init() {
        super.init()
    }

    /// Installs this router as the process's sole notification-center
    /// delegate. Call exactly once, at app-composition time.
    public func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Registers (or replaces) the handler for a category identifier.
    public func register(category: String, handler: Handler) {
        handlers[category] = handler
    }

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let category = response.notification.request.content.categoryIdentifier
        let sendableResponse = Response(
            notificationIdentifier: response.notification.request.identifier,
            actionIdentifier: response.actionIdentifier
        )
        await MainActor.run {
            dispatch(category: category, response: sendableResponse)
        }
    }

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let category = notification.request.content.categoryIdentifier
        return await MainActor.run {
            willPresent(category: category)
        }
    }

    /// Shared by the real delegate callback above and
    /// `dispatchForTesting(category:response:)` — the only place category
    /// lookup + no-handler logging happens.
    private func dispatch(category: String, response: Response) {
        guard let handler = handlers[category] else {
            routerLog.info("No handler registered for category \(category, privacy: .public)")
            return
        }
        handler.didReceive(response)
    }

    private func willPresent(category: String) -> UNNotificationPresentationOptions {
        handlers[category]?.willPresent() ?? [.banner, .sound]
    }

    // MARK: Test seam

    /// Drives dispatch directly with a synthesized `Response`, so tests can
    /// exercise category routing without constructing a real
    /// `UNNotificationResponse` (which the framework doesn't allow
    /// constructing with an arbitrary category anyway).
    func dispatchForTesting(category: String, response: Response) {
        dispatch(category: category, response: response)
    }

    /// Test seam for `willPresent`'s category-based dispatch.
    func willPresentForTesting(category: String) -> UNNotificationPresentationOptions {
        willPresent(category: category)
    }
}
