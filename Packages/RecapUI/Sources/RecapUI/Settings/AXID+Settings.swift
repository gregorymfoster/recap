import Foundation

/// Accessibility identifiers for the Settings window: the page root and the
/// key interactive controls in each of its grouped-form sections (Audio,
/// Transcription, Storage, Launch at Login — see `SettingsWindowView`, the
/// one-page redesign that replaced the old five-tab window). See
/// `AccessibilityIdentifiers.swift` for the naming convention and the
/// `axID(_:)` modifier.
extension AXID {
    /// The Settings window's root container (`SettingsWindowView`).
    public static let settingsPage = AXID("settings-page")

    // MARK: - Audio group

    public static let settingsInputDevicePicker = AXID("settings-recording-input-device-picker")
    public static let settingsSystemAudioToggle = AXID("settings-recording-system-audio-toggle")
    public static let settingsMicrophonePermissionButton = AXID("settings-privacy-microphone-permission-button")

    // MARK: - Calendar group

    /// The auto-record mode picker (Off / Ask before recording / Record automatically).
    public static let settingsCalendarModePicker = AXID("settings-calendar-mode-picker")

    /// "Open System Settings…" shown when calendar auto-record is on but
    /// macOS calendar access was denied.
    public static let settingsCalendarPermissionButton = AXID("settings-privacy-calendar-permission-button")

    // MARK: - Transcription group

    /// The transcription-quality picker (best quality / faster).
    public static let settingsQualityPicker = AXID("settings-quality-picker")

    /// The row shown while a quality-switch model download is in progress
    /// (also used for the `.failed` retry row — same slot, different content).
    public static let settingsDownloadingRow = AXID("settings-downloading-row")

    // MARK: - Storage group

    public static let settingsMeetingsFolderChangeButton = AXID("settings-privacy-meetings-folder-change-button")

    /// The mirror-backup enable/disable toggle.
    public static let settingsBackupToggle = AXID("settings-backup-toggle")

    /// The backup-status summary row (ok/working/stuck).
    public static let settingsBackupStatusRow = AXID("settings-backup-status-row")

    // MARK: - Launch at Login

    public static let settingsLaunchAtLoginToggle = AXID("settings-general-launch-at-login-toggle")
}
