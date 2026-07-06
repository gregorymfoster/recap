import AppKit
import Foundation
import OSLog
import UserNotifications

private let callStartNotifierLog = Logger(subsystem: "com.gregfoster.recap", category: "CallStartNotifier")

/// Seam `AutoRecordCoordinator` drives instead of the concrete
/// `CallStartNotifier`, so tests can inject a spy that never touches a real
/// `UNUserNotificationCenter`.
@MainActor
public protocol CallStartNotifying: AnyObject {
    /// Posts (or updates) the system notification for a nudge.
    func post(_ nudge: MeetingNudge)
    /// Removes the most recently delivered call-start notification — used
    /// for cross-dismissal when the in-app panel's own button is used first.
    func dismissLastDelivered()
}

/// Posts a real system notification alongside the in-app "Meeting started?"
/// panel (`MeetingNudgePanelController`) — added because the panel alone is
/// easy to miss when Recap isn't the frontmost app. Mirrors
/// `CompletionNotifier`'s shape closely: lazy authorization requested on
/// first use (never at launch), silent degradation on denial, an in-memory
/// `identifier -> MeetingNudge` map so a tapped action routes back to the
/// right nudge, and registration with the shared `NotificationRouter` rather
/// than holding the delegate slot itself.
///
/// `.ask` nudges get actionable "Record"/"Ignore" buttons wired to a
/// notification category; `.recordingStarted` (auto-record) gets an
/// informational banner only — recording has already started, so there's
/// nothing actionable left to offer besides opening the app.
@MainActor
public final class CallStartNotifier: CallStartNotifying {
    static let askCategory = "com.gregfoster.recap.call-start.ask"
    static let recordingStartedCategory = "com.gregfoster.recap.call-start.recording-started"
    static let recordActionID = "com.gregfoster.recap.call-start.record"
    static let ignoreActionID = "com.gregfoster.recap.call-start.ignore"

    private var didRequestAuthorization = false
    private var didRegisterCategories = false

    /// Pending asks awaiting a tap, keyed by notification identifier. Only
    /// `.ask` nudges are stored — a `.recordingStarted` banner has no
    /// Record action to route back to.
    private var pendingAsks: [String: MeetingNudge] = [:]

    /// The most recently delivered notification's identifier, so the panel
    /// side (`AutoRecordCoordinator`) can remove it if its own Record/Not now
    /// button is used first — reasonable-effort cross-dismissal, not a full
    /// per-nudge index.
    private(set) var lastDeliveredIdentifier: String?

    /// Routes the notification's Record action back through the same path
    /// the panel's Record button uses (`MeetingNudgeCenter.recordTapped`),
    /// and brings the app forward (mirrors `CompletionNotifier`'s activate).
    private let recordTapped: @MainActor (MeetingNudge) -> Void
    /// Called whenever a call-start notification is delivered or cleared, so
    /// the coordinator can dismiss the in-app panel if the notification's
    /// action is taken first.
    private let onDismissed: @MainActor () -> Void

    public init(
        router: NotificationRouter,
        recordTapped: @escaping @MainActor (MeetingNudge) -> Void,
        onDismissed: @escaping @MainActor () -> Void = {}
    ) {
        self.recordTapped = recordTapped
        self.onDismissed = onDismissed
        router.register(
            category: Self.askCategory,
            handler: NotificationRouter.Handler(didReceive: { [weak self] response in
                self?.handleAskResponse(response)
            })
        )
        router.register(
            category: Self.recordingStartedCategory,
            handler: NotificationRouter.Handler(didReceive: { [weak self] response in
                self?.handleRecordingStartedResponse(response)
            })
        )
    }

    /// Posts the notification for a nudge. `.ask` gets the actionable
    /// Record/Ignore category; `.recordingStarted` gets an informational
    /// banner (tapping just opens the app — there's no `didReceive` routing
    /// needed since `NSApp.activate` already happens for any tap via the
    /// default action, and there's nothing else to do).
    public func post(_ nudge: MeetingNudge) {
        Task {
            guard await ensureAuthorized() else {
                callStartNotifierLog.info("Notifications not authorized; skipping call-start notification")
                return
            }
            await registerCategoriesIfNeeded()

            let identifier = UUID().uuidString
            let content = UNMutableNotificationContent()
            content.title = MeetingNudgeCopy.title(for: nudge)
            content.body = MeetingNudgeCopy.body(for: nudge)
            content.sound = .default

            switch nudge {
            case .ask:
                pendingAsks[identifier] = nudge
                content.categoryIdentifier = Self.askCategory
            case .recordingStarted:
                content.categoryIdentifier = Self.recordingStartedCategory
            }

            lastDeliveredIdentifier = identifier
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    /// Removes the most recently delivered call-start notification — used
    /// when the in-app panel's own button is used first, so a stale
    /// notification doesn't linger in Notification Center for an action
    /// that's already been taken.
    public func dismissLastDelivered() {
        guard let identifier = lastDeliveredIdentifier else { return }
        lastDeliveredIdentifier = nil
        pendingAsks.removeValue(forKey: identifier)
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    private func handleAskResponse(_ response: NotificationRouter.Response) {
        let identifier = response.notificationIdentifier
        guard let nudge = pendingAsks.removeValue(forKey: identifier) else { return }
        if identifier == lastDeliveredIdentifier {
            lastDeliveredIdentifier = nil
        }
        switch response.actionIdentifier {
        case Self.recordActionID, UNNotificationDefaultActionIdentifier:
            recordTapped(nudge)
            activateApp()
            onDismissed()
        case Self.ignoreActionID, UNNotificationDismissActionIdentifier:
            onDismissed()
        default:
            break
        }
    }

    private func handleRecordingStartedResponse(_ response: NotificationRouter.Response) {
        // Informational only: any tap (including the default "open the
        // notification" tap) just brings the app forward.
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        activateApp()
    }

    private func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
    }

    private func ensureAuthorized() async -> Bool {
        let center = UNUserNotificationCenter.current()
        if !didRequestAuthorization {
            didRequestAuthorization = true
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        let settings = await center.notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    /// Registers the "Record"/"Ignore" action category once, lazily (no
    /// point registering before the first post, and no harm calling this
    /// more than once besides a wasted round trip — guarded anyway).
    private func registerCategoriesIfNeeded() async {
        guard !didRegisterCategories else { return }
        didRegisterCategories = true
        let record = UNNotificationAction(
            identifier: Self.recordActionID, title: "Record", options: [.foreground]
        )
        let ignore = UNNotificationAction(
            identifier: Self.ignoreActionID, title: "Ignore", options: [.destructive]
        )
        let askCategory = UNNotificationCategory(
            identifier: Self.askCategory, actions: [record, ignore], intentIdentifiers: [],
            options: []
        )
        let recordingStartedCategory = UNNotificationCategory(
            identifier: Self.recordingStartedCategory, actions: [], intentIdentifiers: [], options: []
        )
        let center = UNUserNotificationCenter.current()
        let existing = await center.notificationCategories()
        center.setNotificationCategories(existing.union([askCategory, recordingStartedCategory]))
    }
}
