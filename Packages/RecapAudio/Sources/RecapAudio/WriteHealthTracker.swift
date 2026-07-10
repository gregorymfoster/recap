import Foundation

/// Tracks the health of `MixerEngine`'s background write path independently
/// of thrown errors: a block dropped by the bounded internal write queue
/// (the consumer couldn't keep up), or an individual write that took
/// abnormally long (the disk is alive but crawling — a thrown-error counter
/// alone would never notice this, since a slow-but-succeeding write never
/// throws). A handful of strikes in a row means the disk is genuinely stuck,
/// not a transient hiccup; a single timely write resets the count, mirroring
/// how the existing thrown-error threshold treats an isolated failure as
/// noise.
///
/// Pure and deterministic — instants are injected rather than read from a
/// live clock, so tests never need to actually sleep.
struct WriteHealthTracker: Sendable, Equatable {
    /// Consecutive strikes before `isUnhealthy` flips true.
    static let strikeThreshold = 3
    /// A single write taking longer than this counts as one strike.
    static let slowWriteThreshold: Duration = .seconds(3)

    private(set) var consecutiveStrikes = 0
    private var writeStartedAt: ContinuousClock.Instant?

    var isUnhealthy: Bool { consecutiveStrikes >= Self.strikeThreshold }

    /// A block was dropped by the bounded internal write queue because the
    /// write task couldn't keep up — counts as one strike.
    mutating func recordDropped() {
        consecutiveStrikes += 1
    }

    /// Call immediately before a write begins.
    mutating func recordWriteStarted(at instant: ContinuousClock.Instant) {
        writeStartedAt = instant
    }

    /// Call immediately after a write finishes (whether it threw or not —
    /// this tracks wall-clock slowness, not success). A no-op if there was
    /// no matching `recordWriteStarted` (shouldn't happen in practice, but
    /// fails safe rather than crashing or mis-attributing a duration).
    mutating func recordWriteCompleted(at instant: ContinuousClock.Instant) {
        defer { writeStartedAt = nil }
        guard let writeStartedAt else { return }
        if instant - writeStartedAt > Self.slowWriteThreshold {
            consecutiveStrikes += 1
        } else {
            consecutiveStrikes = 0
        }
    }
}

/// Thread-safe wrapper around `WriteHealthTracker` plus the one-shot latch
/// that decides whether `MixerEngine` has already reported `.writeFailed` for
/// this recording. Shared between `MixerEngine`'s actor-isolated `emit()`
/// (which observes dropped blocks at the write-queue yield call site) and its
/// detached background write task (which observes write duration and thrown
/// errors) — neither side is willing to `await` a hop to the other just to
/// update a strike count, so this is a plain locked class rather than an
/// actor.
final class WriteFailureLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var tracker = WriteHealthTracker()
    private var reported = false

    /// Returns true exactly once — the moment a dropped block first pushes
    /// the tracker into `isUnhealthy`.
    func recordDropped() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        tracker.recordDropped()
        return latchIfUnhealthyLocked()
    }

    func recordWriteStarted(at instant: ContinuousClock.Instant) {
        lock.lock()
        defer { lock.unlock() }
        tracker.recordWriteStarted(at: instant)
    }

    /// Returns true exactly once — the moment a slow write first pushes the
    /// tracker into `isUnhealthy`.
    func recordWriteCompleted(at instant: ContinuousClock.Instant) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        tracker.recordWriteCompleted(at: instant)
        return latchIfUnhealthyLocked()
    }

    /// Called when the pre-existing thrown-error threshold (file + spool
    /// writers both failing `MixerEngine.failureThreshold` times in a row)
    /// trips. Shares the same one-shot latch as the health-tracker path
    /// above, so a disk that's both throwing errors and running slow only
    /// ever reports `.writeFailed` once.
    func recordThrownErrorThresholdTripped() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !reported else { return false }
        reported = true
        return true
    }

    private func latchIfUnhealthyLocked() -> Bool {
        guard tracker.isUnhealthy, !reported else { return false }
        reported = true
        return true
    }
}
