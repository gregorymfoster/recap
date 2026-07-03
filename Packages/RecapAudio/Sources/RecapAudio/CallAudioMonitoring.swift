import Foundation

/// A watched call app started or stopped producing audio. "Started" is
/// debounced (sustained activity, not a single notification ding);
/// "stopped" fires only after a couple of minutes of silence so one muted
/// moment mid-call doesn't end the session.
public enum CallAudioEvent: Equatable, Sendable {
    case appStartedAudio(bundleID: String)
    case appStoppedAudio(bundleID: String)
}

/// Seam over per-process audio-activity monitoring (design mock 9b). The
/// real implementation reads CoreAudio's process-object list — activity
/// *metadata* only, never audio content, so no capture permission is
/// involved. Tests and fixtures inject fakes.
@MainActor
public protocol CallAudioMonitoring: AnyObject {
    var isMonitoring: Bool { get }
    /// Begins watching the given bundle ids, replacing any previous set.
    func start(bundleIDs: Set<String>, onEvent: @escaping @MainActor (CallAudioEvent) -> Void)
    func stop()
}
