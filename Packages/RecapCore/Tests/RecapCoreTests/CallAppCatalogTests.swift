import Foundation
import Testing
@testable import RecapCore

@Suite struct CallAppCatalogTests {
    @Test func appForBundleIDResolvesAliasToCanonicalID() {
        // Classic Teams bundle id resolves to the new-Teams canonical entry.
        let app = CallAppCatalog.app(forBundleID: "com.microsoft.teams")
        #expect(app?.id == "com.microsoft.teams2")
        #expect(app?.name == "Microsoft Teams")
    }

    @Test func appForBundleIDResolvesCanonicalID() {
        let app = CallAppCatalog.app(forBundleID: "com.microsoft.teams2")
        #expect(app?.id == "com.microsoft.teams2")
    }

    @Test func appForUnknownBundleIDReturnsNil() {
        #expect(CallAppCatalog.app(forBundleID: "com.example.not-a-call-app") == nil)
    }

    @Test func enabledBundleIDsExcludesAllAliasesOfADisabledApp() {
        let enabled = CallAppCatalog.enabledBundleIDs(disabledAppIDs: ["com.microsoft.teams2"])

        #expect(!enabled.contains("com.microsoft.teams2"))
        #expect(!enabled.contains("com.microsoft.teams"))
    }

    @Test func enabledBundleIDsIncludesOthers() {
        let enabled = CallAppCatalog.enabledBundleIDs(disabledAppIDs: ["com.microsoft.teams2"])

        #expect(enabled.contains("us.zoom.xos"))
        #expect(enabled.contains("Cisco-Systems.Spark"))
        #expect(enabled.contains("com.tinyspeck.slackmacgap"))
        #expect(enabled.contains("com.apple.FaceTime"))
        #expect(enabled.contains("com.hammerandchisel.discord"))
    }

    @Test func enabledBundleIDsIncludesEverythingWhenNothingDisabled() {
        let enabled = CallAppCatalog.enabledBundleIDs(disabledAppIDs: [])
        let allBundleIDs = Set(CallAppCatalog.apps.flatMap(\.bundleIDs))

        #expect(enabled == allBundleIDs)
    }
}
