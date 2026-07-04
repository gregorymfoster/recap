import RecapCore
import SwiftUI

/// SwiftUI content for the "Meeting started?" nudge panel (design mock 9b).
/// Fixed-width card matching the floating-indicator idiom: dark surface,
/// hairline stroke, real working buttons only — no decorative affordances.
public struct MeetingNudgeView: View {
    let nudge: MeetingNudge
    let onRecord: () -> Void
    let onNotNow: () -> Void
    let onDontAsk: (() -> Void)?
    let onStop: (() -> Void)?

    public init(
        nudge: MeetingNudge,
        onRecord: @escaping () -> Void,
        onNotNow: @escaping () -> Void,
        onDontAsk: (() -> Void)? = nil,
        onStop: (() -> Void)? = nil
    ) {
        self.nudge = nudge
        self.onRecord = onRecord
        self.onNotNow = onNotNow
        self.onDontAsk = onDontAsk
        self.onStop = onStop
    }

    private var appID: String? {
        if case .ask(let appID, _, _) = nudge { return appID }
        return nil
    }

    private var appName: String? {
        if case .ask(_, let appName, _) = nudge { return appName }
        return nil
    }

    private var symbolName: String {
        appID != nil ? "video.fill" : "calendar"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Text(MeetingNudgeCopy.body(for: nudge))
                .font(.system(size: 12))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            actionRow
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
        .background(Tokens.darkSurface, in: RoundedRectangle(cornerRadius: Tokens.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.radiusCard)
                .stroke(Tokens.darkSurfaceStroke, lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Tokens.accentBlue.opacity(0.18))
                    .frame(width: 28, height: 28)
                Image(systemName: symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tokens.accentBlue)
            }
            Text(MeetingNudgeCopy.title(for: nudge))
                .font(.system(size: 13, weight: .semibold))
                // stays: light text on the pinned-dark nudge card in both modes
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            Text("now")
                .font(.system(size: 11))
                .foregroundStyle(Tokens.textTertiary)
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        switch nudge {
        case .ask:
            HStack(spacing: 8) {
                recordButton
                notNowButton
                Spacer(minLength: 0)
                if let appID, let onDontAsk {
                    let shortName = CallAppCatalog.apps.first { $0.id == appID }?.shortName
                    Button("Don\u{2019}t ask for \(shortName ?? appName ?? appID)") {
                        onDontAsk()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Tokens.textTertiary)
                }
            }
        case .recordingStarted:
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Stop") {
                    onStop?()
                }
                .buttonStyle(.bordered)
                .font(.system(size: 12, weight: .semibold))
            }
        }
    }

    private var recordButton: some View {
        Button {
            onRecord()
        } label: {
            HStack(spacing: 7) {
                // stays: white dot/text on the red Record button in both modes
                Circle().fill(.white).frame(width: 7, height: 7)
                Text("Record")
                    .font(.system(size: 12.5, weight: .semibold))
            }
            // stays: white text on the red Record button in both modes
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 26)
            .background(Tokens.recordRed, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var notNowButton: some View {
        Button {
            onNotNow()
        } label: {
            Text("Not now")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Tokens.textSecondary)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Tokens.chipBackground, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
