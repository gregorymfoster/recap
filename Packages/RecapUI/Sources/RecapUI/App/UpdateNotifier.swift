import AppKit
import Foundation
import OSLog
import UserNotifications

private let updateNotifierLog = Logger(subsystem: "com.gregfoster.recap", category: "UpdateNotifier")

/// Posts the system-notification half of the layered update-available UX
/// (`UpdateReminderDecision` decides whether one should fire at all). Mirrors
/// `CompletionNotifier`'s shape closely: lazy authorization requested on
/// first use (never at launch), silent degradation on denial, and
/// registration with the shared `NotificationRouter` rather than holding the
/// delegate slot itself.
///
/// Uses a single fixed notification identifier (`Self.category`) rather than
/// a fresh UUID per post — a newer version's notification simply replaces
/// whatever's currently delivered/pending, so Notification Center never
/// accumulates a stack of stale "update available" banners.
@MainActor
public final class UpdateNotifier {
    static let category = "com.gregfoster.recap.update"

    private var didRequestAuthorization = false
    /// The version most recently posted, so repeat calls for the same
    /// version (e.g. re-confirmed by successive scheduled checks) don't
    /// re-post. Double-optional: outer `nil` means "never posted this
    /// process"; `.some(nil)` means "posted once with an unknown version".
    private var lastNotifiedVersion: String??

    /// Routes the notification tap back to Sparkle's install flow (wired by
    /// `AppStores` to `UpdateStatus.triggerInstall()`), then brings the app
    /// forward — mirrors `CompletionNotifier`/`CallStartNotifier`'s activate.
    private let onInstall: @MainActor () -> Void
    /// `NSApp.activate(ignoringOtherApps:)`, injectable so tests can drive a
    /// real tap through `NotificationRouter.dispatchForTesting` without
    /// touching `NSApp` — which is nil (and force-unwrap-crashes) in the
    /// headless `swift test` host.
    private let activateApp: @MainActor () -> Void

    public init(
        router: NotificationRouter,
        onInstall: @escaping @MainActor () -> Void,
        activateApp: @escaping @MainActor () -> Void = { NSApp.activate(ignoringOtherApps: true) }
    ) {
        self.onInstall = onInstall
        self.activateApp = activateApp
        router.register(
            category: Self.category,
            handler: NotificationRouter.Handler(
                didReceive: { [weak self] _ in
                    self?.onInstall()
                    self?.activateApp()
                },
                willPresent: { [.banner, .sound] }
            )
        )
    }

    /// Posts (or, for a version already posted this process, no-ops) the
    /// "update available" notification.
    public func postUpdateAvailable(version: String?) {
        guard Self.shouldNotify(version: version, lastNotified: lastNotifiedVersion) else { return }
        lastNotifiedVersion = version

        Task {
            let center = UNUserNotificationCenter.current()
            if !didRequestAuthorization {
                didRequestAuthorization = true
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                updateNotifierLog.info("Notifications not authorized; skipping update-available notification")
                return
            }

            let content = UNMutableNotificationContent()
            content.title = Self.title(version: version)
            content.body = Self.body()
            content.sound = .default
            content.categoryIdentifier = Self.category
            let request = UNNotificationRequest(identifier: Self.category, content: content, trigger: nil)
            try? await center.add(request)
        }
    }

    /// Removes any delivered/pending update notification — used when the
    /// user installs (or otherwise dismisses the update) through another
    /// path first, so a stale notification doesn't linger.
    public func removeDelivered() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.category])
        center.removePendingNotificationRequests(withIdentifiers: [Self.category])
    }

    static func title(version: String?) -> String {
        if let version { return "Recap \(version) is available" }
        return "A Recap update is available"
    }

    static func body() -> String { "Click to install." }

    /// Pure dedupe seam, directly testable: whether `version` should trigger
    /// a fresh notification given what's already been posted this process.
    static func shouldNotify(version: String?, lastNotified: String??) -> Bool {
        guard let lastNotified else { return true }
        return lastNotified != version
    }
}
