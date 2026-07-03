import Foundation
import Testing
@testable import RecapUI

@MainActor
@Suite struct SettingsStoreTests {
    static func ephemeralSuite() -> UserDefaults {
        let suite = UserDefaults(suiteName: "recap.tests.settingsstore")!
        suite.removePersistentDomain(forName: "recap.tests.settingsstore")
        return suite
    }

    @Test func transcriptionLanguageDefaultsToAutoDetect() {
        let store = SettingsStore(defaults: Self.ephemeralSuite())
        #expect(store.transcriptionLanguage == nil)
    }

    @Test func transcriptionLanguageRoundTripsThroughUserDefaults() {
        let defaults = Self.ephemeralSuite()
        let store = SettingsStore(defaults: defaults)
        store.transcriptionLanguage = "es"

        let reopened = SettingsStore(defaults: defaults)
        #expect(reopened.transcriptionLanguage == "es")
    }

    @Test func settingBackToNilRemovesTheStoredValue() {
        let defaults = Self.ephemeralSuite()
        let store = SettingsStore(defaults: defaults)
        store.transcriptionLanguage = "fr"
        store.transcriptionLanguage = nil

        #expect(defaults.string(forKey: "transcriptionLanguage") == nil)
        let reopened = SettingsStore(defaults: defaults)
        #expect(reopened.transcriptionLanguage == nil)
    }
}
