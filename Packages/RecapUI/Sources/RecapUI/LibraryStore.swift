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

@MainActor
@Observable
public final class LibraryStore {
    public private(set) var meetings: [MeetingRecord] = []
    public var selectedMeetingID: UUID?
    public var queueSummary: QueueSummary?

    private let storage: LibraryStorage?
    private let index: SearchIndex?
    private let autosaver: NotesAutosaver?

    /// Disk-backed store: loads the library and rebuilds the search index.
    public init(storage: LibraryStorage, index: SearchIndex) {
        self.storage = storage
        self.index = index
        self.autosaver = NotesAutosaver(storage: storage)
        reload()
    }

    /// Fixture store for previews and early UI work.
    public init(fixtures: [MeetingRecord], queueSummary: QueueSummary? = nil) {
        self.storage = nil
        self.index = nil
        self.autosaver = nil
        self.meetings = fixtures
        self.queueSummary = queueSummary
    }

    public func reload() {
        guard let storage, let index else { return }
        meetings = (try? storage.loadAll()) ?? []
        try? index.reindex(from: storage)
    }

    /// Creates a new meeting on disk and selects it.
    @discardableResult
    public func startNewMeeting() -> MeetingRecord? {
        let meeting = Meeting(title: "Untitled meeting", date: .now, status: .recording)
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

    private func replace(_ record: MeetingRecord) {
        if let i = meetings.firstIndex(where: { $0.meeting.id == record.meeting.id }) {
            meetings[i] = record
        }
        guard let storage else { return }
        try? storage.saveMetadata(record)
        if let index { try? index.update(record, from: storage) }
    }

    public func record(for id: UUID) -> MeetingRecord? {
        meetings.first { $0.meeting.id == id }
    }

    // MARK: Notes & transcript

    public func loadNotes(for record: MeetingRecord) -> String {
        guard let storage else { return "" }
        return (try? storage.loadNotes(in: record)) ?? ""
    }

    public func loadTranscript(for record: MeetingRecord) -> Transcript? {
        guard let storage else { return nil }
        return try? storage.loadTranscript(in: record)
    }

    public func loadEnhancedNotes(for record: MeetingRecord) -> String? {
        guard let storage else { return nil }
        return (try? storage.loadEnhancedNotes(in: record)) ?? nil
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
        Task {
            await autosaver.flush()
            try? index.update(record, from: storage)
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
    /// Sample library matching the states in design mock 1c.
    public static func fixture() -> LibraryStore {
        let now = Date.now
        func record(_ title: String, hoursAgo: Double, duration: TimeInterval, attendees: [String], status: MeetingStatus) -> MeetingRecord {
            MeetingRecord(
                meeting: Meeting(
                    title: title, date: now.addingTimeInterval(-hoursAgo * 3600),
                    duration: duration, attendees: attendees, status: status
                ),
                folderURL: URL(filePath: "/dev/null")
            )
        }
        return LibraryStore(
            fixtures: [
                record("Design sync — Q3 roadmap", hoursAgo: 0.5, duration: 1_453, attendees: ["Maya", "Sam", "Priya"], status: .transcribing(progress: 0.42)),
                record("Customer call — Meridian", hoursAgo: 3, duration: 1_800, attendees: ["Alex"], status: .queued),
                record("Weekly standup", hoursAgo: 6, duration: 900, attendees: ["Maya", "Sam"], status: .ready),
                record("1:1 with Sam", hoursAgo: 26, duration: 1_680, attendees: ["Sam"], status: .ready),
                record("Pricing brainstorm", hoursAgo: 30, duration: 2_400, attendees: ["Maya", "Alex", "Priya"], status: .ready),
            ],
            queueSummary: QueueSummary(jobCount: 2, progress: 0.42)
        )
    }
}
