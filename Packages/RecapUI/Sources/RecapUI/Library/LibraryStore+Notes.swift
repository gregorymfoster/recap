import Foundation
import RecapCore

// MARK: Notes & transcript

extension LibraryStore {
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
}
