import Foundation
import OSLog
import RecapCore
import UserNotifications

private let prompterLog = Logger(subsystem: "com.gregfoster.recap", category: "RecordPrompter")

/// Posts "meeting starting — record?" notifications and routes the Record
/// action (or a click on the notification) back to the app.
@MainActor
final class RecordPrompter: NSObject, UNUserNotificationCenterDelegate {
    static let categoryID = "MEETING_STARTING"
    static let recordActionID = "RECORD"

    private let onRecord: @MainActor (CalendarEventSnapshot) -> Void
    private var pendingEvents: [String: CalendarEventSnapshot] = [:]

    init(onRecord: @escaping @MainActor (CalendarEventSnapshot) -> Void) {
        self.onRecord = onRecord
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.categoryID,
                actions: [
                    UNNotificationAction(
                        identifier: Self.recordActionID, title: "Record",
                        options: [.foreground]
                    )
                ],
                intentIdentifiers: []
            )
        ])
    }

    func promptToRecord(_ event: CalendarEventSnapshot) {
        Task {
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else {
                prompterLog.info("Notifications not authorized; cannot prompt to record")
                return
            }
            pendingEvents[event.id] = event
            let content = UNMutableNotificationContent()
            content.title = "Meeting starting"
            content.body = "\(event.title) — record it?"
            content.categoryIdentifier = Self.categoryID
            content.sound = nil
            let request = UNNotificationRequest(
                identifier: event.id, content: content, trigger: nil
            )
            try? await center.add(request)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let id = response.notification.request.identifier
        let action = response.actionIdentifier
        await MainActor.run {
            guard let event = pendingEvents.removeValue(forKey: id) else { return }
            // Both the Record button and a plain click start recording — a
            // click on "record it?" reads as consent.
            if action == Self.recordActionID || action == UNNotificationDefaultActionIdentifier {
                onRecord(event)
            }
        }
    }

    /// Show banners even while Recap is frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner]
    }
}
