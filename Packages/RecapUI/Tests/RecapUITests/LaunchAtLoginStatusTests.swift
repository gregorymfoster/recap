import Testing
@testable import RecapUI

@Suite struct LaunchAtLoginStatusTests {
    @Test func enabledIsOnWithNoFootnote() {
        #expect(LaunchAtLoginStatus.enabled.isOn == true)
        #expect(LaunchAtLoginStatus.enabled.footnote == nil)
    }

    @Test func disabledIsOffWithNoFootnote() {
        #expect(LaunchAtLoginStatus.disabled.isOn == false)
        #expect(LaunchAtLoginStatus.disabled.footnote == nil)
    }

    @Test func requiresApprovalIsOnAndExplainsWhy() {
        #expect(LaunchAtLoginStatus.requiresApproval.isOn == true)
        #expect(LaunchAtLoginStatus.requiresApproval.footnote != nil)
        #expect(LaunchAtLoginStatus.requiresApproval.footnote?.contains("Login Items") == true)
    }

    @Test func notFoundIsOffAndExplainsWhy() {
        #expect(LaunchAtLoginStatus.notFound.isOn == false)
        #expect(LaunchAtLoginStatus.notFound.footnote != nil)
    }
}
