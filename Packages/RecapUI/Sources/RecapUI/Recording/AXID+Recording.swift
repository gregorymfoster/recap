import Foundation

/// Accessibility identifiers for the Recording feature: the full-window
/// recording view, the session capsule, the floating background capsule, and
/// the system-audio permission probe button. See `AccessibilityIdentifiers.swift`
/// for conventions.
extension AXID {
    /// The background floating recording capsule (`FloatingIndicatorView`),
    /// shown while recording and Recap is backgrounded.
    public static let floatingIndicator = AXID("floating-indicator")

    /// The system-audio permission "Test" probe button, shared by Settings
    /// Permissions and Onboarding (`SystemAudioProbeButton`).
    public static let systemAudioProbeButton = AXID("system-audio-probe-button")

    /// The full-window recording view (redesigned recording surface).
    public static let recordingView = AXID("recording-view")

    /// The recording view's title field (`EditableTitle`).
    public static let recordingTitleField = AXID("recording-title-field")

    /// The recording view's live notes field.
    public static let recordingNotesField = AXID("recording-notes-field")

    /// The redesigned session capsule container.
    public static let sessionCapsule = AXID("session-capsule")

    /// The session capsule's pause/resume control.
    public static let capsulePauseButton = AXID("capsule-pause-button")

    /// The session capsule's Stop control.
    public static let capsuleStopButton = AXID("capsule-stop-button")

    /// The session capsule's input-device menu (`InputDeviceMenu`).
    public static let capsuleDeviceMenu = AXID("capsule-device-menu")

    /// The floating background capsule's pause/resume control.
    public static let floatingPauseButton = AXID("floating-pause-button")

    /// The floating background capsule's Stop control.
    public static let floatingStopButton = AXID("floating-stop-button")
}
