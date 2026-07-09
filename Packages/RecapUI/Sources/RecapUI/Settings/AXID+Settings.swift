import Foundation

/// Accessibility identifiers for the Settings window: the window root, each
/// tab, and the key interactive controls per tab. See `AccessibilityIdentifiers.swift`
/// for the naming convention and the `axID(_:)` modifier.
extension AXID {
    // MARK: - Window & tabs

    /// The Settings window's root `TabView` (`SettingsWindowView`).
    public static let settingsWindow = AXID("settings-window")
    public static let settingsTabGeneral = AXID("settings-tab-general")
    public static let settingsTabRecording = AXID("settings-tab-recording")
    public static let settingsTabCalendar = AXID("settings-tab-calendar")
    public static let settingsTabSync = AXID("settings-tab-sync")
    public static let settingsTabPrivacy = AXID("settings-tab-privacy")

    // MARK: - General tab

    public static let settingsLaunchAtLoginToggle = AXID("settings-general-launch-at-login-toggle")

    // MARK: - Recording tab

    public static let settingsInputDevicePicker = AXID("settings-recording-input-device-picker")
    public static let settingsSystemAudioToggle = AXID("settings-recording-system-audio-toggle")

    // MARK: - Calendar tab

    public static let settingsCalendarAutoRecordPicker = AXID("settings-calendar-auto-record-picker")
    /// A single "detect calls from" app toggle, keyed by the app's own
    /// stable id (`CallApp.id`) rather than its display name.
    public static func settingsCallAppToggle(_ appID: String) -> AXID { AXID("settings-calendar-call-app-toggle-\(appID)") }

    // MARK: - Sync tab

    public static let settingsMirrorBackupToggle = AXID("settings-sync-mirror-backup-toggle")
    public static let settingsMirrorFolderChangeButton = AXID("settings-sync-mirror-folder-change-button")

    // MARK: - Privacy tab

    public static let settingsMicrophonePermissionButton = AXID("settings-privacy-microphone-permission-button")
    public static let settingsSystemAudioPermissionButton = AXID("settings-privacy-system-audio-permission-button")
    public static let settingsSystemAudioProbeButton = AXID("settings-privacy-system-audio-probe-button")
    public static let settingsCalendarPermissionButton = AXID("settings-privacy-calendar-permission-button")
    public static let settingsMeetingsFolderChangeButton = AXID("settings-privacy-meetings-folder-change-button")

    // MARK: - Models

    /// The Models section root (`ModelManagerView`).
    public static let settingsModelsList = AXID("settings-models-list")
    /// A single model row's primary action (Download/Pause/Use), keyed by
    /// the model's own stable id rather than its display name.
    public static func settingsModelDownloadButton(_ modelID: String) -> AXID { AXID("settings-models-download-button-\(modelID)") }
    public static func settingsModelUseButton(_ modelID: String) -> AXID { AXID("settings-models-use-button-\(modelID)") }
    public static func settingsModelDeleteButton(_ modelID: String) -> AXID { AXID("settings-models-delete-button-\(modelID)") }
    public static func settingsModelPauseButton(_ modelID: String) -> AXID { AXID("settings-models-pause-button-\(modelID)") }

    // MARK: - Redesign (Phase 0 scaffolding)

    /// The redesigned Settings surface's root container.
    public static let settingsPage = AXID("settings-page")

    /// The transcription-quality picker (best quality / faster).
    public static let settingsQualityPicker = AXID("settings-quality-picker")

    /// The row shown while a quality-switch model download is in progress.
    public static let settingsDownloadingRow = AXID("settings-downloading-row")

    /// The mirror-backup enable/disable toggle on the redesigned surface.
    public static let settingsBackupToggle = AXID("settings-backup-toggle")

    /// The backup-status summary row on the redesigned surface.
    public static let settingsBackupStatusRow = AXID("settings-backup-status-row")
}
