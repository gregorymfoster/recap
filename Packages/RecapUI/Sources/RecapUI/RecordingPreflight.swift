import RecapAudio

/// Pure decision logic for what to do before a recording starts.
///
/// Mic permission is awaited up front, but the system-audio tap permission
/// can only be discovered by starting a tap — if that happened mid-recording
/// (the old flow), the macOS prompt fired after capture began and a start
/// with zero audio access still created a junk errored meeting record. This
/// type gates recording so both problems are decided *before* any meeting
/// record exists.
public enum RecordingPreflight {
    public enum Outcome: Equatable, Sendable {
        /// Start recording with exactly these sources.
        case proceed(includeMic: Bool, includeSystemAudio: Bool)
        /// No usable audio source — do not start, do not create a record.
        case blocked
    }

    /// Probe only when system audio is enabled and not known-good: `nil`
    /// (never attempted) or `true` (failed last time). A probe both triggers
    /// the TCC prompt pre-recording and verifies recovery.
    static func needsProbe(includeSystemAudio: Bool, lastTapFailed: Bool?) -> Bool {
        guard includeSystemAudio else { return false }
        return lastTapFailed != false
    }

    /// - Parameter probeResult: `nil` when the probe was skipped because
    ///   system audio is known-good (or disabled — then `systemAudioEnabled`
    ///   is `false`).
    public static func decide(
        micGranted: Bool, systemAudioEnabled: Bool, probeResult: SystemAudioProbeResult?
    ) -> Outcome {
        let systemAudioUsable: Bool
        if !systemAudioEnabled {
            systemAudioUsable = false
        } else if let probeResult {
            systemAudioUsable = probeResult == .captured
        } else {
            // Probe skipped because system audio was already known-good.
            systemAudioUsable = true
        }

        guard micGranted || systemAudioUsable else { return .blocked }
        return .proceed(includeMic: micGranted, includeSystemAudio: systemAudioUsable)
    }
}
