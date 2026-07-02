import RecapCore
import SwiftUI

/// Trailing status indicator on a Library row: blue progress while transcribing,
/// gray chip while queued, green chip when ready.
struct MeetingStatusView: View {
    var status: MeetingStatus

    var body: some View {
        switch status {
        case .recording:
            chip("Recording", foreground: .white, background: Tokens.recordRed)
        case .queued:
            chip("Queued", foreground: Tokens.textSecondary, background: Color.black.opacity(0.06))
        case .transcribing(let progress):
            HStack(spacing: 10) {
                Text("Transcribing")
                    .font(Tokens.caption.weight(.semibold))
                    .foregroundStyle(Tokens.accentBlue)
                ProgressView(value: progress)
                    .tint(Tokens.accentBlue)
                    .frame(width: 180)
            }
        case .enhancing:
            chip("Enhancing", foreground: Tokens.accentBlue, background: Tokens.accentBlue.opacity(0.1))
        case .ready:
            chip("Ready", foreground: Tokens.successGreenText, background: Tokens.successGreenTint)
        case .error:
            chip("Error", foreground: Tokens.recordRedDark, background: Tokens.recordRed.opacity(0.1))
        }
    }

    private func chip(_ label: String, foreground: Color, background: Color) -> some View {
        Text(label)
            .font(Tokens.caption.weight(.semibold))
            .foregroundStyle(foreground)
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
    /// "Jun 30 · 24 min · 3 speakers" — the row meta line.
    var metaLine: String {
        var parts = [date.formatted(.dateTime.month(.abbreviated).day())]
        if duration > 0 {
            parts.append(Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes], width: .narrow)))
        }
        if !attendees.isEmpty {
            parts.append("\(attendees.count + 1) speakers")
        }
        return parts.joined(separator: " · ")
    }
}
