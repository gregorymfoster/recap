import Testing
@testable import RecapUI

@Suite struct UpdateStatusTests {
    @MainActor @Test func startsUnavailable() {
        #expect(UpdateStatus().isAvailable == false)
    }

    @MainActor @Test func markAvailableFlipsAndSticks() {
        let status = UpdateStatus()
        status.markAvailable()
        #expect(status.isAvailable)
        status.markAvailable()
        #expect(status.isAvailable)
    }

    @MainActor @Test func markAvailableCapturesVersion() {
        let status = UpdateStatus()
        status.markAvailable(version: "1.4.0")
        #expect(status.availableVersion == "1.4.0")
    }

    @MainActor @Test func markAvailableWithNilVersionDoesNotClobberExisting() {
        let status = UpdateStatus()
        status.markAvailable(version: "1.4.0")
        status.markAvailable(version: nil)
        #expect(status.availableVersion == "1.4.0")
    }

    @MainActor @Test func showsBannerTruthTable() {
        let status = UpdateStatus()
        #expect(status.showsBanner == false) // not available, not dismissed

        status.markAvailable()
        #expect(status.showsBanner) // available, not dismissed

        status.dismissBanner()
        #expect(status.showsBanner == false) // available, dismissed
    }

    @MainActor @Test func dismissBannerLeavesIsAvailableTrue() {
        let status = UpdateStatus()
        status.markAvailable()
        status.dismissBanner()
        #expect(status.isAvailable)
        #expect(status.isBannerDismissed)
    }

    @MainActor @Test func markAvailableWithNewVersionResetsDismissal() {
        let status = UpdateStatus()
        status.markAvailable(version: "1.4.0")
        status.dismissBanner()
        #expect(status.showsBanner == false)

        status.markAvailable(version: "1.5.0")
        #expect(status.isBannerDismissed == false)
        #expect(status.showsBanner)
    }

    @MainActor @Test func markAvailableWithSameVersionLeavesDismissalAlone() {
        let status = UpdateStatus()
        status.markAvailable(version: "1.4.0")
        status.dismissBanner()
        #expect(status.showsBanner == false)

        status.markAvailable(version: "1.4.0")
        #expect(status.isBannerDismissed)
        #expect(status.showsBanner == false)
    }

    @MainActor @Test func triggerInstallCallsInstallHook() {
        let status = UpdateStatus()
        var presented = 0
        status.install = { presented += 1 }
        status.triggerInstall()
        #expect(presented == 1)
    }

    @MainActor @Test func triggerInstallWithoutHookIsSafe() {
        UpdateStatus().triggerInstall()
    }

    /// Sparkle owns availability once the dialog is shown — installing must
    /// not clear the flag from our side.
    @MainActor @Test func triggerInstallLeavesAvailabilityUntouched() {
        let status = UpdateStatus()
        status.install = {}
        status.markAvailable()
        status.triggerInstall()
        #expect(status.isAvailable)
    }
}
