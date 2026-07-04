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

    // MARK: - Bool property round-trips
    //
    // Key paths into a @MainActor type can't cross into @Sendable test
    // arguments under strict concurrency, so `arguments:` carries only plain
    // (nonisolated) property names; the get/set dispatch happens via `switch`
    // inside the @MainActor test body.

    private nonisolated static let boolPropertyNames = [
        "hasOnboarded", "includeSystemAudio", "pausesOnBattery",
        "labelsSpeakers", "syncsToObsidian", "mirrorBackupEnabled",
    ]

    private func boolAccessors(for name: String) -> (get: (SettingsStore) -> Bool, set: (SettingsStore, Bool) -> Void, defaultValue: Bool) {
        switch name {
        case "hasOnboarded": ({ $0.hasOnboarded }, { $0.hasOnboarded = $1 }, false)
        case "includeSystemAudio": ({ $0.includeSystemAudio }, { $0.includeSystemAudio = $1 }, true)
        case "pausesOnBattery": ({ $0.pausesOnBattery }, { $0.pausesOnBattery = $1 }, true)
        case "labelsSpeakers": ({ $0.labelsSpeakers }, { $0.labelsSpeakers = $1 }, true)
        case "syncsToObsidian": ({ $0.syncsToObsidian }, { $0.syncsToObsidian = $1 }, false)
        case "mirrorBackupEnabled": ({ $0.mirrorBackupEnabled }, { $0.mirrorBackupEnabled = $1 }, false)
        default: fatalError("unknown bool property \(name)")
        }
    }

    @Test(arguments: boolPropertyNames)
    func boolPropertyDefaultsThenRoundTrips(name: String) {
        let (get, set, defaultValue) = boolAccessors(for: name)
        let defaults = Self.ephemeralSuite()
        let store = SettingsStore(defaults: defaults)
        #expect(get(store) == defaultValue, "\(name) default")

        set(store, !defaultValue)
        let reopened = SettingsStore(defaults: defaults)
        #expect(get(reopened) == !defaultValue, "\(name) round-trip after flip")

        set(store, defaultValue)
        let reopenedAgain = SettingsStore(defaults: defaults)
        #expect(get(reopenedAgain) == defaultValue, "\(name) round-trip back to default")
    }

    // MARK: - String property round-trips

    private nonisolated static let stringPropertyNames = [
        "obsidianVaultPath", "mirrorFolderPath", "webhookURL", "saveRootPath",
    ]

    private func stringAccessors(for name: String) -> (get: (SettingsStore) -> String, set: (SettingsStore, String) -> Void, value: String) {
        switch name {
        case "obsidianVaultPath": ({ $0.obsidianVaultPath }, { $0.obsidianVaultPath = $1 }, "/tmp/vault")
        case "mirrorFolderPath": ({ $0.mirrorFolderPath }, { $0.mirrorFolderPath = $1 }, "/tmp/mirror")
        case "webhookURL": ({ $0.webhookURL }, { $0.webhookURL = $1 }, "https://example.com/hook")
        case "saveRootPath": ({ $0.saveRootPath }, { $0.saveRootPath = $1 }, "/tmp/recap-root")
        default: fatalError("unknown string property \(name)")
        }
    }

    @Test(arguments: stringPropertyNames)
    func stringPropertyRoundTripsThroughUserDefaults(name: String) {
        let (get, set, value) = stringAccessors(for: name)
        let defaults = Self.ephemeralSuite()
        let store = SettingsStore(defaults: defaults)
        set(store, value)

        let reopened = SettingsStore(defaults: defaults)
        #expect(get(reopened) == value, "\(name) round-trip")
    }

    // MARK: - calendarAutoRecord

    @Test(arguments: CalendarAutoRecordMode.allCases)
    func calendarAutoRecordRoundTripsThroughUserDefaults(mode: CalendarAutoRecordMode) {
        let defaults = Self.ephemeralSuite()
        let store = SettingsStore(defaults: defaults)
        store.calendarAutoRecord = mode

        let reopened = SettingsStore(defaults: defaults)
        #expect(reopened.calendarAutoRecord == mode)
    }

    @Test func calendarAutoRecordDefaultsToOff() {
        let store = SettingsStore(defaults: Self.ephemeralSuite())
        #expect(store.calendarAutoRecord == .off)
    }

    // MARK: - preferredInputUID nil-removal

    @Test func preferredInputUIDDefaultsToNil() {
        let store = SettingsStore(defaults: Self.ephemeralSuite())
        #expect(store.preferredInputUID == nil)
    }

    @Test func preferredInputUIDRoundTripsThenNilRemovesStoredValue() {
        let defaults = Self.ephemeralSuite()
        let store = SettingsStore(defaults: defaults)
        store.preferredInputUID = "device-uid-123"

        let reopened = SettingsStore(defaults: defaults)
        #expect(reopened.preferredInputUID == "device-uid-123")

        store.preferredInputUID = nil
        #expect(defaults.string(forKey: "preferredInputUID") == nil)
        let reopenedAgain = SettingsStore(defaults: defaults)
        #expect(reopenedAgain.preferredInputUID == nil)
    }

    // MARK: - lastSystemAudioTapFailed nil-removal (tri-state: nil/false/true)

    @Test func lastSystemAudioTapFailedDefaultsToNil() {
        let store = SettingsStore(defaults: Self.ephemeralSuite())
        #expect(store.lastSystemAudioTapFailed == nil)
    }

    @Test(arguments: [true, false])
    func lastSystemAudioTapFailedRoundTripsThenNilRemovesStoredValue(value: Bool) {
        let defaults = Self.ephemeralSuite()
        let store = SettingsStore(defaults: defaults)
        store.lastSystemAudioTapFailed = value

        let reopened = SettingsStore(defaults: defaults)
        #expect(reopened.lastSystemAudioTapFailed == value)

        store.lastSystemAudioTapFailed = nil
        #expect(defaults.object(forKey: "lastSystemAudioTapFailed") == nil)
        let reopenedAgain = SettingsStore(defaults: defaults)
        #expect(reopenedAgain.lastSystemAudioTapFailed == nil)
    }

    // MARK: - ephemeralOnboarded isolation

    @Test func ephemeralOnboardedIsAlwaysOnboardedAndIsolatedFromStandardDefaults() {
        // .standard is untouched: onboarding a real user shouldn't leak from
        // the ephemeral suite, and vice versa.
        let ephemeral = SettingsStore.ephemeralOnboarded()
        #expect(ephemeral.hasOnboarded == true)

        // Calling it again starts from a clean slate every time (the suite is
        // wiped on each call), regardless of what a previous call mutated.
        ephemeral.syncsToObsidian = true
        ephemeral.obsidianVaultPath = "/should/not/persist"

        let fresh = SettingsStore.ephemeralOnboarded()
        #expect(fresh.hasOnboarded == true)
        #expect(fresh.syncsToObsidian == false)
        #expect(fresh.obsidianVaultPath == "")
    }
}
