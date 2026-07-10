import Foundation

/// Debounced writer for the notes file: keystrokes call `noteDidChange`,
/// the latest content hits disk after `interval` of quiet (or immediately
/// via `flush()`, e.g. on stop/blur/quit).
public actor NotesAutosaver {
    private let storage: LibraryStorage
    private let interval: Duration
    private let retryBackoff: Duration
    /// Caps the self-scheduled retries below so a persistently broken disk
    /// (e.g. volume unmounted) doesn't spin forever in the background.
    private static let maxRetryAttempts = 5

    private var pending: (record: MeetingRecord, notes: String)?
    private var flushTask: Task<Void, Never>?
    private var retryAttempt = 0

    public init(storage: LibraryStorage, interval: Duration = .seconds(1), retryBackoff: Duration = .seconds(2)) {
        self.storage = storage
        self.interval = interval
        self.retryBackoff = retryBackoff
    }

    public func noteDidChange(_ notes: String, in record: MeetingRecord) {
        pending = (record, notes)
        retryAttempt = 0
        flushTask?.cancel()
        flushTask = Task { [interval] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            self.flush()
        }
    }

    /// Writes any pending content immediately.
    @discardableResult
    public func flush() -> Bool {
        flushTask?.cancel()
        flushTask = nil
        guard let (record, notes) = pending else { return false }
        do {
            try storage.saveNotes(notes, in: record)
            pending = nil
            retryAttempt = 0
            return true
        } catch {
            // Keep the content so the next change or flush retries the write —
            // and self-schedule a retry too, since a failed terminal flush
            // (blur/quit) may never get another `noteDidChange` to trigger one.
            scheduleRetry()
            return false
        }
    }

    private func scheduleRetry() {
        guard retryAttempt < Self.maxRetryAttempts else { return }
        retryAttempt += 1
        flushTask = Task { [retryBackoff] in
            try? await Task.sleep(for: retryBackoff)
            guard !Task.isCancelled else { return }
            self.flush()
        }
    }
}
