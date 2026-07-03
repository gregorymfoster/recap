import RecapUI
import Sparkle

/// Owns Sparkle's updater and bridges "update found" background checks to the
/// in-app indicator (`UpdateStatus`).
///
/// Uses Sparkle's gentle scheduled reminders so a background check lights up our
/// own indicator instead of interrupting with a modal. The modal appears only
/// when the user clicks the indicator, which runs a user-initiated check that
/// re-presents the already-found update in Sparkle's standard dialog.
@MainActor
final class UpdaterModel: NSObject, SPUStandardUserDriverDelegate {
    private let status: UpdateStatus
    private var controller: SPUStandardUpdaterController!

    init(status: UpdateStatus) {
        self.status = status
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
    // touch `status`.

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // We surface scheduled updates through our own indicator, so tell the
        // standard driver not to auto-present them.
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        // Light up the indicator only for background checks; user-initiated
        // checks already show Sparkle's dialog (handleShowingUpdate == true).
        guard !state.userInitiated else { return }
        MainActor.assumeIsolated { status.markAvailable() }
    }
}
