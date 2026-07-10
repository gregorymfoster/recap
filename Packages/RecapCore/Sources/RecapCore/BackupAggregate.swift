import Foundation

/// Failure modes surfaced by the folder-mirror backup ("`FolderMirrorExporter`
/// hardening", Phase 0 scaffolding for the backup-status redesign). Deeper
/// aggregation across meetings lands in a later phase.
public enum MirrorError: Error, Equatable, Sendable {
    case destinationUnreachable
    case diskFull
    case copyFailed

    /// Maps a raw `Error` (from `FileManager` copy/create-directory calls)
    /// to a classified `MirrorError` — pure, so each error kind is directly
    /// testable without touching disk.
    public static func classify(_ error: Error) -> MirrorError {
        if let mirrorError = error as? MirrorError { return mirrorError }

        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == CocoaError.fileWriteOutOfSpace.rawValue {
            return .diskFull
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOSPC) {
            return .diskFull
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(ENOSPC) {
            return .diskFull
        }
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.fileNoSuchFile.rawValue || nsError.code == CocoaError.fileReadNoSuchFile.rawValue {
            return .destinationUnreachable
        }
        return .copyFailed
    }
}

/// Why a backup is stuck, as shown to the user — a stable, non-technical
/// reason distinct from the underlying `MirrorError`.
public enum BackupStuckReason: String, Equatable, Sendable {
    case folderUnreachable
    case diskFull
    case copyFailed
}

/// Aggregate backup status shown in the redesigned Library footer / Settings
/// row.
public enum BackupState: Equatable, Sendable {
    case disabled
    case ok(lastBackupAt: Date?)
    case working(completed: Int, total: Int)
    case stuck(reason: BackupStuckReason, since: Date)
}

public enum BackupAggregate {
    /// Maps a raw mirror failure to the user-facing stuck reason.
    public static func stuckReason(for error: MirrorError) -> BackupStuckReason {
        switch error {
        case .destinationUnreachable: .folderUnreachable
        case .diskFull: .diskFull
        case .copyFailed: .copyFailed
        }
    }

    /// A meeting still needs a mirror backup when it's never been backed up,
    /// or was backed up before its last edit — the same rule whether the
    /// caller is a bulk backfill or a single change-bus re-export.
    public static func isPending(lastBackupDate: Date?, updatedAt: Date?) -> Bool {
        guard let lastBackupDate else { return true }
        guard let updatedAt else { return false }
        return lastBackupDate < updatedAt
    }

    /// Latest of a set of per-meeting backup dates, or `nil` if none have
    /// ever been backed up.
    public static func latestBackupDate(_ dates: [Date?]) -> Date? {
        dates.compactMap { $0 }.max()
    }
}
