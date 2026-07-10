import Foundation
import os

/// A change to the on-disk library worth telling other subsystems about.
public enum LibraryChange: Sendable {
    case meetingChanged(UUID)
    /// Not posted anywhere yet — there's no delete affordance until
    /// Milestone C. Defined now so consumers can handle it from day one.
    case meetingDeleted(UUID)
}

/// Fans out library changes to any number of independent subscribers.
///
/// `LibraryStore` posts here after every persisted change; consumers —
/// today's folder-mirror backup task, tomorrow's CloudKit sync engine —
/// each get their own `AsyncStream` and see every change, not just
/// the first subscriber. This is the single hook every mirror/sync consumer
/// should subscribe to instead of only hooking processing completion, which
/// misses later notes edits.
public final class LibraryChangeBus: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<[UUID: AsyncStream<LibraryChange>.Continuation]>(initialState: [:])

    public init() {}

    /// Delivers `change` to every currently-live subscriber.
    public func post(_ change: LibraryChange) {
        lock.withLock { continuations in
            for continuation in continuations.values {
                continuation.yield(change)
            }
        }
    }

    /// Registers a new independent subscriber. The stream ends (and is
    /// unregistered) if the caller cancels it or drops it.
    public func changes() -> AsyncStream<LibraryChange> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.withLock { continuations in
                continuations[id] = continuation
            }
            continuation.onTermination = { [lock] _ in
                lock.withLock { continuations in
                    _ = continuations.removeValue(forKey: id)
                }
            }
        }
    }
}
