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

    /// Timed notes pinned to offsets into this meeting's timeline. Cached
    /// after the first disk read (see `timedNotesCache`); fixture mode reads
    /// straight from `fixtureTimedNotes`.
    public func timedNotes(for record: MeetingRecord) -> [TimedNote] {
        guard let storage else { return fixtureTimedNotes[record.meeting.id] ?? [] }
        if let cached = timedNotesCache[record.meeting.id] { return cached }
        let loaded = (try? storage.loadTimedNotes(in: record)) ?? []
        timedNotesCache[record.meeting.id] = loaded
        return loaded
    }

    /// Appends a new timed note and persists it — the "pin a note to right
    /// now" action during a live recording. Fixture mode (no `storage`)
    /// appends in-memory only, mirroring `rename`'s fixture fallback.
    public func addTimedNote(_ text: String, at offset: TimeInterval, in record: MeetingRecord) {
        let note = TimedNote(offset: offset, text: text)
        guard let storage else {
            fixtureTimedNotes[record.meeting.id, default: []].append(note)
            return
        }
        var notes = timedNotes(for: record)
        notes.append(note)
        timedNotesCache[record.meeting.id] = notes
        try? storage.saveTimedNotes(notes, in: record)
        changeBus?.post(.meetingChanged(record.meeting.id))
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
