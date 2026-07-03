import Foundation
import os

private let storageLog = Logger(subsystem: "com.gregfoster.recap", category: "LibraryStorage")

/// A meeting together with its on-disk folder.
public struct MeetingRecord: Equatable, Sendable, Identifiable {
    public var meeting: Meeting
    public var folderURL: URL

    public init(meeting: Meeting, folderURL: URL) {
        self.meeting = meeting
        self.folderURL = folderURL
    }

    public var id: UUID { meeting.id }

    public var audioURL: URL { folderURL.appendingPathComponent("audio.m4a") }
    public var notesURL: URL { folderURL.appendingPathComponent("notes.md") }
    public var enhancedURL: URL { folderURL.appendingPathComponent("enhanced.md") }
    public var transcriptURL: URL { folderURL.appendingPathComponent("transcript.json") }
    public var metadataURL: URL { folderURL.appendingPathComponent("meeting.json") }
    public var speakerNamesURL: URL { folderURL.appendingPathComponent("speakers.json") }
}

/// Reads and writes the user-visible meeting library on disk.
///
/// The folder tree is the source of truth — plain Markdown, JSON, and audio files
/// the user can open with anything. One folder per meeting under `rootURL`
/// (default `~/Recap`), named "YYYY-MM-DD Title". Folder names are fixed at
/// creation; the canonical title lives in `meeting.json`.
public struct LibraryStorage: Sendable {
    public var rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    public static var defaultRootURL: URL {
        defaultRootURL(isDevBuild: AppIdentity.isDevBuild)
    }

    /// Pure, testable core: dev builds get their own `~/Recap Dev` tree so a
    /// prod install and a dev build never share meeting data on disk.
    static func defaultRootURL(isDevBuild: Bool) -> URL {
        let folderName = isDevBuild ? "Recap Dev" : "Recap"
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(folderName)
    }

    // MARK: Meetings

    /// Creates the meeting folder and writes initial metadata + empty notes.
    public func create(_ meeting: Meeting) throws -> MeetingRecord {
        try logOnFailure("create") {
            let folderURL = try uniqueFolderURL(for: meeting)
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            let record = MeetingRecord(meeting: meeting, folderURL: folderURL)
            try Self.encoder.encode(record.meeting).write(to: record.metadataURL, options: .atomic)
            try Data().write(to: record.notesURL)
            return record
        }
    }

    /// Creates the folder for a meeting imported from an external audio file:
    /// status starts at `.queued` (there's nothing to record — the audio is
    /// materialized by the importer, then transcription runs). Reuses the
    /// same folder-uniquing as recorded meetings, so a same-day title
    /// collision gets a distinct " 2"-suffixed folder.
    public func createImportedMeeting(
        title: String, date: Date, duration: TimeInterval = 0
    ) throws -> MeetingRecord {
        try create(Meeting(title: title, date: date, duration: duration, status: .queued))
    }

    public func saveMetadata(_ record: MeetingRecord) throws {
        try logOnFailure("saveMetadata") {
            try Self.encoder.encode(record.meeting).write(to: record.metadataURL, options: .atomic)
        }
    }

    /// Renames a meeting's display title. Only `meeting.json` changes — the
    /// on-disk folder name is fixed at creation time, so existing exports
    /// (Obsidian, folder-mirror) that reference the folder path stay valid.
    public func rename(_ record: MeetingRecord, to title: String) throws -> MeetingRecord {
        var updated = record
        updated.meeting.title = title
        try saveMetadata(updated)
        return updated
    }

    /// Moves a meeting's folder to the Trash (recoverable — Finder's Trash,
    /// not a permanent delete), via `FileManager.trashItem`.
    public func trash(_ record: MeetingRecord) throws {
        try logOnFailure("trash") {
            try FileManager.default.trashItem(at: record.folderURL, resultingItemURL: nil)
        }
    }

    /// Loads every meeting folder under the root. Folders without a readable
    /// `meeting.json` are skipped (never deleted); the skip count is logged
    /// so a bad folder doesn't silently vanish from view.
    public func loadAll() throws -> [MeetingRecord] {
        try logOnFailure("loadAll") {
            let fm = FileManager.default
            guard fm.fileExists(atPath: rootURL.path) else { return [] }
            let folders = try fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey])
            var skipped = 0
            let records = folders.compactMap { folderURL -> MeetingRecord? in
                guard (try? folderURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
                let metadataURL = folderURL.appendingPathComponent("meeting.json")
                guard let data = try? Data(contentsOf: metadataURL),
                      let meeting = try? Self.decoder.decode(Meeting.self, from: data)
                else {
                    skipped += 1
                    return nil
                }
                return MeetingRecord(meeting: meeting, folderURL: folderURL)
            }
            .sorted { $0.meeting.date > $1.meeting.date }
            if skipped > 0 {
                storageLog.error("loadAll skipped \(skipped, privacy: .public) folder(s) with unreadable metadata")
            }
            return records
        }
    }

    // MARK: Content files

    public func saveNotes(_ notes: String, in record: MeetingRecord) throws {
        try logOnFailure("saveNotes") {
            try Data(notes.utf8).write(to: record.notesURL, options: .atomic)
        }
    }

    public func loadNotes(in record: MeetingRecord) throws -> String {
        try logOnFailure("loadNotes") {
            try String(contentsOf: record.notesURL, encoding: .utf8)
        }
    }

    public func saveEnhancedNotes(_ notes: String, in record: MeetingRecord) throws {
        try logOnFailure("saveEnhancedNotes") {
            try Data(notes.utf8).write(to: record.enhancedURL, options: .atomic)
        }
    }

    public func loadEnhancedNotes(in record: MeetingRecord) throws -> String? {
        guard FileManager.default.fileExists(atPath: record.enhancedURL.path) else { return nil }
        return try logOnFailure("loadEnhancedNotes") {
            try String(contentsOf: record.enhancedURL, encoding: .utf8)
        }
    }

    public func saveTranscript(_ transcript: Transcript, in record: MeetingRecord) throws {
        try logOnFailure("saveTranscript") {
            try Self.encoder.encode(transcript).write(to: record.transcriptURL, options: .atomic)
        }
    }

    public func loadTranscript(in record: MeetingRecord) throws -> Transcript? {
        guard FileManager.default.fileExists(atPath: record.transcriptURL.path) else { return nil }
        return try logOnFailure("loadTranscript") {
            try Self.decoder.decode(Transcript.self, from: Data(contentsOf: record.transcriptURL))
        }
    }

    /// Per-meeting speaker renames (design handoff v2 §8e). Scope is
    /// intentionally per-meeting only — no cross-meeting voice-print identity.
    public func saveSpeakerNames(_ speakerNames: SpeakerNames, in record: MeetingRecord) throws {
        try logOnFailure("saveSpeakerNames") {
            try Self.encoder.encode(speakerNames).write(to: record.speakerNamesURL, options: .atomic)
        }
    }

    /// Empty mapping when `speakers.json` doesn't exist yet — every speaker
    /// still unnamed is the common case, not an error.
    public func loadSpeakerNames(in record: MeetingRecord) throws -> SpeakerNames {
        guard FileManager.default.fileExists(atPath: record.speakerNamesURL.path) else { return SpeakerNames() }
        return try logOnFailure("loadSpeakerNames") {
            try Self.decoder.decode(SpeakerNames.self, from: Data(contentsOf: record.speakerNamesURL))
        }
    }

    /// Runs `body`, logging (error level, no file contents) and rethrowing on
    /// failure. `operation` and the underlying error are the only dynamic
    /// content — never meeting titles/notes/transcript text.
    private func logOnFailure<T>(_ operation: StaticString, _ body: () throws -> T) rethrows -> T {
        do {
            return try body()
        } catch {
            storageLog.error("\(operation) failed: \(String(describing: error), privacy: .private)")
            throw error
        }
    }

    // MARK: Folder naming

    private func uniqueFolderURL(for meeting: Meeting) throws -> URL {
        let base = Self.folderName(for: meeting)
        var candidate = rootURL.appendingPathComponent(base)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = rootURL.appendingPathComponent("\(base) \(counter)")
            counter += 1
        }
        return candidate
    }

    static func folderName(for meeting: Meeting) -> String {
        let day = meeting.date.formatted(
            Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
        )
        let unsafe = CharacterSet(charactersIn: "/:\\")
        let title = meeting.title
            .components(separatedBy: unsafe)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(day) \(title.isEmpty ? "Untitled meeting" : title)"
    }

    // MARK: Coding

    /// Human-readable JSON — users may open these files directly.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
