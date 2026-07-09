import Observation
import RecapCore

/// Drives the redesigned backup-status surface (Library footer + Settings
/// row): aggregate `BackupState`, figures, retry/backfill actions. Inert
/// stub — implemented in Phase 1 B3; not yet wired into `AppStores`.
@MainActor
@Observable
public final class BackupStatusStore {
    public struct BackupFigures: Equatable, Sendable {
        public var meetingCount: Int
        public var totalBytes: Int64

        public init(meetingCount: Int, totalBytes: Int64) {
            self.meetingCount = meetingCount
            self.totalBytes = totalBytes
        }
    }

    public private(set) var state: BackupState = .disabled
    public private(set) var figures: BackupFigures?

    public init() {}

    public func backfill() {}

    public func retry() {}
}
