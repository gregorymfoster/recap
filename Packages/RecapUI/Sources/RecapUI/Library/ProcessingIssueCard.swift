import RecapCore
import SwiftUI

/// Persistent, compact recovery guidance for stages that can fail after a
/// meeting is otherwise saved. The copyable code is intentionally stable and
/// contains no meeting data or underlying system error text.
struct ProcessingIssueCard: View {
    let issue: ProcessingIssue
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Tokens.warningAmberText)
                .font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(copy.title)
                    .font(Tokens.caption.weight(.semibold))
                    .foregroundStyle(Tokens.textPrimary)
                Text(copy.detail)
                    .font(Tokens.microLabel)
                    .foregroundStyle(Tokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                Button(copy.action, action: onRetry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .axID(.processingIssueRetryButton(issue))
                CopyButton(help: "Copy diagnostic code \(issue.diagnosticCode)") {
                    issue.diagnosticCode
                }
                .axID(.processingIssueCopyCodeButton(issue))
            }
        }
        .padding(11)
        .background(Tokens.warningAmberTint, in: RoundedRectangle(cornerRadius: Tokens.radiusRow))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.radiusRow)
                .stroke(Tokens.warningAmberText.opacity(0.25), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .axID(.processingIssueCard)
    }

    private var copy: (title: String, detail: String, action: String) {
        switch issue {
        case .recordingFileMissing:
            ("Recording file is missing", "Check the meeting folder, then re-transcribe if the audio is restored.", "Retry transcription")
        case .transcriptionFailed:
            ("Transcription needs another try", "Your recording is still saved. Re-run transcription when you are ready.", "Retry transcription")
        case .enhancementFailed:
            ("Notes enhancement was skipped", "The transcript is ready. Re-run enhancement to create the summary.", "Retry enhancement")
        case .mirrorBackupFailed:
            ("Backup needs attention", "The meeting is saved locally. Check the backup folder, then retry delivery.", "Retry sync")
        }
    }
}
