import Foundation
import Testing
@testable import RecapCore

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
}
