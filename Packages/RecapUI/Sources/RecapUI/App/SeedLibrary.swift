import Foundation
import OSLog

private let seedLog = Logger(subsystem: "com.gregfoster.recap", category: "SeedLibrary")

/// Prepares a throwaway, disk-backed copy of a `-seed-dir <path>` library so
/// `-seed-dir` launches can run the real storage stack (`LibraryStorage`,
/// `SearchIndex`, processing queue) against a reproducible snapshot without
/// ever writing to the source directory.
///
/// The source is expected to be a library folder in `LibraryStorage`'s
/// on-disk layout (one subfolder per meeting, each with `meeting.json`,
/// `notes.md`, etc. — see `RecapCore.MeetingRecord`), but `prepare` doesn't
/// validate that shape; an empty or malformed copy just yields an empty
/// library, which is still useful for reproducing "missing file" bugs.
public enum SeedLibrary {
    /// Copies `source` into a unique temp directory and returns the copy's
    /// URL, or `nil` if `source` doesn't exist or the copy fails — callers
    /// should fall back to normal (non-seeded) storage in that case rather
    /// than crash or silently operate on the real source.
    ///
    /// `fileManager` and `temporaryDirectory`/`uniqueSuffix` are injected so
    /// tests can exercise this without touching the real temp directory or
    /// depending on `UUID()` randomness.
    public static func prepare(
        source: URL,
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        uniqueSuffix: @autoclosure () -> String = UUID().uuidString
    ) -> URL? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            seedLog.error("seed-dir source missing or not a directory, falling back to normal storage")
            return nil
        }
        let destination = temporaryDirectory.appendingPathComponent("recap-seed-\(uniqueSuffix())")
        do {
            try fileManager.copyItem(at: source, to: destination)
            seedLog.info("seed-dir prepared temp copy")
            return destination
        } catch {
            seedLog.error("seed-dir copy failed: \(String(describing: error), privacy: .private), falling back to normal storage")
            return nil
        }
    }
}
