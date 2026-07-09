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

    // MARK: - Legacy key scrubbing

    /// Removed settings (pause-on-battery, speaker labeling — now
    /// unconditional behavior; Obsidian sync, the webhook, the transcription
    /// language override, and the floating-capsule style — now removed
    /// features) must never resurface from a stale value under their old key.
    @Test func initScrubsLegacyKeysFromDefaults() {
        let defaults = Self.ephemeralSuite()
        defaults.set(false, forKey: "pauseOnBattery")
        defaults.set(false, forKey: "labelSpeakers")
        defaults.set(true, forKey: "obsidianSync")
        defaults.set("/tmp/vault", forKey: "obsidianVaultPath")
        defaults.set("https://example.com/hook", forKey: "webhookURL")
        defaults.set("es", forKey: "transcriptionLanguage")
        defaults.set("full", forKey: "floatingCapsuleStyle")

        _ = SettingsStore(defaults: defaults)

        #expect(defaults.object(forKey: "pauseOnBattery") == nil)
        #expect(defaults.object(forKey: "labelSpeakers") == nil)
        #expect(defaults.object(forKey: "obsidianSync") == nil)
        #expect(defaults.object(forKey: "obsidianVaultPath") == nil)
        #expect(defaults.object(forKey: "webhookURL") == nil)
        #expect(defaults.object(forKey: "transcriptionLanguage") == nil)
        #expect(defaults.object(forKey: "floatingCapsuleStyle") == nil)
    }

    // MARK: - Bool property round-trips
    //
    // Key paths into a @MainActor type can't cross into @Sendable test
    // arguments under strict concurrency, so `arguments:` carries only plain
    // (nonisolated) property names; the get/set dispatch happens via `switch`
    // inside the @MainActor test body.

    private nonisolated static let boolPropertyNames = [
        "hasOnboarded", "includeSystemAudio", "mirrorBackupEnabled",
    ]

    private func boolAccessors(for name: String) -> (get: (SettingsStore) -> Bool, set: (SettingsStore, Bool) -> Void, defaultValue: Bool) {
        switch name {
        case "hasOnboarded": ({ $0.hasOnboarded }, { $0.hasOnboarded = $1 }, false)
        case "includeSystemAudio": ({ $0.includeSystemAudio }, { $0.includeSystemAudio = $1 }, true)
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
        "mirrorFolderPath", "saveRootPath",
    ]

    private func stringAccessors(for name: String) -> (get: (SettingsStore) -> String, set: (SettingsStore, String) -> Void, value: String) {
        switch name {
        case "mirrorFolderPath": ({ $0.mirrorFolderPath }, { $0.mirrorFolderPath = $1 }, "/tmp/mirror")
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
        ephemeral.mirrorBackupEnabled = true
        ephemeral.mirrorFolderPath = "/should/not/persist"

        let fresh = SettingsStore.ephemeralOnboarded()
        #expect(fresh.hasOnboarded == true)
        #expect(fresh.mirrorBackupEnabled == false)
        #expect(fresh.mirrorFolderPath == "")
    }
}
