import Foundation
import Testing
@testable import RecapCore

@Suite struct LibraryStorageTests {
    func makeStorage() throws -> LibraryStorage {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecapTests-\(UUID().uuidString)")
        return LibraryStorage(rootURL: root)
    }

    @Test func defaultRootURLIsRecapForProdBuild() {
        #expect(LibraryStorage.defaultRootURL(isDevBuild: false).lastPathComponent == "Recap")
    }

    @Test func defaultRootURLIsRecapDevForDevBuild() {
        #expect(LibraryStorage.defaultRootURL(isDevBuild: true).lastPathComponent == "Recap Dev")
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

    @Test func createImportedMeetingRoundTripsAsQueued() throws {
        let storage = try makeStorage()
        let date = Date(timeIntervalSince1970: 1_780_400_000)
        let record = try storage.createImportedMeeting(title: "Podcast episode", date: date)

        #expect(record.meeting.status == .queued)
        #expect(record.meeting.title == "Podcast episode")
        #expect(record.meeting.date == date)
        #expect(record.meeting.duration == 0)
        #expect(FileManager.default.fileExists(atPath: record.metadataURL.path))

        let loaded = try storage.loadAll()
        #expect(loaded.map(\.meeting) == [record.meeting])
    }

    @Test func importedMeetingTitleCollisionOnSameDayGetsDistinctFolder() throws {
        let storage = try makeStorage()
        let date = Date(timeIntervalSince1970: 1_780_400_000)
        // A recorded meeting and an import with the same title on the same day.
        let recorded = try storage.create(Meeting(title: "Interview", date: date))
        let imported = try storage.createImportedMeeting(title: "Interview", date: date)

        #expect(recorded.folderURL != imported.folderURL)
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

    @Test func renameUpdatesTitleButKeepsFolderURL() throws {
        let storage = try makeStorage()
        let record = try storage.create(Meeting(title: "Old title", date: .now))

        let renamed = try storage.rename(record, to: "New title")

        #expect(renamed.meeting.title == "New title")
        #expect(renamed.folderURL == record.folderURL)

        let loaded = try storage.loadAll()
        #expect(loaded.map(\.meeting.title) == ["New title"])
        #expect(loaded.first?.folderURL.resolvingSymlinksInPath() == record.folderURL.resolvingSymlinksInPath())
    }

    @Test func speakerNamesRoundTripAndDefaultToEmpty() throws {
        let storage = try makeStorage()
        let record = try storage.create(Meeting(title: "Standup", date: .now))

        // No speakers.json yet — empty mapping, not an error.
        #expect(try storage.loadSpeakerNames(in: record) == SpeakerNames())

        var speakerNames = SpeakerNames()
        speakerNames["S1"] = "Maya"
        speakerNames["S2"] = "Sam"
        try storage.saveSpeakerNames(speakerNames, in: record)

        #expect(FileManager.default.fileExists(atPath: record.speakerNamesURL.path))
        #expect(try storage.loadSpeakerNames(in: record) == speakerNames)

        // Overwriting persists the new mapping, not a merge of the old.
        var updated = SpeakerNames()
        updated["S1"] = "Maya Chen"
        try storage.saveSpeakerNames(updated, in: record)
        #expect(try storage.loadSpeakerNames(in: record) == updated)
    }

    @Test func timedNotesRoundTripAndDefaultToEmpty() throws {
        let storage = try makeStorage()
        let record = try storage.create(Meeting(title: "Standup", date: .now))

        // No notes.json yet — empty array, not an error.
        #expect(try storage.loadTimedNotes(in: record) == [])

        // Whole-second `createdAt` — the encoder's `.iso8601` date strategy
        // truncates fractional seconds, so a sub-second default `.now` would
        // fail a round-trip equality check for reasons unrelated to what
        // this test covers.
        let createdAt = Date(timeIntervalSince1970: 1_780_400_000)
        let notes = [
            TimedNote(offset: 12, text: "Follow up with Sam", createdAt: createdAt),
            TimedNote(offset: 90, text: "Ship by Friday", createdAt: createdAt),
        ]
        try storage.saveTimedNotes(notes, in: record)

        #expect(FileManager.default.fileExists(atPath: record.timedNotesURL.path))
        #expect(try storage.loadTimedNotes(in: record) == notes)

        // Overwriting persists the new list, not a merge of the old.
        let updated = [TimedNote(offset: 5, text: "Just this one now", createdAt: createdAt)]
        try storage.saveTimedNotes(updated, in: record)
        #expect(try storage.loadTimedNotes(in: record) == updated)
    }

    @Test func loadAllDetailedReportsSkippedFolderCount() throws {
        let storage = try makeStorage()
        _ = try storage.create(Meeting(title: "Valid A", date: .now))
        _ = try storage.create(Meeting(title: "Valid B", date: .now))
        // A folder with garbage instead of a real meeting.json.
        let corrupt = storage.rootURL.appendingPathComponent("corrupt folder")
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: corrupt.appendingPathComponent("meeting.json"))

        let result = try storage.loadAllDetailed()

        #expect(result.records.count == 2)
        #expect(result.skippedCount == 1)
        // loadAll() itself is unaffected — still just the valid records.
        #expect(try storage.loadAll().count == 2)
    }

    @Test func loadRecordRoundTripsACreatedMeeting() throws {
        let storage = try makeStorage()
        // A fixed whole-second epoch date — ISO8601 encoding drops
        // sub-second precision, so `Date.now` would fail the round-trip
        // equality check below for a reason unrelated to `loadRecord` itself.
        let record = try storage.create(Meeting(title: "Design sync", date: Date(timeIntervalSince1970: 1_780_400_000)))

        let loaded = storage.loadRecord(inFolder: record.folderURL)

        #expect(loaded?.meeting == record.meeting)
        #expect(loaded?.folderURL.resolvingSymlinksInPath() == record.folderURL.resolvingSymlinksInPath())
    }

    @Test func loadRecordReturnsNilForMissingMetadata() throws {
        let storage = try makeStorage()
        let emptyFolder = storage.rootURL.appendingPathComponent("no meeting.json here")
        try FileManager.default.createDirectory(at: emptyFolder, withIntermediateDirectories: true)

        #expect(storage.loadRecord(inFolder: emptyFolder) == nil)
    }

    @Test func loadRecordReturnsNilForCorruptMetadata() throws {
        let storage = try makeStorage()
        let corrupt = storage.rootURL.appendingPathComponent("corrupt folder")
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: corrupt.appendingPathComponent("meeting.json"))

        #expect(storage.loadRecord(inFolder: corrupt) == nil)
    }

    @Test func rootIsReachableTrueWhenDirectoryExists() throws {
        let storage = try makeStorage()
        #expect(!storage.rootIsReachable(), "root doesn't exist yet — no meeting created")
        _ = try storage.create(Meeting(title: "First meeting", date: .now))
        #expect(storage.rootIsReachable())
    }

    @Test func rootIsReachableFalseForAFileAtThatPathInsteadOfADirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecapTests-\(UUID().uuidString)")
        try Data().write(to: root)
        let storage = LibraryStorage(rootURL: root)
        #expect(!storage.rootIsReachable())
    }

    // MARK: rootUnreachableIsError

    @Test func rootUnreachableIsErrorFalseWhenReachable() {
        #expect(!LibraryStorage.rootUnreachableIsError(reachable: true, isCustomRoot: true, wasReachableEarlierThisLaunch: true))
    }

    @Test func rootUnreachableIsErrorFalseForFreshDefaultInstall() {
        // A default-location root that's never existed and was never
        // reachable this launch — a fresh install waiting on its first
        // recording — must not read as an error.
        #expect(!LibraryStorage.rootUnreachableIsError(reachable: false, isCustomRoot: false, wasReachableEarlierThisLaunch: false))
    }

    @Test func rootUnreachableIsErrorTrueForMissingCustomizedRoot() {
        #expect(LibraryStorage.rootUnreachableIsError(reachable: false, isCustomRoot: true, wasReachableEarlierThisLaunch: false))
    }

    @Test func rootUnreachableIsErrorTrueWhenReachableEarlierThisLaunchThenVanished() {
        #expect(LibraryStorage.rootUnreachableIsError(reachable: false, isCustomRoot: false, wasReachableEarlierThisLaunch: true))
    }

    @Test func trashMovesFolderAndRemovesItFromLoadAll() throws {
        let storage = try makeStorage()
        let keep = try storage.create(Meeting(title: "Keep me", date: .now))
        let doomed = try storage.create(Meeting(title: "Trash me", date: .now))
        #expect(try storage.loadAll().count == 2)

        try storage.trash(doomed)

        #expect(!FileManager.default.fileExists(atPath: doomed.folderURL.path))
        let loaded = try storage.loadAll()
        #expect(loaded.map(\.meeting.id) == [keep.meeting.id])
    }
}
