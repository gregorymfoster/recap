import Foundation

/// Sample-count-based, symmetric two-sided liveness watchdog.
///
/// `MixerEngine` feeds it the running mic/system sample totals on every push
/// from either side. It detects when one side stops making progress while
/// the *other* side keeps flowing — the only way to notice a silently dead
/// capture source, since `MixBuffer` itself just pads the stalled side with
/// silence past its own much shorter starvation threshold.
///
/// Deliberately sample-count-based, not wall-clock, so it's deterministic
/// and testable without real timers — mirrors the original one-sided
/// `MixerEngine.checkSystemAudioLiveness` this replaces.
///
/// Both directions are retryable and resumable, with identical semantics:
/// each side's recovery is a bounded-attempt rebuild driven by the caller
/// (`MicCapturing.forceRebuild()` / `SystemAudioCapturing.rebuild()`), so a
/// stalled side can fire `.stalled` more than once — once per
/// `stallThreshold` worth of continued silence — and reports `.resumed` the
/// moment its samples start advancing again, so the caller knows when to
/// reset its attempt counter.
struct LivenessWatchdog {
    enum Side: Sendable, Equatable {
        case mic
        case system
    }

    enum Event: Sendable, Equatable {
        /// The side stopped advancing while the other side kept flowing for
        /// more than `stallThreshold` worth of samples.
        case stalled(Side)
        /// A previously-stalled side started advancing again.
        case resumed(Side)
    }

    /// ~4 s of the other side's progress at 48 kHz before declaring a stall
    /// (as opposed to merely lagging — `MixBuffer.starvationThreshold`
    /// already tolerates ~2 s of lag before flushing the live side alone).
    static let stallThreshold = 192_000

    // System-stall direction: is system audio keeping up with the mic?
    private var systemTotalAtLastSystemProgress = 0
    private var micTotalAtLastSystemProgress = 0
    private var systemStalledSinceResume = false

    // Mic-stall direction: is the mic keeping up with system audio?
    private var micTotalAtLastMicProgress = 0
    private var systemTotalAtLastMicProgress = 0
    private var micStalledSinceResume = false

    /// Call on every mic or system push with the buffer's current running
    /// totals for both sides. `systemExpected`/`micExpected` say whether that
    /// side is part of this recording at all — a side that was never started
    /// (mic denied, or system audio off) has nothing to stall against, and
    /// checking it anyway would spuriously fire against a total that's
    /// pinned at 0 forever.
    ///
    /// The mic-stall direction additionally requires `systemExpected`: it's
    /// system audio's continued progress that gives the watchdog a heartbeat
    /// to measure the mic's silence against. A mic-only recording (system
    /// audio off) has no independent heartbeat calling into the mixer at
    /// all if the mic itself goes dead — nothing pushes, so nothing can
    /// react. That's an inherent limit of a push-driven, sample-count-based
    /// design, not something this method can special-case around.
    mutating func recordProgress(
        micTotal: Int, systemTotal: Int, systemExpected: Bool, micExpected: Bool
    ) -> Event? {
        var event: Event?

        if systemExpected {
            if systemTotal > systemTotalAtLastSystemProgress {
                systemTotalAtLastSystemProgress = systemTotal
                micTotalAtLastSystemProgress = micTotal
                if systemStalledSinceResume {
                    systemStalledSinceResume = false
                    event = .resumed(.system)
                }
            } else {
                let micSinceProgress = micTotal - micTotalAtLastSystemProgress
                if micSinceProgress > Self.stallThreshold {
                    systemStalledSinceResume = true
                    // Bump the baseline so the next fire needs another full
                    // threshold of continued silence, rather than firing on
                    // every subsequent push — mirrors the mic direction.
                    micTotalAtLastSystemProgress = micTotal
                    event = .stalled(.system)
                }
            }
        }

        if micExpected, systemExpected {
            if micTotal > micTotalAtLastMicProgress {
                micTotalAtLastMicProgress = micTotal
                systemTotalAtLastMicProgress = systemTotal
                if micStalledSinceResume {
                    micStalledSinceResume = false
                    event = event ?? .resumed(.mic)
                }
            } else {
                let systemSinceProgress = systemTotal - systemTotalAtLastMicProgress
                if systemSinceProgress > Self.stallThreshold {
                    micStalledSinceResume = true
                    // Bump the baseline so the next fire needs another full
                    // threshold of continued silence, rather than firing on
                    // every subsequent push.
                    systemTotalAtLastMicProgress = systemTotal
                    event = event ?? .stalled(.mic)
                }
            }
        }

        return event
    }
}
