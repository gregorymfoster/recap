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
