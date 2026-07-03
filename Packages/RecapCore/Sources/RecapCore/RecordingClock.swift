import Foundation

/// Wall-clock bookkeeping for a pausable recording: total active (unpaused)
/// time is `accumulated` plus however long the current running stretch has
/// been going. Pure — every operation takes an explicit date, so tests never
/// sleep. The audio pipeline gates samples separately; this struct only
/// answers "how much active time has elapsed?" for the timer UI and the
/// final meeting duration.
public struct RecordingClock: Equatable, Sendable {
    /// Active seconds from completed running stretches (before any pause).
    public private(set) var accumulated: TimeInterval
    /// Start of the current running stretch, or nil while paused.
    public private(set) var runningSince: Date?

    public init(startedAt: Date = .now) {
        accumulated = 0
        runningSince = startedAt
    }

    public var isPaused: Bool { runningSince == nil }

    /// Freezes the clock. Idempotent — pausing while paused does nothing.
    public mutating func pause(at date: Date = .now) {
        guard let runningSince else { return }
        accumulated += date.timeIntervalSince(runningSince)
        self.runningSince = nil
    }

    /// Restarts the clock. Idempotent — resuming while running does nothing.
    public mutating func resume(at date: Date = .now) {
        guard runningSince == nil else { return }
        runningSince = date
    }

    /// Total active (unpaused) time as of `date`.
    public func elapsed(at date: Date = .now) -> TimeInterval {
        accumulated + (runningSince.map { date.timeIntervalSince($0) } ?? 0)
    }

    /// The date a never-paused recording would have started at to show the
    /// same elapsed time — invariant: `date - syntheticStartDate(at: date)
    /// == elapsed(at: date)`. Lets a ticking `TimelineView`/`Text(style:
    /// .timer)` render the running state cheaply; while paused, render a
    /// static string instead (a ticking timer cannot freeze).
    public func syntheticStartDate(at date: Date = .now) -> Date {
        date.addingTimeInterval(-elapsed(at: date))
    }
}
