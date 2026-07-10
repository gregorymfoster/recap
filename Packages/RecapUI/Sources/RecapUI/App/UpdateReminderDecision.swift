/// Pure decision logic for the layered update-available UX: when a
/// background ("scheduled") update check finds a newer version, should we
/// flip `UpdateStatus.isAvailable` (driving the Library banner + menu bar
/// install row), and should we also post a system notification?
///
/// Framework-free by design (mirrors `QuitGuard` in `CompletionNotifier.swift`)
/// so the app target's Sparkle delegate can call `decide(...)` and act on the
/// result without any of this being testable only through Sparkle itself.
public enum UpdateReminderDecision {
    /// What the caller should do in response to a check finding an update.
    public struct Actions: Equatable, Sendable {
        /// Whether to call `UpdateStatus.markAvailable(version:)`.
        public let markAvailable: Bool
        /// Whether to post a system notification via `UpdateNotifier`.
        public let postNotification: Bool

        public init(markAvailable: Bool, postNotification: Bool) {
            self.markAvailable = markAvailable
            self.postNotification = postNotification
        }
    }

    /// - Parameters:
    ///   - sparkleWillShowDialog: True when Sparkle is about to present its
    ///     own "A new version is available" dialog for this check.
    ///   - userInitiated: True when the user explicitly triggered this check
    ///     (e.g. "Check for Updates…"), as opposed to a background/scheduled
    ///     check running on its own timer.
    public static func decide(sparkleWillShowDialog: Bool, userInitiated: Bool) -> Actions {
        // Sparkle's own dialog is already up for a user-initiated check —
        // our layered UX (banner + notification) would be redundant noise
        // on top of a modal the user just asked for.
        guard !userInitiated else {
            return Actions(markAvailable: false, postNotification: false)
        }
        // Scheduled check: always surface the in-app banner/indicator. Only
        // also post a system notification when Sparkle's dialog is being
        // suppressed (e.g. the user is mid-recording) — otherwise Sparkle's
        // own dialog is enough of a nudge.
        return Actions(markAvailable: true, postNotification: !sparkleWillShowDialog)
    }
}
