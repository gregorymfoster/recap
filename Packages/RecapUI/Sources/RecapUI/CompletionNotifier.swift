import Foundation
import OSLog
import RecapCore
import UserNotifications

private let notifierLog = Logger(subsystem: "com.gregfoster.recap", category: "CompletionNotifier")

/// Pure decision logic for the ⌘Q-while-recording guard (design spec 8f).
///
/// `AppDelegate.applicationShouldTerminate(_:)` is a thin AppKit shell around
/// this: it reads live session state, calls `QuitGuard.decide(...)`, and only
/// shows the alert / runs the stop-and-save flow when this says to. Kept
/// framework-free so the branch (recording vs not) is unit-testable without
/// booting AppKit.
public enum QuitGuard {
    public enum Decision: Equatable, Sendable {
        /// No active recording — terminate immediately.
        case terminateNow
        /// A recording is active — show the confirmation alert before
        /// deciding whether to terminate.
        case confirmBeforeTerminating(title: String, elapsedLabel: String)
    }

    /// - Parameters:
    ///   - isRecording: `MeetingSessionStore.isRecording` (true while paused too).
    ///   - title: The active meeting's title, for the alert's message text.
    ///   - elapsedLabel: Pre-formatted elapsed time (`RecordingPill.elapsedLabel`),
    ///     for the alert's informative text.
    public static func decide(isRecording: Bool, title: String, elapsedLabel: String) -> Decision {
        guard isRecording else { return .terminateNow }
        return .confirmBeforeTerminating(title: title, elapsedLabel: elapsedLabel)
    }
}

/// Posts exactly one "‹meeting› is ready" notification per meeting, the first
/// time it observes the meeting's status land on `.ready` (transcript done,
/// and enhancement either done or skipped/unavailable — both end at
/// `.ready`). Clicking the notification activates the app and opens the
/// meeting, via the same `AppStores.showMeeting(_:)` path
/// `FloatingIndicatorController.activate()` uses.
///
/// Authorization is requested lazily, on the first completion this process
/// observes — never at launch — and a denial degrades silently (no retry
/// nagging, no crash).
@MainActor
public final class CompletionNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// Meeting IDs already notified this run. In-memory only — a fresh
    /// launch's crash-recovery requeue finishing counts as a new completion,
    /// which is fine (the meeting genuinely just became ready again from the
    /// user's perspective after being stuck).
    private var notifiedMeetingIDs: Set<UUID> = []
    private var didRequestAuthorization = false

    /// Routes a notification click back to the app. Mirrors
    /// `FloatingIndicatorController.activate()`: bring the app forward, then
    /// navigate to the meeting.
    private let onOpenMeeting: @MainActor (UUID) -> Void
    /// Whether the app is currently frontmost AND this exact meeting is the
    /// one on screen — when true, the notification is suppressed (the user
    /// is already looking at it landing).
    private let isMeetingCurrentlyVisible: @MainActor (UUID) -> Bool

    private var pendingMeetingIDs: [String: UUID] = [:]

    public init(
        onOpenMeeting: @escaping @MainActor (UUID) -> Void,
        isMeetingCurrentlyVisible: @escaping @MainActor (UUID) -> Bool
    ) {
        self.onOpenMeeting = onOpenMeeting
        self.isMeetingCurrentlyVisible = isMeetingCurrentlyVisible
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Call from the status-reporting path whenever a meeting's status
    /// changes. Only fires on the transition into `.ready`, and only once per
    /// meeting ID per process lifetime.
    public func meetingStatusChanged(
        meetingID: UUID, title: String, duration: TimeInterval, hasEnhancedNotes: Bool, to status: MeetingStatus
    ) {
        guard status == .ready else { return }
        guard !notifiedMeetingIDs.contains(meetingID) else { return }
        notifiedMeetingIDs.insert(meetingID)

        if isMeetingCurrentlyVisible(meetingID) {
            // The user is already looking at this meeting land — a banner
            // would be redundant noise.
            return
        }

        Task {
            let center = UNUserNotificationCenter.current()
            if !didRequestAuthorization {
                didRequestAuthorization = true
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                notifierLog.info("Notifications not authorized; skipping completion notification")
                return
            }

            let identifier = UUID().uuidString
            pendingMeetingIDs[identifier] = meetingID
            let content = UNMutableNotificationContent()
            content.title = "\(title) is ready"
            content.body = CompletionNotifier.body(duration: duration, hasEnhancedNotes: hasEnhancedNotes)
            content.sound = .default
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            try? await center.add(request)
        }
    }

    /// Pure so it's directly testable: "Transcribed and enhanced · 15m" vs
    /// "Transcribed · 15m" depending on whether enhancement produced notes.
    static func body(duration: TimeInterval, hasEnhancedNotes: Bool) -> String {
        let label = Self.durationLabel(seconds: duration)
        let verb = hasEnhancedNotes ? "Transcribed and enhanced" : "Transcribed"
        return label.isEmpty ? verb : "\(verb) · \(label)"
    }

    /// "15m" / "1h 5m" — narrow-unit duration for the notification body.
    static func durationLabel(seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "" }
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let identifier = response.notification.request.identifier
        await MainActor.run {
            guard let meetingID = pendingMeetingIDs.removeValue(forKey: identifier) else { return }
            onOpenMeeting(meetingID)
        }
    }

    /// Show banners even while Recap is frontmost (a different meeting may be
    /// open, or the user backgrounded then foregrounded — still worth
    /// surfacing).
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
