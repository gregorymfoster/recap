import Testing
@testable import RecapCore

@Suite struct AppIdentityTests {
    @Test func nilBundleIdentifierIsNotDev() {
        #expect(AppIdentity.isDev(bundleIdentifier: nil) == false)
    }

    @Test func prodBundleIdentifierIsNotDev() {
        #expect(AppIdentity.isDev(bundleIdentifier: "com.gregfoster.recap") == false)
    }

    @Test func devBundleIdentifierIsDev() {
        #expect(AppIdentity.isDev(bundleIdentifier: "com.gregfoster.recap.dev") == true)
    }
}
