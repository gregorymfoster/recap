import Foundation

/// Failure modes surfaced by the folder-mirror backup ("`FolderMirrorExporter`
/// hardening", Phase 0 scaffolding for the backup-status redesign). Deeper
/// aggregation across meetings lands in a later phase.
public enum MirrorError: Error, Equatable, Sendable {
    case destinationUnreachable
    case diskFull
    case copyFailed
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
}
