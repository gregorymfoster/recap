import Foundation
import Testing
@testable import RecapCore

@Suite struct LibraryStorageTests {
    func makeStorage() throws -> LibraryStorage {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecapTests-\(UUID().uuidString)")
        return LibraryStorage(rootURL: root)
    }

    @Test func createWritesFolderMetadataAndEmptyNotes() throws {
        let storage = try makeStorage()
        let meeting = Meeting(title: "Design sync", date: Date(timeIntervalSince1970: 1_780_400_000))
        let record = try storage.create(meeting)

        #expect(FileManager.default.fileExists(atPath: record.metadataURL.path))
        #expect(try storage.loadNotes(in: record) == "")
        #expect(record.folderURL.lastPathComponent.hasSuffix("Design sync"))

        // Compare identity + resolved paths: loadAll returns /private/var/… where
        // the tmp root was created via the /var symlink.
        let loaded = try storage.loadAll()
        #expect(loaded.map(\.meeting) == [record.meeting])
        #expect(
            loaded.map { $0.folderURL.resolvingSymlinksInPath() }
                == [record.folderURL.resolvingSymlinksInPath()]
        )
    }

    @Test func contentFilesRoundTrip() throws {
        let storage = try makeStorage()
        let record = try storage.create(Meeting(title: "Standup", date: .now))

        try storage.saveNotes("- ship it", in: record)
        #expect(try storage.loadNotes(in: record) == "- ship it")

        #expect(try storage.loadEnhancedNotes(in: record) == nil)
        try storage.saveEnhancedNotes("## Shipped\nWe shipped it.", in: record)
        #expect(try storage.loadEnhancedNotes(in: record) == "## Shipped\nWe shipped it.")

        #expect(try storage.loadTranscript(in: record) == nil)
        let transcript = Transcript(
            utterances: [Utterance(start: 0, end: 3, text: "Let's ship it today.")],
            engine: "whisperkit", model: "openai_whisper-small", language: "en"
        )
        try storage.saveTranscript(transcript, in: record)
        #expect(try storage.loadTranscript(in: record) == transcript)
    }

    @Test func duplicateTitlesOnSameDayGetDistinctFolders() throws {
        let storage = try makeStorage()
        let date = Date(timeIntervalSince1970: 1_780_400_000)
        let first = try storage.create(Meeting(title: "1:1", date: date))
        let second = try storage.create(Meeting(title: "1:1", date: date))
        #expect(first.folderURL != second.folderURL)
        #expect(try storage.loadAll().count == 2)
    }

    @Test func folderNameSanitizesPathHostileCharacters() {
        let meeting = Meeting(title: "Q3: budget / review", date: Date(timeIntervalSince1970: 1_780_400_000))
        let name = LibraryStorage.folderName(for: meeting)
        #expect(!name.contains("/"))
        #expect(!name.contains(":"))
    }

    @Test func loadAllSkipsForeignFoldersAndSortsNewestFirst() throws {
        let storage = try makeStorage()
        let older = try storage.create(Meeting(title: "Old", date: Date(timeIntervalSince1970: 1_000)))
        let newer = try storage.create(Meeting(title: "New", date: Date(timeIntervalSince1970: 2_000)))
        // A folder the user dropped in by hand, with no meeting.json.
        try FileManager.default.createDirectory(
            at: storage.rootURL.appendingPathComponent("random stuff"),
            withIntermediateDirectories: true
        )

        let loaded = try storage.loadAll()
        #expect(loaded.map(\.meeting.id) == [newer.meeting.id, older.meeting.id])
    }
}
