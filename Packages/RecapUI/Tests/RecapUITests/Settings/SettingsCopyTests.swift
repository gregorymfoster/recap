import Foundation
import RecapCore
import Testing
@testable import RecapUI

/// Pure copy-helper tests for the redesigned Settings page's Storage-group
/// backup status row (`SettingsWindowView`, Phase 3D). Framework-free logic —
/// no view/store setup needed.
@Suite struct SettingsBackupCopyTests {
    private static let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test func relativeDateReadsAsMinutesAgo() {
        let twoMinutesAgo = Self.now.addingTimeInterval(-120)
        let text = SettingsBackupCopy.relativeDate(twoMinutesAgo, now: Self.now)
        #expect(text.contains("2"))
    }

    @Test func shortDayFormatsAsAbbreviatedMonthAndDay() {
        // 2001-07-07 00:00:00 UTC-ish reference date math: pick a known date
        // via DateComponents instead of a magic offset, for readability.
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 7
        let date = Calendar(identifier: .gregorian).date(from: components)!
        #expect(SettingsBackupCopy.shortDay(date) == "Jul 7")
    }

    @Test func reasonTextIsUserFacingNotRawCaseName() {
        #expect(SettingsBackupCopy.reasonText(.folderUnreachable) == "Folder not reachable")
        #expect(SettingsBackupCopy.reasonText(.diskFull) == "Backup destination is full")
        #expect(SettingsBackupCopy.reasonText(.copyFailed) == "Backup copy failed")
    }

    @Test func stuckMessageCombinesReasonAndDate() {
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 7
        let since = Calendar(identifier: .gregorian).date(from: components)!
        #expect(SettingsBackupCopy.stuckMessage(reason: .folderUnreachable, since: since) == "Folder not reachable since Jul 7")
    }

    @Test func figuresLabelOmitsSizeWhenZeroBytes() {
        #expect(SettingsBackupCopy.figuresLabel(meetingCount: 0, totalBytes: 0) == "0 meetings")
        #expect(SettingsBackupCopy.figuresLabel(meetingCount: 1, totalBytes: 0) == "1 meeting")
    }

    @Test func figuresLabelIncludesSizeWhenNonZero() {
        let label = SettingsBackupCopy.figuresLabel(meetingCount: 6, totalBytes: 64_000)
        #expect(label.hasPrefix("6 meetings · "))
    }

    @Test func statusLineUsesNoBackupsYetWhenNeverBackedUp() {
        let line = SettingsBackupCopy.statusLine(lastBackupAt: nil, meetingCount: 0, totalBytes: 0, now: Self.now)
        #expect(line == "No backups yet · 0 meetings")
    }

    @Test func statusLineCombinesLastBackupAndFigures() {
        let twoMinutesAgo = Self.now.addingTimeInterval(-120)
        let line = SettingsBackupCopy.statusLine(lastBackupAt: twoMinutesAgo, meetingCount: 6, totalBytes: 64_000, now: Self.now)
        #expect(line.hasPrefix("Last backup"))
        #expect(line.contains("6 meetings"))
    }
}
