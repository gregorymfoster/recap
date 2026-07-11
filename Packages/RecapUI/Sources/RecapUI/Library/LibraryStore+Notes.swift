import Foundation
import RecapCore

/// Everything `MeetingDetailView` needs to render a meeting, loaded (and, on
/// the disk-backed path, merged) in one shot off the main actor — see
/// `LibraryStore.loadDetailContent(for:)`. Bundling these together means
/// `TranscriptMerge.merged` never has to run inside a view body.
public struct MeetingDetailContent: Sendable {
    public var notes: String
    public var transcript: Transcript?
    public var enhancedNotes: String?
    public var speakerNames: [String: String]
    public var timedNotes: [TimedNote]
    /// Pre-merged transcript+notes items so `TranscriptMerge` never runs in
    /// a view body.
    public var transcriptItems: [TranscriptMerge.Item]

    public init(
        notes: String, transcript: Transcript?, enhancedNotes: String?,
        speakerNames: [String: String], timedNotes: [TimedNote], transcriptItems: [TranscriptMerge.Item]
    ) {
        self.notes = notes
        self.transcript = transcript
        self.enhancedNotes = enhancedNotes
        self.speakerNames = speakerNames
        self.timedNotes = timedNotes
        self.transcriptItems = transcriptItems
    }
}

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

    /// Everything `MeetingDetailView` needs, loaded in one shot instead of
    /// five separate `LibraryStore` calls (each a synchronous disk read on
    /// the main actor) plus a `TranscriptMerge.merged` call in the view body.
    /// The disk-backed path does its file reads and the merge off the main
    /// actor; fixture mode has no disk to hop off of, so it stays on
    /// `MainActor` and reads straight from the fixture dictionaries.
    public func loadDetailContent(for record: MeetingRecord) async -> MeetingDetailContent {
        guard let storage else {
            let notes = fixtureNotes[record.meeting.id] ?? ""
            let transcript = fixtureTranscripts[record.meeting.id]
            let enhancedNotes = fixtureEnhancedNotes[record.meeting.id]
            let timedNotes = fixtureTimedNotes[record.meeting.id] ?? []
            // Fixture mode has no per-meeting speaker-name storage —
            // `loadSpeakerNames(for:)` returns an empty mapping too.
            let speakerNames: [String: String] = [:]
            let transcriptItems = TranscriptMerge.merged(utterances: transcript?.utterances ?? [], notes: timedNotes)
            return MeetingDetailContent(
                notes: notes, transcript: transcript, enhancedNotes: enhancedNotes,
                speakerNames: speakerNames, timedNotes: timedNotes, transcriptItems: transcriptItems
            )
        }
        // Reuse an already-cached disk read of timed notes (kept in sync by
        // `addTimedNote`) instead of re-reading `notes.json` off-main.
        let cachedTimedNotes = timedNotesCache[record.meeting.id]
        let content = await Self.loadDetailContentFromDisk(
            record: record, storage: storage, cachedTimedNotes: cachedTimedNotes
        )
        // Prime/refresh the cache exactly like `timedNotes(for:)` does, so a
        // later `addTimedNote` call still sees a consistent starting point.
        timedNotesCache[record.meeting.id] = content.timedNotes
        return content
    }

    /// Runs off the main actor (this is `nonisolated`, so awaiting it from a
    /// `@MainActor` method hops execution to the background before touching
    /// the filesystem/decoding JSON): the four disk reads
    /// `MeetingDetailView` used to make one at a time, plus the
    /// `TranscriptMerge.merged` interleave.
    private nonisolated static func loadDetailContentFromDisk(
        record: MeetingRecord, storage: LibraryStorage, cachedTimedNotes: [TimedNote]?
    ) async -> MeetingDetailContent {
        let notes = (try? storage.loadNotes(in: record)) ?? ""
        let transcript = try? storage.loadTranscript(in: record)
        let enhancedNotes = (try? storage.loadEnhancedNotes(in: record)) ?? nil
        let speakerNames = ((try? storage.loadSpeakerNames(in: record)) ?? SpeakerNames()).names
        let timedNotes = cachedTimedNotes ?? ((try? storage.loadTimedNotes(in: record)) ?? [])
        let transcriptItems = TranscriptMerge.merged(utterances: transcript?.utterances ?? [], notes: timedNotes)
        return MeetingDetailContent(
            notes: notes, transcript: transcript, enhancedNotes: enhancedNotes,
            speakerNames: speakerNames, timedNotes: timedNotes, transcriptItems: transcriptItems
        )
    }
}
