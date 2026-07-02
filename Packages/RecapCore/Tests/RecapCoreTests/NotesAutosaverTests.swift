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
}
