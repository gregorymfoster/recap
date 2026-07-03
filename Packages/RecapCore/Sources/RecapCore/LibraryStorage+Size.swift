import Foundation

/// Aggregate on-disk footprint of the library, for the Settings "Storage" section.
public struct LibrarySizeSummary: Sendable, Equatable {
    public struct Entry: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var title: String
        public var bytes: Int64

        public init(id: UUID, title: String, bytes: Int64) {
            self.id = id
            self.title = title
            self.bytes = bytes
        }
    }

    public let totalBytes: Int64
    public let largest: [Entry]

    public init(totalBytes: Int64, largest: [Entry]) {
        self.totalBytes = totalBytes
        self.largest = largest
    }
}

extension LibraryStorage {
    /// Walks each meeting's folder on disk and totals its size. Blocking —
    /// this does synchronous `FileManager` enumeration, so call it off the
    /// main actor (e.g. from a detached `Task.detached(priority: .utility)`);
    /// never call it directly from a SwiftUI view body or `@MainActor` code.
    ///
    /// Takes `records` as a parameter (rather than re-reading `loadAll()`)
    /// so callers that already have the library loaded skip a redundant
    /// decode pass.
    public func sizeSummary(for records: [MeetingRecord], topCount: Int = 5) throws -> LibrarySizeSummary {
        let fm = FileManager.default
        var total: Int64 = 0
        var entries: [LibrarySizeSummary.Entry] = []
        entries.reserveCapacity(records.count)

        for record in records {
            let bytes = Self.folderSize(at: record.folderURL, fileManager: fm)
            total += bytes
            entries.append(LibrarySizeSummary.Entry(id: record.id, title: record.meeting.title, bytes: bytes))
        }

        let largest = entries
            .sorted { $0.bytes > $1.bytes }
            .prefix(topCount)
        return LibrarySizeSummary(totalBytes: total, largest: Array(largest))
    }

    /// Sums file sizes under `url`. Uses logical size (`.fileSizeKey`) rather
    /// than allocated size: allocated size varies with the filesystem's block
    /// size and compression (APFS can allocate more or less than the logical
    /// byte count), which would make both this display and its tests
    /// non-deterministic. Logical size is close enough for a Settings display
    /// and matches what `ls -l`/Finder's "size" (not "size on disk") show.
    private static func folderSize(at url: URL, fileManager: FileManager) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = fileManager.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }
            if let logical = values.fileSize {
                total += Int64(logical)
            } else if let allocated = values.totalFileAllocatedSize ?? values.fileAllocatedSize {
                total += Int64(allocated)
            }
        }
        return total
    }
}
