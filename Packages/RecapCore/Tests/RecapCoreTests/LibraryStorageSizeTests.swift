import Foundation
import Testing
@testable import RecapCore

@Suite struct LibraryStorageSizeTests {
    func makeStorage() -> LibraryStorage {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecapSizeTests-\(UUID().uuidString)")
        return LibraryStorage(rootURL: root)
    }

    func writeFile(_ bytes: Int, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: bytes).write(to: url)
    }

    /// Builds a bare meeting record backed by a folder with no files in it —
    /// unlike `LibraryStorage.create`, which also writes `meeting.json` and
    /// an empty `notes.md`. Keeping the folder empty until the test writes
    /// its own known-size files makes the total/ordering assertions exact.
    func bareRecord(_ storage: LibraryStorage, title: String, date: Date) throws -> MeetingRecord {
        let folderURL = storage.rootURL.appendingPathComponent(title)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        return MeetingRecord(meeting: Meeting(title: title, date: date), folderURL: folderURL)
    }

    @Test func totalsAndOrdersTopMeetingsByKnownByteSizes() throws {
        let storage = makeStorage()
        let a = try bareRecord(storage, title: "Small", date: .now)
        let b = try bareRecord(storage, title: "Big", date: .now.addingTimeInterval(1))

        try writeFile(1_000, at: a.audioURL)
        try writeFile(500, at: a.notesURL)
        try writeFile(50_000, at: b.audioURL)

        let summary = try storage.sizeSummary(for: [a, b])
        #expect(summary.totalBytes == 1_000 + 500 + 50_000)
        #expect(summary.largest.first?.title == "Big")
        #expect(summary.largest.first?.bytes == 50_000)
        #expect(summary.largest.count == 2)
    }

    @Test func topCountLimitsTheLargestList() throws {
        let storage = makeStorage()
        var records: [MeetingRecord] = []
        for i in 0..<8 {
            let record = try bareRecord(storage, title: "M\(i)", date: .now.addingTimeInterval(Double(i)))
            try writeFile(i * 100, at: record.audioURL)
            records.append(record)
        }

        let summary = try storage.sizeSummary(for: records, topCount: 3)
        #expect(summary.largest.count == 3)
        #expect(summary.largest.map(\.title) == ["M7", "M6", "M5"])
    }

    @Test func emptyRecordsProducesZeroTotal() throws {
        let storage = makeStorage()
        let summary = try storage.sizeSummary(for: [])
        #expect(summary.totalBytes == 0)
        #expect(summary.largest.isEmpty)
    }

    @Test func missingFolderContributesZeroRatherThanThrowing() throws {
        let storage = makeStorage()
        let ghost = MeetingRecord(
            meeting: Meeting(title: "Ghost", date: .now),
            folderURL: storage.rootURL.appendingPathComponent("does-not-exist")
        )
        let summary = try storage.sizeSummary(for: [ghost])
        #expect(summary.totalBytes == 0)
        #expect(summary.largest.first?.bytes == 0)
    }
}
