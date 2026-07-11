import Foundation
import Testing
@testable import RecapCore
@testable import RecapUI

/// `LibraryStore.search(_:)`'s async overload — mirrors the sync fixture-mode
/// title-filter path, exercised here since fixture mode has no disk-backed
/// `SearchIndex` to go through.
@MainActor
@Suite struct LibraryStoreSearchTests {
    static func record(_ title: String) -> MeetingRecord {
        MeetingRecord(meeting: Meeting(title: title, date: .now), folderURL: URL(filePath: "/dev/null"))
    }

    @Test func asyncSearchFiltersFixtureTitles() async {
        let store = LibraryStore(fixtures: [Self.record("Roadmap review"), Self.record("Standup")])

        let hits = await store.search("roadmap")

        #expect(hits.map(\.title) == ["Roadmap review"])
    }

    @Test func asyncSearchMatchesSyncSearchInFixtureMode() async {
        let store = LibraryStore(fixtures: [Self.record("Roadmap review"), Self.record("Standup")])

        let asyncHits = await store.search("stand")
        let syncHits = syncSearch(store, "stand")

        #expect(asyncHits == syncHits)
    }

    /// Calls the synchronous `search(_:)` overload from an async test
    /// context. A plain `store.search(query)` call site there resolves to
    /// the async overload (Swift prefers it in an async context even
    /// without `await`), so this forces the sync one via a non-async closure.
    private func syncSearch(_ store: LibraryStore, _ query: String) -> [SearchHit] {
        store.search(query)
    }
}
