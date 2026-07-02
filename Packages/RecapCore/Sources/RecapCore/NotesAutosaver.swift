import Foundation

/// Debounced writer for the notes file: keystrokes call `noteDidChange`,
/// the latest content hits disk after `interval` of quiet (or immediately
/// via `flush()`, e.g. on stop/blur/quit).
public actor NotesAutosaver {
    private let storage: LibraryStorage
    private let interval: Duration
    private var pending: (record: MeetingRecord, notes: String)?
    private var flushTask: Task<Void, Never>?

    public init(storage: LibraryStorage, interval: Duration = .seconds(1)) {
        self.storage = storage
        self.interval = interval
    }

    public func noteDidChange(_ notes: String, in record: MeetingRecord) {
        pending = (record, notes)
        flushTask?.cancel()
        flushTask = Task { [interval] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            await self.flush()
        }
    }

    /// Writes any pending content immediately.
    @discardableResult
    public func flush() -> Bool {
        flushTask?.cancel()
        flushTask = nil
        guard let (record, notes) = pending else { return false }
        pending = nil
        do {
            try storage.saveNotes(notes, in: record)
            return true
        } catch {
            // Keep the content so the next change or flush retries the write.
            pending = (record, notes)
            return false
        }
    }
}
