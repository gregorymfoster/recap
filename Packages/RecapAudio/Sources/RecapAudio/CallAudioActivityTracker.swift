import Foundation

/// Pure debounce logic over per-poll "is this bundle id currently producing
/// audio" snapshots. No CoreAudio, no timers — just consecutive-poll
/// counting, so it's exhaustively unit-testable.
///
/// An id becomes "started" only after `startAfterPolls` CONSECUTIVE polls in
/// which it was active — one ding shouldn't nudge a session open. Once
/// started, it becomes "stopped" only after `stopAfterPolls` CONSECUTIVE
/// polls in which it was inactive — a muted moment mid-call must not end the
/// session. An id that never started emits nothing while inactive.
public struct CallAudioActivityTracker: Sendable {
    private struct State {
        var isStarted = false
        var consecutiveActive = 0
        var consecutiveInactive = 0
    }

    public let startAfterPolls: Int
    public let stopAfterPolls: Int

    private var states: [String: State] = [:]

    public init(startAfterPolls: Int = 2, stopAfterPolls: Int = 40) {
        self.startAfterPolls = startAfterPolls
        self.stopAfterPolls = stopAfterPolls
    }

    /// Feeds one poll's worth of active bundle ids and returns any events
    /// that just crossed a threshold, in deterministic (bundle-id sorted)
    /// order.
    public mutating func ingest(activeIDs: Set<String>) -> [CallAudioEvent] {
        var events: [CallAudioEvent] = []

        // Ids we've never seen before but are active now need a State entry.
        for id in activeIDs where states[id] == nil {
            states[id] = State()
        }

        for id in states.keys.sorted() {
            var state = states[id]!
            let isActive = activeIDs.contains(id)

            if isActive {
                state.consecutiveInactive = 0
                if state.isStarted {
                    // Already in a session; nothing to emit on continued activity.
                    state.consecutiveActive += 1
                } else {
                    state.consecutiveActive += 1
                    if state.consecutiveActive >= startAfterPolls {
                        state.isStarted = true
                        events.append(.appStartedAudio(bundleID: id))
                    }
                }
            } else {
                state.consecutiveActive = 0
                if state.isStarted {
                    state.consecutiveInactive += 1
                    if state.consecutiveInactive >= stopAfterPolls {
                        state.isStarted = false
                        state.consecutiveInactive = 0
                        events.append(.appStoppedAudio(bundleID: id))
                    }
                } else {
                    // Never started; inactivity is a no-op. Drop bookkeeping
                    // for ids that are no longer active and never started,
                    // to avoid unbounded growth from transient bundle ids.
                    state.consecutiveInactive = 0
                }
            }

            states[id] = state
        }

        // Prune ids that are neither started nor currently active — they
        // have no state worth retaining.
        states = states.filter { _, state in state.isStarted || state.consecutiveActive > 0 }

        return events
    }
}
