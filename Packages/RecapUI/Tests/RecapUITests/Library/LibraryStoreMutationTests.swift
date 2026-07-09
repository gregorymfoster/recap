import Foundation
import Testing
@testable import RecapCore
@testable import RecapUI

extension LibraryChange: @retroactive Equatable {
    public static func == (lhs: LibraryChange, rhs: LibraryChange) -> Bool {
        switch (lhs, rhs) {
        case (.meetingChanged(let a), .meetingChanged(let b)): a == b
        case (.meetingDeleted(let a), .meetingDeleted(let b)): a == b
        default: false
        }
    }
}

/// Collects `LibraryChange` posts from a `LibraryChangeBus`. Construct with
/// `make(_:)` *before* the action under test runs so no post is missed —
/// the bus fans out to whatever subscribers exist at post time.
private actor ChangeCollector {
    private var changes: [LibraryChange] = []
    private var task: Task<Void, Never>?

    static func make(_ bus: LibraryChangeBus) -> ChangeCollector {
        let collector = ChangeCollector()
        let stream = bus.changes()
        Task { await collector.consume(stream) }
        return collector
    }

    private func consume(_ stream: AsyncStream<LibraryChange>) async {
        task = Task { [weak self] in
            for await change in stream {
                await self?.append(change)
            }
        }
        // Yield so the subscription (bus.changes() already registered the
        // continuation synchronously above) is guaranteed live before callers
        // start acting — the continuation itself is registered before this
        // task even runs, so this is a safety margin, not a requirement.
        await Task.yield()
    }

    private func append(_ change: LibraryChange) {
        changes.append(change)
    }

    /// Polls briefly for at least `count` collected changes — delivery is
    /// asynchronous, so a synchronous read right after the action can race it.
    func waitForCount(_ count: Int, timeout: Duration = .milliseconds(500)) async -> [LibraryChange] {
        let deadline = ContinuousClock.now + timeout
        while changes.count < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return changes
    }

    deinit {
        task?.cancel()
    }
}

@MainActor
@Suite struct LibraryStoreMutationTests {
    private func makeStore() -> (LibraryStore, LibraryStorage, LibraryChangeBus) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryStoreMutationTests-\(UUID().uuidString)")
        let storage = LibraryStorage(rootURL: root)
        let changeBus = LibraryChangeBus()
        let index = try! SearchIndex()
        let store = LibraryStore(storage: storage, index: index, changeBus: changeBus)
        return (store, storage, changeBus)
    }

    // MARK: reload

    @Test func reloadPicksUpMeetingsWrittenDirectlyToStorage() throws {
        let (store, storage, _) = makeStore()
        #expect(store.meetings.isEmpty)

        _ = try storage.create(Meeting(title: "Written directly", date: .now))
        #expect(store.meetings.isEmpty, "store shouldn't see disk changes until reload()")

        store.reload()
        #expect(store.meetings.map(\.meeting.title) == ["Written directly"])
    }

    // MARK: startNewMeeting

    @Test func startNewMeetingCreatesFolderAndRecordingStatus() async throws {
        let (store, storage, changeBus) = makeStore()
        let collector = ChangeCollector.make(changeBus)

        let record = store.startNewMeeting(title: "Standup", attendees: ["Sam"])

        let record2 = try #require(record)
        #expect(record2.meeting.title == "Standup")
        #expect(record2.meeting.attendees == ["Sam"])
        #expect(record2.meeting.status == .recording)
        #expect(store.meetings.first?.meeting.id == record2.meeting.id)
        #expect(store.selectedMeetingID == record2.meeting.id)

        // Disk state: folder + metadata + empty notes exist.
        #expect(FileManager.default.fileExists(atPath: record2.folderURL.path))
        #expect(FileManager.default.fileExists(atPath: record2.metadataURL.path))
        #expect(FileManager.default.fileExists(atPath: record2.notesURL.path))
        let reloaded = try storage.loadAll()
        #expect(reloaded.first?.meeting.id == record2.meeting.id)

        // startNewMeeting itself doesn't post to the change bus (only
        // replace()/insertImported() do) — confirm no spurious post arrived.
        let changes = await collector.waitForCount(1, timeout: .milliseconds(100))
        #expect(changes.isEmpty)
    }

    // MARK: finishRecording

    @Test func finishRecordingSetsQueuedStatusAndDuration() async throws {
        let (store, storage, changeBus) = makeStore()
        let record = try #require(store.startNewMeeting(title: "Recorded meeting"))
        let collector = ChangeCollector.make(changeBus)

        store.finishRecording(record, duration: 123.5)

        let updated = try #require(store.record(for: record.meeting.id))
        #expect(updated.meeting.status == .queued)
        #expect(updated.meeting.duration == 123.5)

        let onDisk = try #require(try storage.loadAll().first { $0.meeting.id == record.meeting.id })
        #expect(onDisk.meeting.status == .queued)
        #expect(onDisk.meeting.duration == 123.5)

        let changes = await collector.waitForCount(1)
        #expect(changes == [.meetingChanged(record.meeting.id)])
    }

    // MARK: updateStatus

    @Test func updateStatusPersistsNonTranscribingTransitions() async throws {
        let (store, storage, changeBus) = makeStore()
        let record = try #require(store.startNewMeeting(title: "Meeting"))
        let collector = ChangeCollector.make(changeBus)

        store.updateStatus(record.meeting.id, to: .ready)

        #expect(store.record(for: record.meeting.id)?.meeting.status == .ready)
        let onDisk = try #require(try storage.loadAll().first { $0.meeting.id == record.meeting.id })
        #expect(onDisk.meeting.status == .ready)

        let changes = await collector.waitForCount(1)
        #expect(changes == [.meetingChanged(record.meeting.id)])
    }

    @Test func updateStatusBetweenTranscribingProgressSkipsDiskWrite() async throws {
        let (store, storage, changeBus) = makeStore()
        let record = try #require(store.startNewMeeting(title: "Meeting"))
        store.updateStatus(record.meeting.id, to: .transcribing(progress: 0.1))
        let collector = ChangeCollector.make(changeBus)

        // Progress-only tick between two .transcribing states: store updates
        // in memory but does not hit disk or the change bus (UI-only churn).
        store.updateStatus(record.meeting.id, to: .transcribing(progress: 0.5))

        #expect(store.record(for: record.meeting.id)?.meeting.status == .transcribing(progress: 0.5))
        let onDisk = try #require(try storage.loadAll().first { $0.meeting.id == record.meeting.id })
        if case .transcribing(let progress) = onDisk.meeting.status {
            #expect(progress != 0.5, "progress ticks between .transcribing states must not hit disk")
        } else {
            Issue.record("expected on-disk status to remain .transcribing, got \(onDisk.meeting.status)")
        }

        let changes = await collector.waitForCount(1, timeout: .milliseconds(100))
        #expect(changes.isEmpty)
    }

    @Test func updateStatusForUnknownIDIsANoOp() {
        let (store, _, _) = makeStore()
        store.updateStatus(UUID(), to: .ready)
        #expect(store.meetings.isEmpty)
    }

    @Test func processingIssuePersistsAndClearsIndependently() throws {
        let (store, storage, _) = makeStore()
        let record = try #require(store.startNewMeeting(title: "Meeting"))

        store.addProcessingIssue(.enhancementFailed, for: record.meeting.id)
        store.addProcessingIssue(.mirrorBackupFailed, for: record.meeting.id)
        store.clearProcessingIssue(.enhancementFailed, for: record.meeting.id)

        #expect(store.record(for: record.meeting.id)?.meeting.processingIssues == [.mirrorBackupFailed])
        let onDisk = try #require(try storage.loadAll().first { $0.meeting.id == record.meeting.id })
        #expect(onDisk.meeting.processingIssues == [.mirrorBackupFailed])
    }

    // MARK: updateDuration

    @Test func updateDurationPersistsNewDuration() async throws {
        let (store, storage, changeBus) = makeStore()
        let record = try #require(store.startNewMeeting(title: "Meeting"))
        let collector = ChangeCollector.make(changeBus)

        store.updateDuration(record.meeting.id, to: 987)

        #expect(store.record(for: record.meeting.id)?.meeting.duration == 987)
        let onDisk = try #require(try storage.loadAll().first { $0.meeting.id == record.meeting.id })
        #expect(onDisk.meeting.duration == 987)

        let changes = await collector.waitForCount(1)
        #expect(changes == [.meetingChanged(record.meeting.id)])
    }

    // MARK: replace (via markError, which is its only other public caller)

    @Test func markErrorReplacesStatusAndPersists() async throws {
        let (store, storage, changeBus) = makeStore()
        let record = try #require(store.startNewMeeting(title: "Meeting"))
        let collector = ChangeCollector.make(changeBus)

        store.markError(record, message: "mic denied")

        #expect(store.record(for: record.meeting.id)?.meeting.status == .error(message: "mic denied"))
        let onDisk = try #require(try storage.loadAll().first { $0.meeting.id == record.meeting.id })
        #expect(onDisk.meeting.status == .error(message: "mic denied"))

        let changes = await collector.waitForCount(1)
        #expect(changes == [.meetingChanged(record.meeting.id)])
    }

    @Test func replaceUpdatesUpdatedAtTimestamp() throws {
        let (store, _, _) = makeStore()
        let record = try #require(store.startNewMeeting(title: "Meeting"))
        #expect(record.meeting.updatedAt == nil)

        store.updateDuration(record.meeting.id, to: 42)

        let updated = try #require(store.record(for: record.meeting.id))
        #expect(updated.meeting.updatedAt != nil)
    }

    // MARK: setPreferredNotesView

    @Test func setPreferredNotesViewPersistsChoiceAndPostsChange() async throws {
        let (store, storage, changeBus) = makeStore()
        let record = try #require(store.startNewMeeting(title: "Meeting"))
        let collector = ChangeCollector.make(changeBus)

        store.setPreferredNotesView(.original, for: record.meeting.id)

        #expect(store.record(for: record.meeting.id)?.meeting.preferredNotesView == .original)
        let onDisk = try #require(try storage.loadAll().first { $0.meeting.id == record.meeting.id })
        #expect(onDisk.meeting.preferredNotesView == .original)

        let changes = await collector.waitForCount(1)
        #expect(changes == [.meetingChanged(record.meeting.id)])
    }

    @Test func setPreferredNotesViewNilClearsStoredPreference() throws {
        let (store, _, _) = makeStore()
        let record = try #require(store.startNewMeeting(title: "Meeting"))
        store.setPreferredNotesView(.original, for: record.meeting.id)

        store.setPreferredNotesView(nil, for: record.meeting.id)

        #expect(store.record(for: record.meeting.id)?.meeting.preferredNotesView == nil)
    }

    // MARK: updateSubtitle

    @Test func updateSubtitlePersistsAndPostsChange() async throws {
        let (store, storage, changeBus) = makeStore()
        let record = try #require(store.startNewMeeting(title: "Meeting"))
        let collector = ChangeCollector.make(changeBus)

        store.updateSubtitle("Q3 budget approved, launch slips a week", for: record.meeting.id)

        #expect(store.record(for: record.meeting.id)?.meeting.subtitle == "Q3 budget approved, launch slips a week")
        let onDisk = try #require(try storage.loadAll().first { $0.meeting.id == record.meeting.id })
        #expect(onDisk.meeting.subtitle == "Q3 budget approved, launch slips a week")

        let changes = await collector.waitForCount(1)
        #expect(changes == [.meetingChanged(record.meeting.id)])
    }

    // MARK: renameSpeaker / loadSpeakerNames

    @Test func renameSpeakerPersistsAndPostsChange() async throws {
        let (store, storage, changeBus) = makeStore()
        let record = try #require(store.startNewMeeting(title: "Meeting"))
        let collector = ChangeCollector.make(changeBus)

        #expect(store.loadSpeakerNames(for: record).isEmpty)

        store.renameSpeaker("S1", to: "Maya", in: record)

        #expect(store.loadSpeakerNames(for: record) == ["S1": "Maya"])
        let onDisk = try storage.loadSpeakerNames(in: record)
        #expect(onDisk.names == ["S1": "Maya"])

        let changes = await collector.waitForCount(1)
        #expect(changes == [.meetingChanged(record.meeting.id)])
    }

    @Test func renameSpeakerTwiceKeepsBothMappings() throws {
        let (store, _, _) = makeStore()
        let record = try #require(store.startNewMeeting(title: "Meeting"))

        store.renameSpeaker("S1", to: "Maya", in: record)
        store.renameSpeaker("S2", to: "Sam", in: record)

        #expect(store.loadSpeakerNames(for: record) == ["S1": "Maya", "S2": "Sam"])
    }

    @Test func renameSpeakerWithBlankNameClearsTheMapping() throws {
        let (store, _, _) = makeStore()
        let record = try #require(store.startNewMeeting(title: "Meeting"))
        store.renameSpeaker("S1", to: "Maya", in: record)

        store.renameSpeaker("S1", to: "   ", in: record)

        #expect(store.loadSpeakerNames(for: record).isEmpty)
    }

    // MARK: addTimedNote / timedNotes

    @Test func addTimedNotePersistsAndPostsChange() async throws {
        let (store, storage, changeBus) = makeStore()
        let record = try #require(store.startNewMeeting(title: "Meeting"))
        let collector = ChangeCollector.make(changeBus)

        #expect(store.timedNotes(for: record).isEmpty)

        store.addTimedNote("Follow up with Sam", at: 42, in: record)

        let notes = store.timedNotes(for: record)
        #expect(notes.map(\.text) == ["Follow up with Sam"])
        #expect(notes.map(\.offset) == [42])
        let onDisk = try storage.loadTimedNotes(in: record)
        #expect(onDisk.map(\.text) == ["Follow up with Sam"])

        let changes = await collector.waitForCount(1)
        #expect(changes == [.meetingChanged(record.meeting.id)])
    }

    @Test func addTimedNoteTwiceAppendsBothInOffsetOrder() throws {
        let (store, _, _) = makeStore()
        let record = try #require(store.startNewMeeting(title: "Meeting"))

        store.addTimedNote("First", at: 5, in: record)
        store.addTimedNote("Second", at: 90, in: record)

        #expect(store.timedNotes(for: record).map(\.text) == ["First", "Second"])
    }

    @Test func timedNotesCachesAfterFirstDiskLoad() throws {
        let (store, storage, _) = makeStore()
        let record = try #require(store.startNewMeeting(title: "Meeting"))

        // First read populates the cache from disk (empty — nothing saved yet).
        #expect(store.timedNotes(for: record).isEmpty)

        // Writing to disk directly, bypassing the store, must not appear —
        // proves the second read comes from the cache, not a fresh disk read.
        try storage.saveTimedNotes([TimedNote(offset: 1, text: "Written directly")], in: record)
        #expect(store.timedNotes(for: record).isEmpty)
    }

    // MARK: rename

    @Test func renamePersistsNewTitleAndPostsChange() async throws {
        let (store, storage, changeBus) = makeStore()
        let record = try #require(store.startNewMeeting(title: "Original title"))
        let collector = ChangeCollector.make(changeBus)

        store.rename(record, to: "New title")

        #expect(store.record(for: record.meeting.id)?.meeting.title == "New title")
        let onDisk = try #require(try storage.loadAll().first { $0.meeting.id == record.meeting.id })
        #expect(onDisk.meeting.title == "New title")

        let changes = await collector.waitForCount(1)
        #expect(changes == [.meetingChanged(record.meeting.id)])
    }

    @Test func renameWithUntrimmedTitlePersistsExactlyAsGiven() throws {
        // LibraryStore.rename itself does no trimming — trimming is the
        // caller's responsibility (RenameSheetModifier / the detail-view
        // title field both trim before calling in). Confirm the store is a
        // faithful passthrough rather than silently re-trimming.
        let (store, storage, _) = makeStore()
        let record = try #require(store.startNewMeeting(title: "Original title"))

        store.rename(record, to: "  Padded title  ")

        #expect(store.record(for: record.meeting.id)?.meeting.title == "  Padded title  ")
        let onDisk = try #require(try storage.loadAll().first { $0.meeting.id == record.meeting.id })
        #expect(onDisk.meeting.title == "  Padded title  ")
    }

    @Test func renameOnFixtureStoreUpdatesInMemoryOnly() {
        // Fixture stores have no `storage`/`index`/`changeBus` — rename must
        // fall back to the in-memory-only branch rather than crashing.
        let record = MeetingRecord(
            meeting: Meeting(title: "Fixture meeting", date: .now),
            folderURL: URL(filePath: "/dev/null")
        )
        let store = LibraryStore(fixtures: [record])

        store.rename(record, to: "Renamed fixture meeting")

        #expect(store.record(for: record.meeting.id)?.meeting.title == "Renamed fixture meeting")
    }

    // MARK: insertImported

    @Test func insertImportedAddsRecordAtSortedPositionAndPostsChange() async throws {
        let (store, storage, changeBus) = makeStore()
        let older = try storage.createImportedMeeting(title: "Older import", date: .now.addingTimeInterval(-3_600))
        store.reload()
        let collector = ChangeCollector.make(changeBus)

        let newer = try storage.createImportedMeeting(title: "Newer import", date: .now)
        store.insertImported(newer)

        // meetings is newest-first at index 0 for a later date than everything present.
        #expect(store.meetings.first?.meeting.id == newer.meeting.id)
        #expect(store.meetings.map(\.meeting.id).contains(older.meeting.id))
        #expect(store.meetings.count == 2)

        let changes = await collector.waitForCount(1)
        #expect(changes == [.meetingChanged(newer.meeting.id)])
    }
}
