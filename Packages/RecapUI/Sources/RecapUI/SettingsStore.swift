import Foundation
import Observation
import RecapCore

/// What Recap does when a meeting-shaped calendar event starts.
public enum CalendarAutoRecordMode: String, CaseIterable, Sendable {
    case off
    case prompt
    case auto
}

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

    /// Label who spoke in transcripts (on-device diarization).
    public var labelsSpeakers: Bool {
        didSet { defaults.set(labelsSpeakers, forKey: "labelSpeakers") }
    }

    public var calendarAutoRecord: CalendarAutoRecordMode {
        didSet { defaults.set(calendarAutoRecord.rawValue, forKey: "calendarAutoRecord") }
    }

    /// Mirror finished meetings into an Obsidian vault folder as Markdown.
    public var syncsToObsidian: Bool {
        didSet { defaults.set(syncsToObsidian, forKey: "obsidianSync") }
    }

    public var obsidianVaultPath: String {
        didSet { defaults.set(obsidianVaultPath, forKey: "obsidianVaultPath") }
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
        labelsSpeakers = defaults.object(forKey: "labelSpeakers") as? Bool ?? true
        calendarAutoRecord = defaults.string(forKey: "calendarAutoRecord")
            .flatMap(CalendarAutoRecordMode.init(rawValue:)) ?? .off
        syncsToObsidian = defaults.bool(forKey: "obsidianSync")
        obsidianVaultPath = defaults.string(forKey: "obsidianVaultPath") ?? ""
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
