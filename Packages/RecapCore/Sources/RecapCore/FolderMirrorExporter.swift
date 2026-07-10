import Foundation

/// Mirrors a meeting folder's known files into another folder — typically
/// somewhere under iCloud Drive, so Recap gets a second, user-owned copy for
/// free. This is a one-way backup: the meeting folder stays the source of
/// truth, nothing is ever read back or deleted from the destination.
public struct FolderMirrorExporter: Sendable {
    public var destinationRootURL: URL

    public init(destinationRootURL: URL) {
        self.destinationRootURL = destinationRootURL
    }

    /// Copies every present known file into
    /// `destinationRootURL/<meeting folder name>/`, skipping files that are
    /// already up to date at the destination. Best-effort per file — a
    /// missing source file (e.g. no `audio.m4a` yet, or Apple Intelligence
    /// off so no `enhanced.md`) is simply skipped, never thrown. A
    /// destination that can't be reached or written to, however, throws the
    /// most severe classified `MirrorError` — the caller (queue/backfill/
    /// change-bus consumer) needs that signal to surface a stuck backup.
    public func mirror(_ record: MeetingRecord) throws {
        let fm = FileManager.default

        // Pre-check reachability without touching any files: a destination
        // root that isn't there (iCloud Drive unmounted, folder deleted,
        // external volume ejected) must never silently get re-created.
        do {
            guard try destinationRootURL.checkResourceIsReachable() else {
                throw MirrorError.destinationUnreachable
            }
        } catch {
            throw MirrorError.destinationUnreachable
        }

        let destinationFolderURL = destinationRootURL.appendingPathComponent(record.folderURL.lastPathComponent)
        do {
            try fm.createDirectory(at: destinationFolderURL, withIntermediateDirectories: true)
        } catch {
            throw MirrorError.destinationUnreachable
        }

        let fileNames = [
            "meeting.json", "notes.md", "notes.json", "enhanced.md", "transcript.json", "audio.m4a",
        ]
        var failures: [MirrorError] = []
        for fileName in fileNames {
            let sourceURL = record.folderURL.appendingPathComponent(fileName)
            let destinationURL = destinationFolderURL.appendingPathComponent(fileName)
            if let failure = copyIfNeeded(from: sourceURL, to: destinationURL) {
                failures.append(failure)
            }
        }

        if let mostSevere = Self.mostSevere(of: failures) {
            throw mostSevere
        }
    }

    /// Copies `sourceURL` to `destinationURL` if the source exists and is
    /// newer or different in size than what's already at the destination.
    /// A missing source file is skipped (not a failure); an actual copy
    /// failure is classified and returned rather than thrown, so the caller
    /// keeps going through the rest of the file list instead of aborting.
    private func copyIfNeeded(from sourceURL: URL, to destinationURL: URL) -> MirrorError? {
        let fm = FileManager.default
        guard let sourceAttributes = try? fm.attributesOfItem(atPath: sourceURL.path) else { return nil }

        if let destinationAttributes = try? fm.attributesOfItem(atPath: destinationURL.path) {
            let sourceDate = sourceAttributes[.modificationDate] as? Date
            let destinationDate = destinationAttributes[.modificationDate] as? Date
            let sourceSize = sourceAttributes[.size] as? UInt64
            let destinationSize = destinationAttributes[.size] as? UInt64

            let isNewer = (sourceDate ?? .distantPast) > (destinationDate ?? .distantPast)
            let sizeDiffers = sourceSize != destinationSize
            guard isNewer || sizeDiffers else { return nil }
        }

        // Copy via a temp file in the destination directory, then replace
        // atomically — iCloud Drive only ever sees a complete file appear.
        let tempURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")
        do {
            try fm.copyItem(at: sourceURL, to: tempURL)
            _ = try fm.replaceItemAt(destinationURL, withItemAt: tempURL)
            return nil
        } catch {
            try? fm.removeItem(at: tempURL)
            return MirrorError.classify(error)
        }
    }

    /// Most severe failure across every file in one mirror pass, by
    /// `diskFull > destinationUnreachable > copyFailed`.
    private static func mostSevere(of failures: [MirrorError]) -> MirrorError? {
        if failures.contains(.diskFull) { return .diskFull }
        if failures.contains(.destinationUnreachable) { return .destinationUnreachable }
        return failures.first
    }
}
