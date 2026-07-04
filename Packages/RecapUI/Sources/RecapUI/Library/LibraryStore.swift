import Foundation
import Observation
import RecapCore

/// Aggregate state of the background processing queue, for the sidebar widget.
public struct QueueSummary: Equatable, Sendable {
    public var jobCount: Int
    public var progress: Double
    public var pauseReason: String?

    public init(jobCount: Int, progress: Double, pauseReason: String? = nil) {
        self.jobCount = jobCount
        self.progress = progress
        self.pauseReason = pauseReason
    }
}

/// Library list ordering. Persisted to UserDefaults — the user's chosen sort
/// should survive a relaunch, unlike the filter (session-only).
public enum LibrarySort: String, CaseIterable, Sendable {
    case newest
    case oldest
    case longest

    var label: String {
        switch self {
        case .newest: "Newest first"
        case .oldest: "Oldest first"
        case .longest: "Longest first"
        }
    }
}

/// Metadata-only narrowing of the library list — no disk I/O, so it's cheap
/// to recompute on every keystroke/toggle. Session-only (not persisted): a
/// fresh launch always shows everything until the user filters again.
public struct LibraryFilter: Equatable, Sendable {
    public var minDuration: TimeInterval?
    public var readyOnly: Bool

    public init(minDuration: TimeInterval? = nil, readyOnly: Bool = false) {
        self.minDuration = minDuration
        self.readyOnly = readyOnly
    }

    public var isActive: Bool { minDuration != nil || readyOnly }

    func matches(_ record: MeetingRecord) -> Bool {
        if let minDuration, record.meeting.duration < minDuration { return false }
        if readyOnly, record.meeting.status != .ready { return false }
        return true
    }
}

@MainActor
@Observable
public final class LibraryStore {
    public private(set) var meetings: [MeetingRecord] = []
    public var selectedMeetingID: UUID?
    public var queueSummary: QueueSummary?

    public var sort: LibrarySort {
        didSet { defaults?.set(sort.rawValue, forKey: Self.sortKey) }
    }
    public var filter = LibraryFilter()

    private let storage: LibraryStorage?
    private let index: SearchIndex?
    private let autosaver: NotesAutosaver?
    private let changeBus: LibraryChangeBus?
    private let defaults: UserDefaults?
    /// Canned transcripts for fixture records (no disk in fixture mode), so
    /// -fixtures runs and screenshot dumps can show the transcript pane —
    /// avatars, rename affordance, playback follow. Empty in disk-backed mode.
    private var fixtureTranscripts: [UUID: Transcript] = [:]
    /// Canned raw notes for fixture records, mirroring `fixtureTranscripts`.
    /// Empty in disk-backed mode.
    private var fixtureNotes: [UUID: String] = [:]
    /// Canned enhanced notes for fixture records, mirroring
    /// `fixtureTranscripts`. Empty in disk-backed mode.
    private var fixtureEnhancedNotes: [UUID: String] = [:]

    private static let sortKey = "librarySort"

    /// Disk-backed store: loads the library and rebuilds the search index.
    public init(storage: LibraryStorage, index: SearchIndex, changeBus: LibraryChangeBus, defaults: UserDefaults = .standard) {
        self.storage = storage
        self.index = index
        self.autosaver = NotesAutosaver(storage: storage)
        self.changeBus = changeBus
        self.defaults = defaults
        self.sort = defaults.string(forKey: Self.sortKey).flatMap(LibrarySort.init(rawValue:)) ?? .newest
        reload()
    }

    /// Fixture store for previews and early UI work.
    public init(
        fixtures: [MeetingRecord], queueSummary: QueueSummary? = nil,
        transcripts: [UUID: Transcript] = [:],
        notes: [UUID: String] = [:],
        enhancedNotes: [UUID: String] = [:]
    ) {
        self.storage = nil
        self.index = nil
        self.autosaver = nil
        self.changeBus = nil
        self.defaults = nil
        self.sort = .newest
        self.meetings = fixtures
        self.queueSummary = queueSummary
        self.fixtureTranscripts = transcripts
        self.fixtureNotes = notes
        self.fixtureEnhancedNotes = enhancedNotes
    }

    /// `meetings` filtered then sorted — the source of truth (`meetings`,
    /// newest-first from disk) never changes. Recomputed on demand; cheap
    /// since it's metadata-only.
    public var displayMeetings: [MeetingRecord] {
        let filtered = filter.isActive ? meetings.filter(filter.matches) : meetings
        switch sort {
        case .newest:
            return filtered.sorted { $0.meeting.date > $1.meeting.date }
        case .oldest:
            return filtered.sorted { $0.meeting.date < $1.meeting.date }
        case .longest:
            return filtered.sorted { $0.meeting.duration > $1.meeting.duration }
        }
    }

    public func reload() {
        guard let storage, let index else { return }
        meetings = (try? storage.loadAll()) ?? []
        try? index.reindex(from: storage)
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
            return record
        }
        guard let record = try? storage.create(meeting) else { return nil }
        meetings.insert(record, at: 0)
        selectedMeetingID = meeting.id
        if let index { try? index.update(record, from: storage) }
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
        record.meeting.status = status
        if case .transcribing = status, case .transcribing = previous {
            if let i = meetings.firstIndex(where: { $0.meeting.id == id }) {
                meetings[i] = record
            }
        } else {
            replace(record)
        }
    }

    /// Records a successful folder-mirror backup, persisting through the
    /// same metadata save path as every other meeting mutation.
    public func markBackedUp(_ id: UUID, at date: Date = .now) {
        guard var record = record(for: id) else { return }
        record.meeting.lastBackupDate = date
        replace(record)
    }

    /// Used by crash salvage: the recovered file is the only duration source.
    public func updateDuration(_ id: UUID, to duration: TimeInterval) {
        guard var record = record(for: id) else { return }
        record.meeting.duration = duration
        replace(record)
    }

    /// Persists the user's explicit Enhanced/My notes choice (design handoff
    /// v2 §8c) through the same metadata save path as every other mutation.
    public func setPreferredNotesView(_ preference: NotesViewPreference?, for id: UUID) {
        guard var record = record(for: id) else { return }
        record.meeting.preferredNotesView = preference
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
        if let index { try? index.reindex(from: storage) }
        changeBus?.post(.meetingChanged(record.meeting.id))
    }

    /// Fixture-only path for `rename` — mirrors `replace` minus disk I/O.
    private func replaceInMemoryOnly(_ record: MeetingRecord) {
        var record = record
        record.meeting.updatedAt = .now
        if let i = meetings.firstIndex(where: { $0.meeting.id == record.meeting.id }) {
            meetings[i] = record
        }
    }

    // MARK: Notes & transcript

    public func loadNotes(for record: MeetingRecord) -> String {
        guard let storage else { return fixtureNotes[record.meeting.id] ?? "" }
        return (try? storage.loadNotes(in: record)) ?? ""
    }

    public func loadTranscript(for record: MeetingRecord) -> Transcript? {
        guard let storage else { return fixtureTranscripts[record.meeting.id] }
        return try? storage.loadTranscript(in: record)
    }

    public func loadEnhancedNotes(for record: MeetingRecord) -> String? {
        guard let storage else { return fixtureEnhancedNotes[record.meeting.id] }
        return (try? storage.loadEnhancedNotes(in: record)) ?? nil
    }

    /// Per-meeting speaker renames (design handoff v2 §8e). Fixture mode (no
    /// `storage`) returns an empty mapping — previews just show "Speaker N".
    public func loadSpeakerNames(for record: MeetingRecord) -> [String: String] {
        guard let storage else { return [:] }
        return ((try? storage.loadSpeakerNames(in: record)) ?? SpeakerNames()).names
    }

    /// Renames one diarized speaker within a single meeting and persists it to
    /// `speakers.json`, then posts a change-bus event so any open view (this
    /// meeting's detail view, an export watcher) refreshes. No-ops in fixture
    /// mode — there's no real folder to persist into for a `/dev/null` record.
    public func renameSpeaker(_ speakerID: String, to name: String, in record: MeetingRecord) {
        guard let storage else { return }
        var speakerNames = (try? storage.loadSpeakerNames(in: record)) ?? SpeakerNames()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        speakerNames[speakerID] = trimmed.isEmpty ? nil : trimmed
        guard (try? storage.saveSpeakerNames(speakerNames, in: record)) != nil else { return }
        changeBus?.post(.meetingChanged(record.meeting.id))
    }

    /// "~/Recap"-style label for the status bar.
    public var saveLocationLabel: String {
        guard let storage else { return "~/Recap" }
        let path = storage.rootURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Called on every keystroke; the autosaver debounces the disk write.
    public func notesChanged(_ notes: String, in record: MeetingRecord) {
        guard let autosaver else { return }
        Task { await autosaver.noteDidChange(notes, in: record) }
    }

    /// Writes pending notes and refreshes the search index (call on blur/quit).
    public func flushNotes(for record: MeetingRecord) {
        guard let autosaver, let storage, let index else { return }
        let changeBus = changeBus
        Task {
            await autosaver.flush()
            try? index.update(record, from: storage)
            changeBus?.post(.meetingChanged(record.meeting.id))
        }
    }

    public var readyCount: Int {
        meetings.filter { $0.meeting.status == .ready }.count
    }

    /// Full-text search over titles, notes, enhanced notes, and transcripts.
    public func search(_ query: String) -> [SearchHit] {
        guard let index else {
            // Fixture mode: filter titles so the overlay is previewable.
            return meetings
                .filter { $0.meeting.title.localizedCaseInsensitiveContains(query) }
                .map { SearchHit(meetingID: $0.meeting.id, title: $0.meeting.title, snippet: "") }
        }
        return (try? index.search(query)) ?? []
    }
}

// MARK: - Fixtures

extension LibraryStore {
    /// Sample library matching the states in design mock 1c. Equivalent to
    /// `FixtureScenario.default.library` — kept as a standalone entry point
    /// since it's the one every preview/test in this package already calls.
    /// See `FixtureScenarios.swift` for this and every other named
    /// `-fixtures <scenario>` graph.
    public static func fixture() -> LibraryStore {
        FixtureScenarios.defaultLibrary()
    }
}
