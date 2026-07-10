import RecapCore
import SwiftUI

/// Trailing status indicator on a Library row — the "quiet status system"
/// (design global decision #4): `.ready` is the silent default (nothing
/// shown at all, no green chip); color marks exceptions only. `needsModel`
/// stays an actionable amber chip (there's a real action: install a model),
/// and `.error` is red text plus a blue "Retry" link that re-enqueues
/// transcription — the one other actionable exception.
struct MeetingStatusView: View {
    var status: MeetingStatus
    /// Invoked when the user taps the "needs model" chip. When nil, the chip is
    /// shown as a non-interactive label (e.g. in previews).
    var onInstallModel: (() -> Void)?
    /// Invoked when the user taps "Retry" on a failed transcription. When
    /// nil, the retry link is omitted (e.g. in previews/fixtures).
    var onRetry: (() -> Void)?

    var body: some View {
        switch status {
        case .recording:
            // stays: white text on the solid red "Recording" chip in both modes
            chip("Recording", foreground: .white, background: Tokens.recordRed)
        case .queued, .recovered:
            Text("Queued")
                .font(Tokens.caption)
                .foregroundStyle(Tokens.textSecondary)
        case .transcribing(let progress):
            HStack(spacing: 8) {
                Text("Transcribing · \(Int((progress * 100).rounded()))%")
                    .font(Tokens.caption.weight(.semibold))
                    .foregroundStyle(Tokens.accentBlue)
                    .monospacedDigit()
                ProgressView(value: progress)
                    .tint(Tokens.accentBlue)
                    .frame(width: 110)
            }
        case .enhancing:
            Text("Enhancing")
                .font(Tokens.caption.weight(.semibold))
                .foregroundStyle(Tokens.accentBlue)
        case .ready:
            // Silent default: a finished meeting shows no status at all.
            EmptyView()
        case .needsModel:
            needsModelChip
        case .error:
            errorStatus
        }
    }

    /// Red "Transcription failed" text + blue "Retry" link that re-enqueues
    /// transcription. The underlying message (e.g. "Microphone access
    /// denied") stays available on hover for detail, but the row itself
    /// always reads the same quiet, generic failure text per the design.
    @ViewBuilder private var errorStatus: some View {
        if case .error(let message) = status {
            HStack(spacing: 8) {
                Text("Transcription failed")
                    .font(Tokens.caption.weight(.semibold))
                    .foregroundStyle(Tokens.recordRedDark)
                if let onRetry {
                    Button("Retry", action: onRetry)
                        .buttonStyle(.plain)
                        .font(Tokens.caption.weight(.semibold))
                        .foregroundStyle(Tokens.accentBlue)
                        .axID(.libraryRowRetranscribe)
                }
            }
            .help(message)
        }
    }

    /// Amber, tappable "install a model to finish this" affordance.
    @ViewBuilder private var needsModelChip: some View {
        let label = HStack(spacing: 5) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 11))
            Text("Install model to transcribe")
                .font(Tokens.caption.weight(.semibold))
        }
        .foregroundStyle(Tokens.warningAmberText)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Tokens.warningAmberTint, in: RoundedRectangle(cornerRadius: Tokens.radiusChip))

        if let onInstallModel {
            Button(action: onInstallModel) { label }
                .buttonStyle(.plain)
                .help("No speech model is installed yet. Click to retry setup — this meeting transcribes automatically once a model is ready.")
                .axID(.rowInstallModelButton)
        } else {
            label
        }
    }

    private func chip(_ label: String, foreground: Color, background: Color) -> some View {
        Text(label)
            .font(Tokens.caption.weight(.semibold))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(background, in: RoundedRectangle(cornerRadius: Tokens.radiusChip))
    }
}

/// "🔒 On-device only" / "on-device" privacy indicator used across the app.
struct OnDeviceBadge: View {
    var label = "On-device only"

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.fill")
                .font(.system(size: 8, weight: .semibold))
            Text(label)
                .font(Tokens.microLabel)
        }
        .foregroundStyle(Tokens.successGreenText)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(Tokens.successGreenTint, in: RoundedRectangle(cornerRadius: Tokens.radiusChip))
    }
}

extension Meeting {
    /// "Jun 30 · 24 min · 3 speakers" — the row meta line. Meetings parked at
    /// `.needsModel` have audio safely on disk but nothing to show for
    /// duration/speakers yet (no transcript = no diarization) — "audio
    /// saved" reassures that the recording wasn't lost.
    var metaLine: String {
        var parts = [date.formatted(.dateTime.month(.abbreviated).day())]
        if duration > 0 {
            parts.append(Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes], width: .narrow)))
        }
        if !attendees.isEmpty {
            parts.append("\(attendees.count + 1) speakers")
        }
        if status == .needsModel {
            parts.append("audio saved")
        }
        return parts.joined(separator: " · ")
    }
}
