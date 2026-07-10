import Foundation
import Testing
@testable import RecapCore
@testable import RecapUI

/// Covers `LibraryStore.flushNotes` writing through a pending (debounced,
/// unflushed) `notesChanged` edit — the fix for the notes-loss bug where a
/// note typed within the autosaver's 1s debounce window was lost on app
/// quit, main-window close, or a screen swap that skipped the library back
/// button (the only call site before this fix).
@MainActor
@Suite(.serialized) struct LibraryStoreFlushNotesTests {
    private func makeStorage() -> LibraryStorage {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryStoreFlushNotesTests-\(UUID().uuidString)")
        return LibraryStorage(rootURL: root)
    }

    @Test func flushNotesPersistsAPendingDebouncedEdit() async throws {
        let storage = makeStorage()
        let changeBus = LibraryChangeBus()
        let library = LibraryStore(storage: storage, index: try! SearchIndex(), changeBus: changeBus)
        let record = try storage.create(Meeting(title: "Notes flush", date: .now, status: .ready))
        library.reload()
        let loaded = library.record(for: record.meeting.id)!

        // A keystroke within the 1s autosave debounce — nothing has hit disk
        // yet at this point.
        library.notesChanged("typed but not yet debounce-flushed", in: loaded)
        #expect(try storage.loadNotes(in: loaded) == "")

        library.flushNotes(for: loaded)

        // `flushNotes` fires an internal unstructured `Task`, so poll rather
        // than assume synchronous completion.
        let deadline = ContinuousClock.now + .seconds(2)
        while (try? storage.loadNotes(in: loaded)) != "typed but not yet debounce-flushed", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try storage.loadNotes(in: loaded) == "typed but not yet debounce-flushed")
    }
}
