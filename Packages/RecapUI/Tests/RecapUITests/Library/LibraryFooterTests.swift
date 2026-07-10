import Foundation
import RecapCore
import Testing
@testable import RecapUI

/// `BackupFooterCopy` — the pure copy mapping behind `LibraryFooter`'s
/// backup-status line (design mock 10a/11c), extracted so the
/// reason-specific stuck copy is directly testable.
@Suite struct BackupFooterCopyTests {
    @Test func okWithLastBackupDateIncludesRelativeTime() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let lastBackup = now.addingTimeInterval(-120)
        let copy = BackupFooterCopy.ok(lastBackupAt: lastBackup, now: now)
        #expect(copy.hasPrefix("Backed up · "))
    }

    @Test func okWithNoLastBackupDateOmitsTheRelativeSegment() {
        #expect(BackupFooterCopy.ok(lastBackupAt: nil) == "Backed up")
    }

    @Test func workingFormatsCompletedOfTotal() {
        #expect(BackupFooterCopy.working(completed: 2, total: 6) == "Backing up · 2 of 6…")
    }

    @Test func stuckReasonsMapToDistinctCopy() {
        #expect(BackupFooterCopy.stuck(.folderUnreachable) == "Backup paused — folder not reachable")
        #expect(BackupFooterCopy.stuck(.diskFull) == "Backup paused — iCloud Drive is full")
        #expect(BackupFooterCopy.stuck(.copyFailed) == "Backup paused")
    }
}
