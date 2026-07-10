import Foundation
import Testing
@testable import RecapCore

/// Thread-safe counter for `onExhausted` invocations — the closure is
/// `@Sendable` and called from actor context, so a plain `var` would race.
private final class ExhaustedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@Suite struct NotesAutosaverTests {
    @Test func debouncesRapidChangesAndWritesLatest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecapTests-\(UUID().uuidString)")
        let storage = LibraryStorage(rootURL: root)
        let record = try storage.create(Meeting(title: "Notes", date: .now))
        let autosaver = NotesAutosaver(storage: storage, interval: .milliseconds(50))

        await autosaver.noteDidChange("d", in: record)
        await autosaver.noteDidChange("dr", in: record)
        await autosaver.noteDidChange("draft", in: record)
        // Nothing on disk before the debounce interval elapses.
        #expect(try storage.loadNotes(in: record) == "")

        try await Task.sleep(for: .milliseconds(200))
        #expect(try storage.loadNotes(in: record) == "draft")
    }

    @Test func flushWritesImmediately() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecapTests-\(UUID().uuidString)")
        let storage = LibraryStorage(rootURL: root)
        let record = try storage.create(Meeting(title: "Notes", date: .now))
        let autosaver = NotesAutosaver(storage: storage, interval: .seconds(60))

        await autosaver.noteDidChange("must not be lost", in: record)
        let wrote = await autosaver.flush()
        #expect(wrote)
        #expect(try storage.loadNotes(in: record) == "must not be lost")

        // Nothing pending → flush is a no-op.
        let wroteAgain = await autosaver.flush()
        #expect(!wroteAgain)
    }

    /// Fix: a failed terminal flush (e.g. blur/quit) used to leave `pending`
    /// set with nothing left to trigger a retry, silently losing the notes.
    /// Removing the meeting folder makes the write throw (no parent
    /// directory); recreating it before the self-scheduled retry fires lets
    /// the retry succeed, so the notes must land on disk without any further
    /// `noteDidChange` call.
    @Test func failedFlushSchedulesRetryAndEventuallySaves() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecapTests-\(UUID().uuidString)")
        let storage = LibraryStorage(rootURL: root)
        let record = try storage.create(Meeting(title: "Notes", date: .now))
        let autosaver = NotesAutosaver(storage: storage, interval: .seconds(60), retryBackoff: .milliseconds(50))

        try FileManager.default.removeItem(at: record.folderURL)

        await autosaver.noteDidChange("must survive a failed flush", in: record)
        let wrote = await autosaver.flush()
        #expect(!wrote)

        // Recreate the folder before the self-scheduled retry fires.
        try FileManager.default.createDirectory(at: record.folderURL, withIntermediateDirectories: true)

        try await Task.sleep(for: .milliseconds(300))
        #expect(try storage.loadNotes(in: record) == "must survive a failed flush")
    }

    /// Fix: a persistently broken disk (volume unmounted, folder deleted and
    /// never recreated) used to exhaust the retry budget in total silence.
    /// `onExhausted` must fire exactly once — not once per subsequent failed
    /// write — once every retry is spent.
    @Test func exhaustingRetryBudgetFiresOnExhaustedExactlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecapTests-\(UUID().uuidString)")
        let storage = LibraryStorage(rootURL: root)
        let record = try storage.create(Meeting(title: "Notes", date: .now))
        // Never recreated — every write (initial flush + every retry) fails.
        try FileManager.default.removeItem(at: record.folderURL)

        let counter = ExhaustedCounter()
        let autosaver = NotesAutosaver(storage: storage, interval: .seconds(60), retryBackoff: .milliseconds(20))
        await autosaver.setOnExhausted { counter.increment() }

        await autosaver.noteDidChange("will never be saved", in: record)
        let wrote = await autosaver.flush()
        #expect(!wrote)

        // 5 retries at a 20ms backoff, plus margin, is enough for the budget
        // to fully exhaust.
        try await Task.sleep(for: .milliseconds(600))
        #expect(counter.count == 1)

        // A little longer still — no further firing once exhausted.
        try await Task.sleep(for: .milliseconds(200))
        #expect(counter.count == 1)
    }
}
