import Foundation

/// Pure disk-space math for the Model Manager: decides whether a model's
/// approximate download size fits the free space available on the volume
/// that holds the models folder, and formats the footnote shown when it
/// doesn't. Kept as a pure function of two byte counts (rather than reading
/// the volume itself) so the decision and copy are unit-testable without
/// touching the filesystem — `ModelManagerView` supplies the live
/// `volumeAvailableCapacityForImportantUsage` value.
enum ModelDiskSpace {
    /// A model's approximate download size clearly won't fit the free space
    /// available. Deliberately conservative (checks against
    /// `approximateSizeMB`, not the exact remote size) so this only ever
    /// warns when a download would almost certainly fail partway through,
    /// not for close calls.
    static func wontFit(freeBytes: Int64?, modelSizeMB: Int) -> Bool {
        guard let freeBytes else { return false }
        let neededBytes = Int64(modelSizeMB) * 1_000_000
        return freeBytes < neededBytes
    }

    /// Footnote copy for a model that won't fit, e.g. "4.2 GB free on disk —
    /// Whisper Large v3 Turbo needs 626 MB." Returns `nil` when the model
    /// fits (or free space is unknown), so callers can render nothing rather
    /// than an empty footnote.
    static func footnote(freeBytes: Int64?, modelSizeMB: Int, modelDisplayName: String) -> String? {
        guard wontFit(freeBytes: freeBytes, modelSizeMB: modelSizeMB), let freeBytes else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let freeText = formatter.string(fromByteCount: freeBytes)
        return "\(freeText) free on disk — \(modelDisplayName) needs \(modelSizeMB) MB"
    }
}
