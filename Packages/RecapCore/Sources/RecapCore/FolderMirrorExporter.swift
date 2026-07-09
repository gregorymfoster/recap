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
    /// off so no `enhanced.md`) is simply skipped, never thrown.
    public func mirror(_ record: MeetingRecord) throws {
        let fm = FileManager.default
        let destinationFolderURL = destinationRootURL.appendingPathComponent(record.folderURL.lastPathComponent)
        try fm.createDirectory(at: destinationFolderURL, withIntermediateDirectories: true)

        let fileNames = [
            "meeting.json", "notes.md", "notes.json", "enhanced.md", "transcript.json", "audio.m4a",
        ]
        for fileName in fileNames {
            let sourceURL = record.folderURL.appendingPathComponent(fileName)
            let destinationURL = destinationFolderURL.appendingPathComponent(fileName)
            copyIfNeeded(from: sourceURL, to: destinationURL)
        }
    }

    /// Copies `sourceURL` to `destinationURL` if the source exists and is
    /// newer or different in size than what's already at the destination.
    /// Failures are swallowed — one bad file must never abort the mirror.
    private func copyIfNeeded(from sourceURL: URL, to destinationURL: URL) {
        let fm = FileManager.default
        guard let sourceAttributes = try? fm.attributesOfItem(atPath: sourceURL.path) else { return }

        if let destinationAttributes = try? fm.attributesOfItem(atPath: destinationURL.path) {
            let sourceDate = sourceAttributes[.modificationDate] as? Date
            let destinationDate = destinationAttributes[.modificationDate] as? Date
            let sourceSize = sourceAttributes[.size] as? UInt64
            let destinationSize = destinationAttributes[.size] as? UInt64

            let isNewer = (sourceDate ?? .distantPast) > (destinationDate ?? .distantPast)
            let sizeDiffers = sourceSize != destinationSize
            guard isNewer || sizeDiffers else { return }
        }

        // Copy via a temp file in the destination directory, then replace
        // atomically — iCloud Drive only ever sees a complete file appear.
        let tempURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")
        do {
            try fm.copyItem(at: sourceURL, to: tempURL)
            _ = try fm.replaceItemAt(destinationURL, withItemAt: tempURL)
        } catch {
            try? fm.removeItem(at: tempURL)
        }
    }
}
