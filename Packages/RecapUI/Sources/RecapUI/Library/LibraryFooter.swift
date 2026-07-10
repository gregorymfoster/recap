import RecapCore
import SwiftUI

/// Pure copy mapping for the Library footer's backup status (design mock
/// 10a/11c) — extracted out of the view so the reason-specific stuck copy is
/// directly unit-testable.
public enum BackupFooterCopy {
    /// "Backed up · 2 min ago" — `lastBackupAt: nil` (backups enabled but
    /// nothing has completed yet) reads as a bare "Backed up".
    public static func ok(lastBackupAt: Date?, now: Date = .now) -> String {
        guard let lastBackupAt else { return "Backed up" }
        let relative = lastBackupAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        return "Backed up · \(relative)"
    }

    /// "Backing up · 2 of 6…"
    public static func working(completed: Int, total: Int) -> String {
        "Backing up · \(completed) of \(total)…"
    }

    /// Reason-specific stuck copy, each prefixed "Backup paused".
    public static func stuck(_ reason: BackupStuckReason) -> String {
        switch reason {
        case .folderUnreachable: "Backup paused — folder not reachable"
        case .diskFull: "Backup paused — iCloud Drive is full"
        case .copyFailed: "Backup paused"
        }
    }
}

/// The Library window's footer (design mock 10a/11c): a 32pt bar, hairline
/// top border, meeting count on the left, backup status on the right.
/// Always present at the bottom of the Library screen (pinned via
/// `LibraryView`'s `.safeAreaInset`, not part of the scrolling content).
struct LibraryFooter: View {
    var meetingCount: Int
    var backupState: BackupState
    var onFixBackup: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(countLabel)
                .font(.system(size: 11))
                .foregroundStyle(Tokens.textPrimary.opacity(0.45))
            Spacer(minLength: 12)
            backupStatus
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(Tokens.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(Tokens.hairline).frame(height: 1)
        }
        .axID(.libraryFooter)
    }

    private var countLabel: String {
        "\(meetingCount) meeting\(meetingCount == 1 ? "" : "s")"
    }

    @ViewBuilder private var backupStatus: some View {
        switch backupState {
        case .disabled:
            EmptyView()
        case .ok(let lastBackupAt):
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Tokens.successGreenText)
                Text(BackupFooterCopy.ok(lastBackupAt: lastBackupAt))
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.textPrimary.opacity(0.45))
            }
            .axID(.libraryBackupStatus)
        case .working(let completed, let total):
            Text(BackupFooterCopy.working(completed: completed, total: total))
                .font(.system(size: 11))
                .foregroundStyle(Tokens.textPrimary.opacity(0.45))
                .axID(.libraryBackupStatus)
        case .stuck(let reason, _):
            HStack(spacing: 8) {
                Text("⚠ \(BackupFooterCopy.stuck(reason))")
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.warningAmberText)
                Button("Fix…", action: onFixBackup)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Tokens.accentBlue)
                    .axID(.libraryFixBackupLink)
            }
            .axID(.libraryBackupStatus)
        }
    }
}

#Preview {
    VStack(spacing: 0) {
        LibraryFooter(meetingCount: 6, backupState: .ok(lastBackupAt: Date.now.addingTimeInterval(-120)), onFixBackup: {})
        LibraryFooter(meetingCount: 6, backupState: .working(completed: 2, total: 6), onFixBackup: {})
        LibraryFooter(meetingCount: 6, backupState: .stuck(reason: .diskFull, since: .now), onFixBackup: {})
        LibraryFooter(meetingCount: 0, backupState: .disabled, onFixBackup: {})
    }
    .frame(width: 500)
    .background(Tokens.surface)
}
