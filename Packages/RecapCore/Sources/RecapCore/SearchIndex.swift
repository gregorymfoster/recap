import Foundation
import GRDB
import os

private let searchIndexLog = Logger(subsystem: "com.gregfoster.recap", category: "SearchIndex")

public struct SearchHit: Equatable, Sendable, Identifiable {
    public var meetingID: UUID
    public var title: String
    public var snippet: String

    public init(meetingID: UUID, title: String, snippet: String) {
        self.meetingID = meetingID
        self.title = title
        self.snippet = snippet
    }

    public var id: UUID { meetingID }
}

/// SQLite index over the meeting library, used for the meeting list and ⌘K
/// full-text search. Disposable by design: `reindex(records:storage:)` rebuilds
/// it entirely from the given records, so external edits (or a deleted
/// database) heal on the next launch.
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
        defaultDatabaseURL(isDevBuild: AppIdentity.isDevBuild)
    }

    /// Opens the on-disk index at `databaseURL`, recovering from a corrupt or
    /// otherwise unreadable database instead of crashing at launch: a failed
    /// open deletes the file and retries once — `reindex(from:)` rebuilds
    /// everything from the folder tree anyway, so losing the file costs
    /// nothing but a rebuild — and a second failure falls back to an
    /// in-memory index so the app can still launch, just without a persisted
    /// index for this run.
    public static func openOrRecover(databaseURL: URL) -> SearchIndex {
        if let index = try? SearchIndex(databaseURL: databaseURL) {
            return index
        }
        searchIndexLog.error("failed to open search index at \(databaseURL.path, privacy: .public); deleting and retrying")
        try? FileManager.default.removeItem(at: databaseURL)
        if let index = try? SearchIndex(databaseURL: databaseURL) {
            searchIndexLog.info("recovered search index after deleting corrupt database")
            return index
        }
        searchIndexLog.fault("search index recovery failed; falling back to an in-memory index")
        return openInMemoryOrRecover()
    }

    /// In-memory index that never throws in practice — the last-resort
    /// fallback when the on-disk index can't be opened even after deleting
    /// it. Still logs loudly (rather than silently swallowing) if GRDB's
    /// in-memory database construction itself somehow fails, since at that
    /// point there's nothing left to recover from.
    public static func openInMemoryOrRecover() -> SearchIndex {
        if let index = try? SearchIndex() {
            return index
        }
        searchIndexLog.fault("in-memory search index construction failed")
        return try! SearchIndex()
    }

    /// Pure, testable core: dev builds get their own `Recap Dev/index.db` so a
    /// prod install and a dev build never share a search index.
    static func defaultDatabaseURL(isDevBuild: Bool) -> URL {
        let folderName = isDevBuild ? "Recap Dev" : "Recap"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(folderName)/index.db")
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

    /// Drops everything and rebuilds from the given records — the caller
    /// (`LibraryStore.reload()`) already loaded them via `storage.loadAll()`,
    /// so this no longer re-walks the folder tree itself (that used to mean
    /// every launch paid for `loadAll()` twice: once for `LibraryStore`,
    /// once again inside this method).
    public func reindex(records: [MeetingRecord], storage: LibraryStorage) throws {
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

    /// Drops a single meeting's rows from both the metadata and FTS tables —
    /// used when a meeting is trashed, so it stops appearing in search
    /// immediately instead of waiting for the next full `reindex(from:)`.
    public func remove(meetingID: UUID) throws {
        try dbQueue.write { db in
            let id = meetingID.uuidString
            try db.execute(sql: "DELETE FROM meeting WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM meeting_fts WHERE meetingID = ?", arguments: [id])
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
