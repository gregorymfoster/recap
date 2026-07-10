import Foundation
import RecapCore

/// Pure copy helpers for the redesigned one-page Settings surface
/// (`SettingsWindowView`, Phase 3D) — backup relative dates, stuck-reason
/// messages, and the figures line under the Storage group. Framework-free
/// (just Foundation) so they're directly unit-testable without a live view.
enum SettingsBackupCopy {
    /// "2 min ago" / "Yesterday" — relative to `now`, matching macOS's
    /// system relative-date phrasing.
    static func relativeDate(_ date: Date, now: Date = .now) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// "Jul 7" — the short day shown in the stuck row's "since <date>".
    static func shortDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    /// User-facing reason text for a stuck backup, distinct from the raw
    /// `BackupStuckReason` case name.
    static func reasonText(_ reason: BackupStuckReason) -> String {
        switch reason {
        case .folderUnreachable: "Folder not reachable"
        case .diskFull: "Backup destination is full"
        case .copyFailed: "Backup copy failed"
        }
    }

    /// "Folder not reachable since Jul 7" — the inline amber stuck row's copy.
    static func stuckMessage(reason: BackupStuckReason, since: Date) -> String {
        "\(reasonText(reason)) since \(shortDay(since))"
    }

    /// "6 meetings · 64 kB" (design global #6 — never dev copy like "Zero
    /// kB"; an empty or size-less backup set reads as plain prose).
    static func figuresLabel(meetingCount: Int, totalBytes: Int64) -> String {
        let meetings = "\(meetingCount) meeting\(meetingCount == 1 ? "" : "s")"
        guard totalBytes > 0 else { return meetings }
        let size = totalBytes.formatted(.byteCount(style: .file))
        return "\(meetings) · \(size)"
    }

    /// "Last backup 2 min ago · 6 meetings · 64 kB" — the full ok-state
    /// status row shown under the backup toggle.
    static func statusLine(lastBackupAt: Date?, meetingCount: Int, totalBytes: Int64, now: Date = .now) -> String {
        let leading = lastBackupAt.map { "Last backup \(relativeDate($0, now: now))" } ?? "No backups yet"
        return "\(leading) · \(figuresLabel(meetingCount: meetingCount, totalBytes: totalBytes))"
    }
}
