import Foundation
import Observation
import RecapCore

/// User preferences, backed by UserDefaults.
@MainActor
@Observable
public final class SettingsStore {
    public var hasOnboarded: Bool {
        didSet { defaults.set(hasOnboarded, forKey: "hasOnboarded") }
    }

    /// Capture other participants via the system-audio tap.
    public var includeSystemAudio: Bool {
        didSet { defaults.set(includeSystemAudio, forKey: "includeSystemAudio") }
    }

    public var pausesOnBattery: Bool {
        didSet { defaults.set(pausesOnBattery, forKey: "pauseOnBattery") }
    }

    /// Meeting library location. Applies to meetings created after a change.
    public var saveRootPath: String {
        didSet { defaults.set(saveRootPath, forKey: "saveRootPath") }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasOnboarded = defaults.bool(forKey: "hasOnboarded")
        includeSystemAudio = defaults.object(forKey: "includeSystemAudio") as? Bool ?? true
        pausesOnBattery = defaults.object(forKey: "pauseOnBattery") as? Bool ?? true
        saveRootPath = defaults.string(forKey: "saveRootPath") ?? LibraryStorage.defaultRootURL.path
    }

    public var saveRootURL: URL {
        URL(fileURLWithPath: saveRootPath)
    }

    /// Isolated store for previews and `-fixtures` runs — never touches the
    /// app's real defaults (so it can't suppress first-run onboarding).
    static func ephemeralOnboarded() -> SettingsStore {
        let suite = UserDefaults(suiteName: "recap.ephemeral.fixtures") ?? .standard
        suite.removePersistentDomain(forName: "recap.ephemeral.fixtures")
        let store = SettingsStore(defaults: suite)
        store.hasOnboarded = true
        return store
    }
}
