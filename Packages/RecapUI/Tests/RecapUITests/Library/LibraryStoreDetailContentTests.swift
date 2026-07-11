import Foundation
import Testing
@testable import RecapCore
@testable import RecapUI

/// Covers `LibraryStore.loadDetailContent(for:)` — the off-main bundle of
/// notes/transcript/enhanced-notes/speaker-names/timed-notes plus the
/// pre-merged `TranscriptMerge.Item` list that replaced five separate
/// `MeetingDetailView` disk reads and an in-body merge.
@MainActor
@Suite struct LibraryStoreDetailContentTests {
    private func makeStorage() -> LibraryStorage {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryStoreDetailContentTests-\(UUID().uuidString)")
        return LibraryStorage(rootURL: root)
    }

    @Test func diskBackedLoadReturnsAllFieldsWithTranscriptItemsInTimeOrder() async throws {
        let storage = makeStorage()
        let record = try storage.create(Meeting(title: "Standup", date: .now))
        try storage.saveNotes("raw notes", in: record)
        try storage.saveEnhancedNotes("## Enhanced", in: record)
        var speakerNames = SpeakerNames()
        speakerNames["S1"] = "Maya"
        try storage.saveSpeakerNames(speakerNames, in: record)
        let transcript = Transcript(
            utterances: [
                Utterance(speakerID: "S1", start: 0, end: 3, text: "First"),
                Utterance(speakerID: "S1", start: 10, end: 13, text: "Second"),
            ],
            engine: "whisperkit", model: "openai_whisper-small", language: "en"
        )
        try storage.saveTranscript(transcript, in: record)
        // Whole-second `createdAt` — the encoder's `.iso8601` date strategy
        // truncates fractional seconds, so a sub-second default `.now`
        // would fail the round-trip equality check below.
        let timedNote = TimedNote(offset: 5, text: "Follow up", createdAt: Date(timeIntervalSince1970: 1_780_400_000))
        try storage.saveTimedNotes([timedNote], in: record)

        let index = try SearchIndex()
        let store = LibraryStore(storage: storage, index: index, changeBus: LibraryChangeBus())

        let content = await store.loadDetailContent(for: record)

        #expect(content.notes == "raw notes")
        #expect(content.transcript == transcript)
        #expect(content.enhancedNotes == "## Enhanced")
        #expect(content.speakerNames == ["S1": "Maya"])
        #expect(content.timedNotes == [timedNote])
        // Interleaved in time order: utterance@0, note@5, utterance@10.
        #expect(content.transcriptItems.map(\.id) == [
            transcript.utterances[0].id, timedNote.id, transcript.utterances[1].id,
        ])
    }

    @Test func diskBackedLoadPrimesTheTimedNotesCacheForSubsequentAddTimedNote() async throws {
        let storage = makeStorage()
        let record = try storage.create(Meeting(title: "Standup", date: .now))
        let existingNote = TimedNote(offset: 5, text: "Existing")
        try storage.saveTimedNotes([existingNote], in: record)

        let store = LibraryStore(storage: storage, index: try SearchIndex(), changeBus: LibraryChangeBus())
        _ = await store.loadDetailContent(for: record)

        // `addTimedNote` reads through `timedNotes(for:)`'s cache — if
        // `loadDetailContent` primed it correctly, the existing note
        // survives alongside the newly added one.
        store.addTimedNote("New note", at: 20, in: record)

        let onDisk = try storage.loadTimedNotes(in: record)
        #expect(onDisk.map(\.text).sorted() == ["Existing", "New note"])
    }

    @Test func fixtureStoreReturnsFixtureDataWithMergedTranscriptItems() async throws {
        let record = MeetingRecord(
            meeting: Meeting(title: "Fixture meeting", date: .now, status: .ready),
            folderURL: URL(filePath: "/dev/null")
        )
        let transcript = Transcript(
            utterances: [Utterance(start: 0, end: 2, text: "Hello")],
            engine: "whisperkit", model: "openai_whisper-small", language: "en"
        )
        let timedNote = TimedNote(offset: 1, text: "Pinned")
        let store = LibraryStore(
            fixtures: [record],
            transcripts: [record.meeting.id: transcript],
            notes: [record.meeting.id: "fixture notes"],
            enhancedNotes: [record.meeting.id: "fixture enhanced"],
            timedNotes: [record.meeting.id: [timedNote]]
        )

        let content = await store.loadDetailContent(for: record)

        #expect(content.notes == "fixture notes")
        #expect(content.transcript == transcript)
        #expect(content.enhancedNotes == "fixture enhanced")
        #expect(content.speakerNames.isEmpty)
        #expect(content.timedNotes == [timedNote])
        #expect(content.transcriptItems.count == 2)
    }
}
