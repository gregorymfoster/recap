import RecapUI
import Sparkle

/// Owns Sparkle's updater and bridges "update found" background checks to the
/// in-app surfaces (`UpdateStatus`) and, when the app isn't in focus, a
/// clickable macOS notification (`UpdateNotifier`).
///
/// Uses Sparkle's gentle scheduled reminders, layered by attention:
/// - App in immediate focus when the scheduled check fires → Sparkle's
///   standard dialog shows right away.
/// - Otherwise → we post a notification (tap → activate + present the dialog)
///   and light the menu-bar indicator / Library banner via `UpdateStatus`.
/// - User-initiated checks always show Sparkle's dialog directly.
@MainActor
final class UpdaterModel: NSObject, SPUStandardUserDriverDelegate {
    private let status: UpdateStatus
    private let notifier: UpdateNotifier?
    private var controller: SPUStandardUpdaterController!

    init(status: UpdateStatus, notifier: UpdateNotifier?) {
        self.status = status
        self.notifier = notifier
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
        status.install = { [weak self] in
            // A user-initiated check re-presents the pending update in Sparkle's
            // standard dialog (release notes + Install).
            self?.controller.checkForUpdates(nil)
        }
    }

    /// The Sparkle updater, for the existing "Check for Updates…" menu command.
    var updater: SPUUpdater { controller.updater }

    // MARK: SPUStandardUserDriverDelegate
    //
    // Sparkle invokes these on the main thread but the ObjC protocol isn't
    // actor-annotated, so they're `nonisolated` and hop to the main actor to
    // touch `status`/`notifier`.

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // In immediate focus (frontmost or just launched), Sparkle's dialog is
        // the right surface; otherwise we take over with a notification.
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        let version = update.displayVersionString
        MainActor.assumeIsolated {
            let actions = UpdateReminderDecision.decide(
                sparkleWillShowDialog: handleShowingUpdate, userInitiated: state.userInitiated)
            if actions.markAvailable { status.markAvailable(version: version) }
            if actions.postNotification { notifier?.postUpdateAvailable(version: version) }
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        // The update has been seen (dialog focused / notification tapped) —
        // a lingering notification would be stale noise.
        MainActor.assumeIsolated { notifier?.removeDelivered() }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        // Deliberately does NOT clear `status.isAvailable`: the update stays
        // available (and the indicator lit) until the relaunch installs it.
        MainActor.assumeIsolated { notifier?.removeDelivered() }
    }
}
