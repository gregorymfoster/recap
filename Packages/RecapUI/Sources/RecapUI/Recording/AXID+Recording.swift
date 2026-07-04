import Foundation

/// Accessibility identifiers for the Recording feature: the docked recording
/// pill, the floating background capsule, and the system-audio permission
/// probe button. See `AccessibilityIdentifiers.swift` for conventions.
extension AXID {
    /// The docked recording pill container (`RecordingPill`).
    public static let recordingPill = AXID("recording-pill")

    /// The pill's pause/resume round button (`RecordingPill`).
    public static let recordingPauseButton = AXID("recording-pause-button")

    /// The pill's white Stop control (`RecordingPill`).
    public static let recordingStopButton = AXID("recording-stop-button")

    /// The background floating recording capsule (`FloatingIndicatorView`),
    /// shown while recording and Recap is backgrounded.
    public static let floatingIndicator = AXID("floating-indicator")

    /// The system-audio permission "Test" probe button, shared by Settings
    /// Permissions and Onboarding (`SystemAudioProbeButton`).
    public static let systemAudioProbeButton = AXID("system-audio-probe-button")
}
