import Foundation
import Testing
@testable import RecapCore
@testable import RecapUI

/// Covers `LibraryStore.reload()`'s launch-time behavior: synchronous
/// meeting load, background search-index convergence (2a — "kill the
/// launch freeze"), and the root-unreachable banner state (2c).
@MainActor
@Suite(.serialized) struct LibraryStoreReloadTests {
    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeStorage() -> LibraryStorage {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryStoreReloadTests-\(UUID().uuidString)")
        return LibraryStorage(rootURL: root)
    }

    // MARK: 2a — synchronous load, background index rebuild

    @Test func reloadPopulatesMeetingsSynchronouslyAndIndexConvergesAfterward() async throws {
        let storage = makeStorage()
        let a = try storage.create(Meeting(title: "Alpha", date: .now))
        let b = try storage.create(Meeting(title: "Beta", date: .now))
        let index = try SearchIndex()

        let store = LibraryStore(storage: storage, index: index, changeBus: LibraryChangeBus())

        // Meetings are populated synchronously by init/reload — no polling.
        #expect(Set(store.meetings.map(\.meeting.id)) == Set([a.meeting.id, b.meeting.id]))

        // The index rebuild is backgrounded; poll briefly for it to converge.
        await waitUntil { (try? index.indexedMeetingCount()) == 2 }
        #expect(try index.indexedMeetingCount() == 2)
    }

    @Test func reloadSkipsIndexRebuildWhenCountsAlreadyMatch() async throws {
        let storage = makeStorage()
        let record = try storage.create(Meeting(title: "Solo", date: .now))
        try storage.saveNotes("original content", in: record)
        let index = try SearchIndex()
        try index.reindex(records: [record], storage: storage)
        #expect(try await index.search("original").count == 1)

        // Edit notes.md directly on disk, bypassing the index. If reload()
        // skips the rebuild (1 folder == 1 indexed row already), the stale
        // "original" text stays searchable and "edited" never becomes so.
        try Data("edited externally".utf8).write(to: record.notesURL)

        _ = LibraryStore(storage: storage, index: index, changeBus: LibraryChangeBus())
        try await Task.sleep(for: .milliseconds(300))

        #expect(try await index.search("original").count == 1)
        #expect(try await index.search("edited").isEmpty)
    }

    @Test func reloadRepairsIndexWhenPreSeededWithFewerRowsThanFolders() async throws {
        let storage = makeStorage()
        let a = try storage.create(Meeting(title: "Alpha", date: .now))
        _ = try storage.create(Meeting(title: "Beta", date: .now))
        _ = try storage.create(Meeting(title: "Gamma", date: .now))
        let index = try SearchIndex()
        // Pre-seed the index with only one of the three folders — a stale
        // index from before "Beta"/"Gamma" existed.
        try index.reindex(records: [a], storage: storage)
        #expect(try index.indexedMeetingCount() == 1)

        let store = LibraryStore(storage: storage, index: index, changeBus: LibraryChangeBus())
        // Meetings populate synchronously regardless of the index state.
        #expect(store.meetings.count == 3)

        await waitUntil { (try? index.indexedMeetingCount()) == 3 }
        #expect(try index.indexedMeetingCount() == 3)
        #expect(try await index.search("beta").count == 1)
        #expect(try await index.search("gamma").count == 1)
    }

    // MARK: 2b — corrupt-meeting.json surfacing

    @Test func reloadSurfacesSkippedCorruptFoldersWithoutDroppingValidOnes() throws {
        let storage = makeStorage()
        _ = try storage.create(Meeting(title: "Valid A", date: .now))
        _ = try storage.create(Meeting(title: "Valid B", date: .now))
        let corrupt = storage.rootURL.appendingPathComponent("corrupt folder")
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: corrupt.appendingPathComponent("meeting.json"))

        var reportedMessages: [String] = []
        let store = LibraryStore(storage: storage, index: try SearchIndex(), changeBus: LibraryChangeBus())
        store.onSaveError = { reportedMessages.append($0) }
        store.reload()

        #expect(store.meetings.count == 2)
        #expect(reportedMessages.contains { $0.contains("1 meeting") })
    }

    // MARK: 2c — root unreachable

    @Test func reloadWithMissingCustomRootSetsRootUnreachableAndKeepsLastKnownMeetings() throws {
        let storage = makeStorage()
        let record = try storage.create(Meeting(title: "Before the folder vanished", date: .now))
        let store = LibraryStore(storage: storage, index: try SearchIndex(), changeBus: LibraryChangeBus())
        #expect(!store.rootUnreachable)
        #expect(store.meetings.map(\.meeting.id) == [record.meeting.id])

        // The folder disappears from under the app (drive unmounted, folder
        // deleted/renamed) — a temp dir is always distinct from the real
        // default root, so this is the "customized root" branch of
        // `LibraryStorage.rootUnreachableIsError`.
        try FileManager.default.removeItem(at: storage.rootURL)

        store.reload()

        #expect(store.rootUnreachable)
        // Last-known meetings stay in memory rather than being wiped to
        // empty — losing the folder must not look like losing the meetings.
        #expect(store.meetings.map(\.meeting.id) == [record.meeting.id])
    }

    @Test func reloadClearsRootUnreachableOnceTheRootIsBackAndReloadsMeetings() throws {
        let storage = makeStorage()
        let record = try storage.create(Meeting(title: "Survives a round trip", date: .now))
        let store = LibraryStore(storage: storage, index: try SearchIndex(), changeBus: LibraryChangeBus())

        // Simulate the root going away (unmounted drive, moved/renamed
        // folder) by moving it aside, rather than deleting it — that way
        // moving it back below restores the exact same meeting folder.
        let movedAside = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryStoreReloadTests-movedaside-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: storage.rootURL, to: movedAside)
        store.reload()
        #expect(store.rootUnreachable)

        try FileManager.default.moveItem(at: movedAside, to: storage.rootURL)
        store.reload()

        #expect(!store.rootUnreachable)
        #expect(store.meetings.map(\.meeting.id) == [record.meeting.id])
    }
}
