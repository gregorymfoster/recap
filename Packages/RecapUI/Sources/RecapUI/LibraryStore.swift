import Foundation
import Observation
import RecapCore

/// Aggregate state of the background processing queue, for the sidebar widget.
public struct QueueSummary: Equatable, Sendable {
    public var jobCount: Int
    public var progress: Double

    public init(jobCount: Int, progress: Double) {
        self.jobCount = jobCount
        self.progress = progress
    }
}

@MainActor
@Observable
public final class LibraryStore {
    public private(set) var meetings: [MeetingRecord] = []
    public var selectedMeetingID: UUID?
    public var queueSummary: QueueSummary?
    public var activeModelName = "Whisper Small · English"

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

    /// Creates a new meeting on disk and selects it. Audio capture attaches in M3.
    public func startNewMeeting() {
        let meeting = Meeting(title: "Untitled meeting", date: .now, status: .recording)
        guard let storage else {
            meetings.insert(MeetingRecord(meeting: meeting, folderURL: URL(filePath: "/dev/null")), at: 0)
            selectedMeetingID = meeting.id
            return
        }
        guard let record = try? storage.create(meeting) else { return }
        meetings.insert(record, at: 0)
        selectedMeetingID = meeting.id
        if let index { try? index.update(record, from: storage) }
    }

    public func record(for id: UUID) -> MeetingRecord? {
        meetings.first { $0.meeting.id == id }
    }

    // MARK: Notes

    public func loadNotes(for record: MeetingRecord) -> String {
        guard let storage else { return "" }
        return (try? storage.loadNotes(in: record)) ?? ""
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
