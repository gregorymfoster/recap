import Foundation
import GRDB

public struct SearchHit: Equatable, Sendable, Identifiable {
    public var meetingID: UUID
    public var title: String
    public var snippet: String

    public var id: UUID { meetingID }
}

/// SQLite index over the meeting library, used for the meeting list and ⌘K
/// full-text search. Disposable by design: `reindex(from:)` rebuilds it entirely
/// from the folders on disk, so external edits (or a deleted database) heal on
/// the next launch.
public final class SearchIndex: Sendable {
    private let dbQueue: DatabaseQueue

    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        dbQueue = try DatabaseQueue(path: databaseURL.path)
        try migrator.migrate(dbQueue)
    }

    /// In-memory index, for tests and previews.
    public init() throws {
        dbQueue = try DatabaseQueue()
        try migrator.migrate(dbQueue)
    }

    public static var defaultDatabaseURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recap/index.db")
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "meeting") { t in
                t.primaryKey("id", .text)
                t.column("folder", .text).notNull()
                t.column("title", .text).notNull()
                t.column("date", .datetime).notNull()
                t.column("duration", .double).notNull()
            }
            try db.create(virtualTable: "meeting_fts", using: FTS5()) { t in
                t.column("meetingID").notIndexed()
                t.column("title")
                t.column("notes")
                t.column("enhanced")
                t.column("transcript")
                t.tokenizer = .porter(wrapping: .unicode61())
            }
        }
        return migrator
    }

    // MARK: Indexing

    /// Drops everything and rebuilds from the library on disk.
    public func reindex(from storage: LibraryStorage) throws {
        let records = try storage.loadAll()
        let entries = records.map { record in
            IndexEntry(
                record: record,
                notes: (try? storage.loadNotes(in: record)) ?? "",
                enhanced: (try? storage.loadEnhancedNotes(in: record)) ?? "",
                transcript: (try? storage.loadTranscript(in: record))?.fullText ?? ""
            )
        }
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM meeting")
            try db.execute(sql: "DELETE FROM meeting_fts")
            for entry in entries {
                try Self.insert(entry, in: db)
            }
        }
    }

    /// Refreshes a single meeting (called on save).
    public func update(_ record: MeetingRecord, from storage: LibraryStorage) throws {
        let entry = IndexEntry(
            record: record,
            notes: (try? storage.loadNotes(in: record)) ?? "",
            enhanced: (try? storage.loadEnhancedNotes(in: record)) ?? "",
            transcript: (try? storage.loadTranscript(in: record))?.fullText ?? ""
        )
        try dbQueue.write { db in
            let id = record.meeting.id.uuidString
            try db.execute(sql: "DELETE FROM meeting WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM meeting_fts WHERE meetingID = ?", arguments: [id])
            try Self.insert(entry, in: db)
        }
    }

    private struct IndexEntry {
        var record: MeetingRecord
        var notes: String
        var enhanced: String
        var transcript: String
    }

    private static func insert(_ entry: IndexEntry, in db: Database) throws {
        let meeting = entry.record.meeting
        try db.execute(
            sql: "INSERT INTO meeting (id, folder, title, date, duration) VALUES (?, ?, ?, ?, ?)",
            arguments: [
                meeting.id.uuidString, entry.record.folderURL.lastPathComponent,
                meeting.title, meeting.date, meeting.duration,
            ]
        )
        try db.execute(
            sql: """
                INSERT INTO meeting_fts (meetingID, title, notes, enhanced, transcript)
                VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [meeting.id.uuidString, meeting.title, entry.notes, entry.enhanced, entry.transcript]
        )
    }

    // MARK: Search

    public func search(_ query: String) throws -> [SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT meetingID, title,
                           snippet(meeting_fts, -1, '', '', '…', 12) AS snippet
                    FROM meeting_fts
                    WHERE meeting_fts MATCH ?
                    ORDER BY rank
                    LIMIT 50
                    """,
                arguments: [FTS5Pattern(matchingAllPrefixesIn: trimmed)]
            )
            return rows.compactMap { row in
                guard let id = UUID(uuidString: row["meetingID"]) else { return nil }
                return SearchHit(meetingID: id, title: row["title"], snippet: row["snippet"])
            }
        }
    }

    public func indexedMeetingCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meeting") ?? 0
        }
    }
}
