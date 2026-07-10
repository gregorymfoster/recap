import Foundation
import Observation
import RecapCore

@MainActor
@Observable
public final class LibraryStore {
    public private(set) var meetings: [MeetingRecord] = []
    public var selectedMeetingID: UUID?

    let storage: LibraryStorage?
    let index: SearchIndex?
    let autosaver: NotesAutosaver?
    let changeBus: LibraryChangeBus?
    /// Canned transcripts for fixture records (no disk in fixture mode), so
    /// -fixtures runs and screenshot dumps can show the transcript pane —
    /// avatars, rename affordance. Empty in disk-backed mode.
    var fixtureTranscripts: [UUID: Transcript] = [:]
    /// Canned raw notes for fixture records, mirroring `fixtureTranscripts`.
    /// Empty in disk-backed mode.
    var fixtureNotes: [UUID: String] = [:]
    /// Canned enhanced notes for fixture records, mirroring
    /// `fixtureTranscripts`. Empty in disk-backed mode.
    var fixtureEnhancedNotes: [UUID: String] = [:]
    /// In-memory timed notes for fixture records, mirroring
    /// `fixtureNotes` — `addTimedNote` appends here instead of touching disk.
    /// Empty in disk-backed mode.
    var fixtureTimedNotes: [UUID: [TimedNote]] = [:]
    /// Per-meeting cache of disk-loaded timed notes, so repeat
    /// `timedNotes(for:)` calls don't re-read `notes.json` — populated on
    /// first load, kept in sync by `addTimedNote`. Disk-backed mode only.
    var timedNotesCache: [UUID: [TimedNote]] = [:]

    /// Disk-backed store: loads the library and rebuilds the search index.
    public init(storage: LibraryStorage, index: SearchIndex, changeBus: LibraryChangeBus) {
        self.storage = storage
        self.index = index
        self.autosaver = NotesAutosaver(storage: storage)
        self.changeBus = changeBus
        reload()
    }

    /// Fixture store for previews and early UI work.
    public init(
        fixtures: [MeetingRecord],
        transcripts: [UUID: Transcript] = [:],
        notes: [UUID: String] = [:],
        enhancedNotes: [UUID: String] = [:],
        timedNotes: [UUID: [TimedNote]] = [:]
    ) {
        self.storage = nil
        self.index = nil
        self.autosaver = nil
        self.changeBus = nil
        self.meetings = fixtures
        self.fixtureTranscripts = transcripts
        self.fixtureNotes = notes
        self.fixtureEnhancedNotes = enhancedNotes
        self.fixtureTimedNotes = timedNotes
        rebuildDisplayMeetings()
    }

    /// `meetings`, newest-first — the source of truth (`meetings`) never
    /// changes order itself. Cached instead of resorted on every access: the
    /// redesign (design mock 10a/11c) dropped the user-facing sort/filter UI
    /// in favor of a single fixed ordering, but transcription-progress ticks
    /// touch `meetings` far more often than membership or dates change, and
    /// re-sorting + re-grouping the whole library on every tick was showing
    /// up as an O(n log n) hitch while a recording was transcribing. Rebuilt
    /// (`rebuildDisplayMeetings`) only when membership or sort keys (date)
    /// change; status/progress-only updates patch the cached element in
    /// place via `updateDisplayElement`.
    public private(set) var displayMeetings: [MeetingRecord] = []

    private func rebuildDisplayMeetings() {
        displayMeetings = meetings.sorted { $0.meeting.date > $1.meeting.date }
    }

    /// Patches one element of the cached `displayMeetings` in place, for
    /// mutations that don't change membership or sort order (status,
    /// progress, subtitle, backup timestamp, rename). No-op if the record
    /// isn't present (shouldn't happen, but keeps this defensive).
    private func updateDisplayElement(_ record: MeetingRecord) {
        if let i = displayMeetings.firstIndex(where: { $0.meeting.id == record.meeting.id }) {
            displayMeetings[i] = record
        }
    }

    public func reload() {
        guard let storage, let index else { return }
        meetings = (try? storage.loadAll()) ?? []
        try? index.reindex(from: storage)
        rebuildDisplayMeetings()
    }

    /// Creates a new meeting on disk and selects it. Calendar auto-record
    /// seeds the title and attendees from the event.
    @discardableResult
    public func startNewMeeting(title: String = "Untitled meeting", attendees: [String] = []) -> MeetingRecord? {
        let meeting = Meeting(title: title, date: .now, attendees: attendees, status: .recording)
        guard let storage else {
            let record = MeetingRecord(meeting: meeting, folderURL: URL(filePath: "/dev/null"))
            meetings.insert(record, at: 0)
            selectedMeetingID = meeting.id
            rebuildDisplayMeetings()
            return record
        }
        guard let record = try? storage.create(meeting) else { return nil }
        meetings.insert(record, at: 0)
        selectedMeetingID = meeting.id
        if let index { try? index.update(record, from: storage) }
        rebuildDisplayMeetings()
        return record
    }

    /// Recording stopped: persist the duration and hand the meeting to the
    /// processing queue (M6 — until then it parks as queued).
    public func finishRecording(_ record: MeetingRecord, duration: TimeInterval) {
        var updated = record
        updated.meeting.duration = duration
        updated.meeting.status = .queued
        replace(updated)
    }

    /// Adds an already-materialized imported meeting (folder, audio, and
    /// metadata all on disk — see `AudioImporter`) without a full `reload()`:
    /// sorted insert into the newest-first array, index update, change-bus
    /// post.
    public func insertImported(_ record: MeetingRecord) {
        let i = meetings.firstIndex { $0.meeting.date < record.meeting.date } ?? meetings.endIndex
        meetings.insert(record, at: i)
        if let storage, let index { try? index.update(record, from: storage) }
        rebuildDisplayMeetings()
        changeBus?.post(.meetingChanged(record.meeting.id))
    }

    /// Aborts a recording that never captured audio (permission denied, engine failure).
    public func markError(_ record: MeetingRecord, message: String) {
        var updated = record
        updated.meeting.status = .error(message: message)
        replace(updated)
    }

    /// Status transition from the processing pipeline. Transcription progress
    /// ticks update the UI only; transitions between states hit disk.
    public func updateStatus(_ id: UUID, to status: MeetingStatus) {
        guard var record = record(for: id) else { return }
        let previous = record.meeting.status
        guard MeetingStatusTransition.accepts(status, after: previous) else { return }
        record.meeting.status = status
        if case .transcribing = status, case .transcribing = previous {
            // Progress-only tick within the same status: patch both the
            // source array and the cached display order in place. Doesn't
            // touch sort keys, so no rebuild of displayMeetings.
            if let i = meetings.firstIndex(where: { $0.meeting.id == id }) {
                meetings[i] = record
            }
            updateDisplayElement(record)
        } else {
            replace(record)
        }
    }

    /// Persists a recoverable pipeline problem without demoting a meeting that
    /// is otherwise ready (for example, an optional export failure).
    public func addProcessingIssue(_ issue: ProcessingIssue, for id: UUID) {
        guard var record = record(for: id), !record.meeting.processingIssues.contains(issue) else { return }
        record.meeting.processingIssues.append(issue)
        replace(record)
    }

    /// Clears one successfully recovered stage while preserving any unrelated
    /// issues (for example, a repaired backup must not hide a transcription error).
    public func clearProcessingIssue(_ issue: ProcessingIssue, for id: UUID) {
        guard var record = record(for: id), record.meeting.processingIssues.contains(issue) else { return }
        record.meeting.processingIssues.removeAll { $0 == issue }
        replace(record)
    }

    /// Records a successful folder-mirror backup. Deliberately NOT routed
    /// through `replace(_:)`: a backup timestamp isn't a content change, so
    /// it must neither bump `updatedAt` (that would leave the meeting
    /// forever "pending" — `lastBackupDate < updatedAt` — for the next
    /// backfill) nor post `.meetingChanged` (that would re-trigger the very
    /// mirror export that just completed, looping through the change-bus
    /// consumer indefinitely).
    public func markBackedUp(_ id: UUID, at date: Date = .now) {
        guard var record = record(for: id) else { return }
        record.meeting.lastBackupDate = date
        if let i = meetings.firstIndex(where: { $0.meeting.id == id }) {
            meetings[i] = record
        }
        updateDisplayElement(record)
        guard let storage else { return }
        try? storage.saveMetadata(record)
    }

    /// Used by crash salvage: the recovered file is the only duration source.
    public func updateDuration(_ id: UUID, to duration: TimeInterval) {
        guard var record = record(for: id) else { return }
        record.meeting.duration = duration
        replace(record)
    }

    /// Persists the one-line subtitle generated during on-device enhancement,
    /// through the same metadata save path as every other mutation.
    public func updateSubtitle(_ subtitle: String, for id: UUID) {
        guard var record = record(for: id) else { return }
        record.meeting.subtitle = subtitle
        replace(record)
    }

    private func replace(_ record: MeetingRecord) {
        var record = record
        record.meeting.updatedAt = .now
        if let i = meetings.firstIndex(where: { $0.meeting.id == record.meeting.id }) {
            meetings[i] = record
        }
        // None of `replace`'s callers change `meeting.date` (the sort key),
        // so the cached display order stays valid — patch the element
        // in place rather than re-sorting the whole library.
        updateDisplayElement(record)
        guard let storage else { return }
        try? storage.saveMetadata(record)
        if let index { try? index.update(record, from: storage) }
        changeBus?.post(.meetingChanged(record.meeting.id))
    }

    public func record(for id: UUID) -> MeetingRecord? {
        meetings.first { $0.meeting.id == id }
    }

    /// Renames a meeting's display title. Fixture mode (no `storage`) updates
    /// the in-memory record only, so the context menu still works in previews.
    public func rename(_ record: MeetingRecord, to title: String) {
        guard let storage else {
            var updated = record
            updated.meeting.title = title
            replaceInMemoryOnly(updated)
            return
        }
        guard let renamed = try? storage.rename(record, to: title) else { return }
        replace(renamed)
    }

    /// Moves a meeting's folder to the Trash (recoverable) and drops it from
    /// the in-memory list + search index. No-ops in fixture mode — there's no
    /// real folder to trash for a `/dev/null` fixture record.
    public func moveToTrash(_ record: MeetingRecord) {
        guard let storage else { return }
        guard (try? storage.trash(record)) != nil else { return }
        meetings.removeAll { $0.meeting.id == record.meeting.id }
        if selectedMeetingID == record.meeting.id { selectedMeetingID = nil }
        if let index { try? index.remove(meetingID: record.meeting.id) }
        rebuildDisplayMeetings()
        changeBus?.post(.meetingDeleted(record.meeting.id))
    }

    /// Fixture-only path for `rename` — mirrors `replace` minus disk I/O.
    private func replaceInMemoryOnly(_ record: MeetingRecord) {
        var record = record
        record.meeting.updatedAt = .now
        if let i = meetings.firstIndex(where: { $0.meeting.id == record.meeting.id }) {
            meetings[i] = record
        }
        updateDisplayElement(record)
    }

    /// "~/Recap"-style label for the status bar.
    public var saveLocationLabel: String {
        guard let storage else { return "~/Recap" }
        let path = storage.rootURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    public var readyCount: Int {
        meetings.filter { $0.meeting.status == .ready }.count
    }
}
