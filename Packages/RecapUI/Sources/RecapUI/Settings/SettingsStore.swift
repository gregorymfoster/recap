import Foundation
import Observation
import RecapCore
import RecapTranscription

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

    public var calendarAutoRecord: CalendarAutoRecordMode {
        didSet { defaults.set(calendarAutoRecord.rawValue, forKey: "calendarAutoRecord") }
    }

    /// Canonical `CallApp.id`s the user has muted for call detection
    /// ("Don't ask for Teams", or a toggle off in Settings → Calendar).
    /// Stored as the *disabled* set so apps added to the catalog later
    /// default to on.
    public var disabledCallAppIDs: Set<String> {
        didSet { defaults.set(Array(disabledCallAppIDs).sorted(), forKey: "disabledCallAppIDs") }
    }

    /// Mirror finished meeting folders (incl. audio) into another folder —
    /// typically iCloud Drive, for a one-way backup outside the app.
    public var mirrorBackupEnabled: Bool {
        didSet { defaults.set(mirrorBackupEnabled, forKey: "mirrorBackup") }
    }

    public var mirrorFolderPath: String {
        didSet { defaults.set(mirrorFolderPath, forKey: "mirrorFolderPath") }
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

    /// Automatic-model-selection quality preference (replaces the old
    /// manual Models screen). Absent key → `.bestQuality` for everyone,
    /// regardless of whatever model happened to be active before.
    public var transcriptionQuality: TranscriptionQuality {
        didSet { defaults.set(transcriptionQuality.rawValue, forKey: "transcriptionQuality") }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasOnboarded = defaults.bool(forKey: "hasOnboarded")
        includeSystemAudio = defaults.object(forKey: "includeSystemAudio") as? Bool ?? true
        calendarAutoRecord = defaults.string(forKey: "calendarAutoRecord")
            .flatMap(CalendarAutoRecordMode.init(rawValue:)) ?? .off
        disabledCallAppIDs = Set(defaults.stringArray(forKey: "disabledCallAppIDs") ?? [])
        mirrorBackupEnabled = defaults.bool(forKey: "mirrorBackup")
        mirrorFolderPath = defaults.string(forKey: "mirrorFolderPath") ?? ""
        saveRootPath = defaults.string(forKey: "saveRootPath") ?? LibraryStorage.defaultRootURL.path
        lastSystemAudioTapFailed = defaults.object(forKey: "lastSystemAudioTapFailed") as? Bool
        preferredInputUID = defaults.string(forKey: "preferredInputUID")
        transcriptionQuality = defaults.string(forKey: "transcriptionQuality")
            .flatMap(TranscriptionQuality.init(rawValue:)) ?? .bestQuality

        // Scrub legacy keys: pause-on-battery, speaker labeling, Obsidian
        // sync, the webhook, the transcription-language override, and the
        // floating-capsule style picker are all unconditional/removed
        // behavior now — a stale value here must never resurface if any of
        // these settings ever get reintroduced under the same key.
        defaults.removeObject(forKey: "pauseOnBattery")
        defaults.removeObject(forKey: "labelSpeakers")
        defaults.removeObject(forKey: "obsidianSync")
        defaults.removeObject(forKey: "obsidianVaultPath")
        defaults.removeObject(forKey: "webhookURL")
        defaults.removeObject(forKey: "transcriptionLanguage")
        defaults.removeObject(forKey: "floatingCapsuleStyle")
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
