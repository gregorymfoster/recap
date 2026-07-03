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

    /// Mirror finished meeting folders (incl. audio) into another folder —
    /// typically iCloud Drive, for a one-way backup outside the app.
    public var mirrorBackupEnabled: Bool {
        didSet { defaults.set(mirrorBackupEnabled, forKey: "mirrorBackup") }
    }

    public var mirrorFolderPath: String {
        didSet { defaults.set(mirrorFolderPath, forKey: "mirrorFolderPath") }
    }

    /// POST finished meetings (JSON) to this URL; empty disables.
    public var webhookURL: String {
        didSet { defaults.set(webhookURL, forKey: "webhookURL") }
    }

    /// Meeting library location. Applies to meetings created after a change.
    public var saveRootPath: String {
        didSet { defaults.set(saveRootPath, forKey: "saveRootPath") }
    }

    /// Outcome of the system-audio tap the last time a recording started.
    /// There's no permission-query API for the tap, so this is the best
    /// signal Settings can show: nil means it's never been attempted.
    public var lastSystemAudioTapFailed: Bool? {
        didSet {
            if let lastSystemAudioTapFailed {
                defaults.set(lastSystemAudioTapFailed, forKey: "lastSystemAudioTapFailed")
            } else {
                defaults.removeObject(forKey: "lastSystemAudioTapFailed")
            }
        }
    }

    /// Preferred microphone, by Core Audio persistent UID. `nil` means
    /// "system default" — today's behavior.
    public var preferredInputUID: String? {
        didSet {
            if let preferredInputUID {
                defaults.set(preferredInputUID, forKey: "preferredInputUID")
            } else {
                defaults.removeObject(forKey: "preferredInputUID")
            }
        }
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
        mirrorBackupEnabled = defaults.bool(forKey: "mirrorBackup")
        mirrorFolderPath = defaults.string(forKey: "mirrorFolderPath") ?? ""
        webhookURL = defaults.string(forKey: "webhookURL") ?? ""
        saveRootPath = defaults.string(forKey: "saveRootPath") ?? LibraryStorage.defaultRootURL.path
        lastSystemAudioTapFailed = defaults.object(forKey: "lastSystemAudioTapFailed") as? Bool
        preferredInputUID = defaults.string(forKey: "preferredInputUID")
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
