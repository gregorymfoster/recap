import Foundation
import Testing
@testable import RecapCore

@Suite struct SearchIndexTests {
    func makeLibrary() throws -> (LibraryStorage, SearchIndex) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecapTests-\(UUID().uuidString)")
        return (LibraryStorage(rootURL: root), try SearchIndex())
    }

    @Test func defaultDatabaseURLIsRecapForProdBuild() {
        let url = SearchIndex.defaultDatabaseURL(isDevBuild: false)
        #expect(url.lastPathComponent == "index.db")
        #expect(url.deletingLastPathComponent().lastPathComponent == "Recap")
    }

    @Test func defaultDatabaseURLIsRecapDevForDevBuild() {
        let url = SearchIndex.defaultDatabaseURL(isDevBuild: true)
        #expect(url.lastPathComponent == "index.db")
        #expect(url.deletingLastPathComponent().lastPathComponent == "Recap Dev")
    }

    @Test func searchFindsTextAcrossNotesTranscriptAndTitle() throws {
        let (storage, index) = try makeLibrary()
        let record = try storage.create(Meeting(title: "Roadmap review", date: .now))
        try storage.saveNotes("- kubernetes migration blocked on budget", in: record)
        try storage.saveTranscript(
            Transcript(
                utterances: [Utterance(start: 0, end: 4, text: "The onboarding revamp ships in October.")],
                engine: "whisperkit", model: "small", language: "en"
            ),
            in: record
        )
        try index.reindex(from: storage)

        #expect(try index.search("kubernetes").map(\.meetingID) == [record.meeting.id])
        #expect(try index.search("onboarding").map(\.meetingID) == [record.meeting.id])
        #expect(try index.search("roadmap").map(\.meetingID) == [record.meeting.id])
        #expect(try index.search("zebra").isEmpty)
        #expect(try index.search("   ").isEmpty)
    }

    @Test func prefixMatchingSupportsTypeAhead() throws {
        let (storage, index) = try makeLibrary()
        let record = try storage.create(Meeting(title: "Budget", date: .now))
        try storage.saveNotes("discussed quarterly forecasting", in: record)
        try index.reindex(from: storage)

        #expect(try index.search("forecas").count == 1)
    }

    @Test func reindexHealsExternalEdits() throws {
        let (storage, index) = try makeLibrary()
        let record = try storage.create(Meeting(title: "Sync", date: .now))
        try storage.saveNotes("original content", in: record)
        try index.reindex(from: storage)
        #expect(try index.search("original").count == 1)

        // User edits notes.md in another app, adds a meeting folder by hand,
        // and the index knows nothing about either.
        try Data("edited externally with vim".utf8).write(to: record.notesURL)
        let handMade = Meeting(title: "Hand-made meeting", date: .now)
        _ = try storage.create(handMade)

        try index.reindex(from: storage)
        #expect(try index.search("original").isEmpty)
        #expect(try index.search("vim").map(\.meetingID) == [record.meeting.id])
        #expect(try index.search("hand-made").count == 1)
        #expect(try index.indexedMeetingCount() == 2)
    }

    @Test func updateRefreshesSingleMeeting() throws {
        let (storage, index) = try makeLibrary()
        let a = try storage.create(Meeting(title: "Alpha", date: .now))
        let b = try storage.create(Meeting(title: "Beta", date: .now))
        try index.reindex(from: storage)

        try storage.saveNotes("pineapple discussion", in: b)
        try index.update(b, from: storage)

        #expect(try index.search("pineapple").map(\.meetingID) == [b.meeting.id])
        #expect(try index.search("alpha").map(\.meetingID) == [a.meeting.id])
        #expect(try index.indexedMeetingCount() == 2)
    }
}
