import SwiftUI

/// Accessibility identifiers for `App/` — the app root, first-run sheet, and
/// the Library-back-navigation toolbar item. See `Shared/AccessibilityIdentifiers.swift`
/// for the naming convention.
extension AXID {
    // MARK: Root

    /// The `RootView`'s top-level, push-style-navigated content container.
    public static let rootView = AXID("root-view")

    /// "‹ Library" back button shown in the meeting detail toolbar.
    public static let libraryBackButton = AXID("library-back-button")

    // MARK: First run

    /// The first-run flow's root container.
    public static let firstRunView = AXID("first-run-view")

    /// First-run's "Allow" action on the Microphone row.
    public static let firstRunAllowMic = AXID("first-run-allow-mic")

    /// First-run's "Open System Settings…" fix-it on the Microphone row,
    /// shown instead of a dead "Allow" once access was previously denied.
    public static let firstRunOpenSystemSettingsMic = AXID("first-run-open-system-settings-mic")

    /// First-run's "Allow" action on the Other participants (system audio) row.
    public static let firstRunAllowSystemAudio = AXID("first-run-allow-system-audio")

    /// First-run's "Open System Settings…" fix-it on the Other participants
    /// (system audio) row, shown alongside the retry button once a tap
    /// attempt failed and macOS access was denied.
    public static let firstRunOpenSystemSettingsSystemAudio = AXID("first-run-open-system-settings-system-audio")

    /// First-run's "Setting up transcription" card.
    public static let firstRunModelCard = AXID("first-run-model-card")

    /// First-run's final "Start using Recap" action.
    public static let firstRunStartButton = AXID("first-run-start-button")
}
