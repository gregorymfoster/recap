import Foundation

/// Tick-driven companion to `LivenessWatchdog` for single-source (mic-only)
/// recordings, where the missing side leaves no pushes to measure silence
/// against.
///
/// `LivenessWatchdog`'s mic-stall direction requires `systemExpected` — it's
/// system audio's continued progress that gives it a heartbeat to measure the
/// mic's silence against (see its doc comment). A mic-only recording has no
/// such heartbeat: if the mic tap itself goes dead, nothing pushes into the
/// mixer at all, so nothing sample-count-based can ever notice. This struct
/// fills that gap with a wall-clock tick instead of a sample push — the
/// caller is expected to call `tick(micTotal:)` on a fixed interval (the
/// production tick is ~1s) regardless of whether any audio arrived.
///
/// Mirrors `LivenessWatchdog`'s re-arm/resume semantics: after `stallTicks`
/// consecutive ticks with no mic progress, `.stalled(.mic)` fires and the
/// counter resets so the next fire needs another full silent window, not one
/// tick later. Progress resets the counter and, if it comes after a fire,
/// reports `.resumed(.mic)`.
struct HeartbeatWatchdog {
    /// ~5 s at the 1 s production tick — matches `LivenessWatchdog.stallThreshold`'s
    /// ~4 s window.
    static let stallTicks = 5

    private var micTotalAtLastProgress = 0
    private var silentTicks = 0
    private var stalledSinceResume = false

    /// Call once per tick with the buffer's current running mic sample total,
    /// regardless of whether the tick observed any real progress.
    mutating func tick(micTotal: Int) -> LivenessWatchdog.Event? {
        if micTotal > micTotalAtLastProgress {
            micTotalAtLastProgress = micTotal
            silentTicks = 0
            if stalledSinceResume {
                stalledSinceResume = false
                return .resumed(.mic)
            }
            return nil
        }

        silentTicks += 1
        guard silentTicks >= Self.stallTicks else { return nil }
        stalledSinceResume = true
        // Bump the baseline so the next fire needs another full window of
        // continued silence, rather than firing on every subsequent tick —
        // mirrors `LivenessWatchdog`'s baseline-bump behavior.
        silentTicks = 0
        return .stalled(.mic)
    }
}
