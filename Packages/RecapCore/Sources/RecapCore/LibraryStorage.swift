import Foundation

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
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Recap")
    }

    // MARK: Meetings

    /// Creates the meeting folder and writes initial metadata + empty notes.
    public func create(_ meeting: Meeting) throws -> MeetingRecord {
        let folderURL = try uniqueFolderURL(for: meeting)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let record = MeetingRecord(meeting: meeting, folderURL: folderURL)
        try saveMetadata(record)
        try Data().write(to: record.notesURL)
        return record
    }

    public func saveMetadata(_ record: MeetingRecord) throws {
        try Self.encoder.encode(record.meeting).write(to: record.metadataURL, options: .atomic)
    }

    /// Loads every meeting folder under the root. Folders without a readable
    /// `meeting.json` are skipped (never deleted).
    public func loadAll() throws -> [MeetingRecord] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: rootURL.path) else { return [] }
        let folders = try fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey])
        return folders.compactMap { folderURL in
            guard (try? folderURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let metadataURL = folderURL.appendingPathComponent("meeting.json")
            guard let data = try? Data(contentsOf: metadataURL),
                  let meeting = try? Self.decoder.decode(Meeting.self, from: data)
            else { return nil }
            return MeetingRecord(meeting: meeting, folderURL: folderURL)
        }
        .sorted { $0.meeting.date > $1.meeting.date }
    }

    // MARK: Content files

    public func saveNotes(_ notes: String, in record: MeetingRecord) throws {
        try Data(notes.utf8).write(to: record.notesURL, options: .atomic)
    }

    public func loadNotes(in record: MeetingRecord) throws -> String {
        try String(contentsOf: record.notesURL, encoding: .utf8)
    }

    public func saveEnhancedNotes(_ notes: String, in record: MeetingRecord) throws {
        try Data(notes.utf8).write(to: record.enhancedURL, options: .atomic)
    }

    public func loadEnhancedNotes(in record: MeetingRecord) throws -> String? {
        guard FileManager.default.fileExists(atPath: record.enhancedURL.path) else { return nil }
        return try String(contentsOf: record.enhancedURL, encoding: .utf8)
    }

    public func saveTranscript(_ transcript: Transcript, in record: MeetingRecord) throws {
        try Self.encoder.encode(transcript).write(to: record.transcriptURL, options: .atomic)
    }

    public func loadTranscript(in record: MeetingRecord) throws -> Transcript? {
        guard FileManager.default.fileExists(atPath: record.transcriptURL.path) else { return nil }
        return try Self.decoder.decode(Transcript.self, from: Data(contentsOf: record.transcriptURL))
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
