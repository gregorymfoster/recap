import Foundation
import Testing
@testable import RecapUI

/// `disabledCallAppIDs` round-trips (settings for the "Detect calls from"
/// section, design mock 9b). Kept separate from `SettingsStoreTests` since
/// it's `Set<String>`-valued rather than Bool/String/enum.
@MainActor
@Suite struct SettingsStoreDetectionTests {
    static func ephemeralSuite() -> UserDefaults {
        let suite = UserDefaults(suiteName: "recap.tests.settingsstore.detection")!
        suite.removePersistentDomain(forName: "recap.tests.settingsstore.detection")
        return suite
    }

    @Test func disabledCallAppIDsDefaultsToEmpty() {
        let store = SettingsStore(defaults: Self.ephemeralSuite())
        #expect(store.disabledCallAppIDs.isEmpty)
    }

    @Test func disabledCallAppIDsRoundTripsThroughUserDefaults() {
        let defaults = Self.ephemeralSuite()
        let store = SettingsStore(defaults: defaults)
        store.disabledCallAppIDs = ["us.zoom.xos", "com.apple.FaceTime"]

        let reopened = SettingsStore(defaults: defaults)
        #expect(reopened.disabledCallAppIDs == ["us.zoom.xos", "com.apple.FaceTime"])
    }

    @Test func removalPersists() {
        let defaults = Self.ephemeralSuite()
        let store = SettingsStore(defaults: defaults)
        store.disabledCallAppIDs = ["us.zoom.xos", "com.apple.FaceTime"]
        store.disabledCallAppIDs.remove("us.zoom.xos")

        #expect(store.disabledCallAppIDs == ["com.apple.FaceTime"])
        let reopened = SettingsStore(defaults: defaults)
        #expect(reopened.disabledCallAppIDs == ["com.apple.FaceTime"])
    }
}
