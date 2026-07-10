import RecapCore
import SwiftUI

/// Trailing status indicator on a Library row — the "quiet status system"
/// (design global decision #4): `.ready` is the silent default (nothing
/// shown at all here — `LibraryView.MeetingRow` renders the start ·
/// duration line for `.ready` itself); color marks exceptions only.
/// `.recovered` gets its own full-row layout in `LibraryView.MeetingRow`
/// rather than a trailing status, so it isn't rendered by this view.
struct MeetingStatusView: View {
    var status: MeetingStatus
    /// The transcription-setup pipeline's current phase, used to derive
    /// `.needsModel`'s copy ("Waiting for setup · 34%" while downloading,
    /// a Retry action if setup failed). `nil` in previews/fixtures that
    /// don't wire a `TranscriptionSetupStore`.
    var setupPhase: TranscriptionSetupStore.SetupPhase?
    /// Invoked when the user taps "Retry" after a failed transcription-setup
    /// download. When nil, the retry link is omitted (e.g. in previews).
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
            Text("Waiting to transcribe")
                .font(Tokens.caption)
                .foregroundStyle(Tokens.textSecondary)
        case .transcribing(let progress):
            HStack(spacing: 8) {
                Text("Transcribing · \(Int((progress * 100).rounded()))%")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Tokens.accentBlue)
                    .monospacedDigit()
                ThinProgressBar(progress: progress)
                    .frame(width: 90, height: 4)
            }
        case .enhancing:
            Text("Enhancing")
                .font(Tokens.caption.weight(.semibold))
                .foregroundStyle(Tokens.accentBlue)
        case .ready:
            // Silent default: a finished meeting shows no status at all
            // here — `MeetingRow` renders its own start · duration line.
            EmptyView()
        case .needsModel:
            needsModelStatus
        case .error:
            errorStatus
        }
    }

    /// Amber "Transcription failed" text + a ghost "Retry" that re-enqueues
    /// transcription. The underlying message (e.g. "Microphone access
    /// denied") stays available on hover for detail, but the row itself
    /// always reads the same quiet, generic failure text per the design.
    @ViewBuilder private var errorStatus: some View {
        if case .error(let message) = status {
            HStack(spacing: 8) {
                Text("Transcription failed")
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.warningAmberText)
                if let onRetry {
                    Button("Retry", action: onRetry)
                        .buttonStyle(.quietBlueOutline)
                        .axID(.libraryRowRetranscribe)
                }
            }
            .help(message)
        }
    }

    /// A meeting parked on `.needsModel` derives its copy from the
    /// transcription-setup pipeline rather than showing its own affordance —
    /// there's nothing this row can do that setup isn't already doing
    /// automatically, except retry a failed download.
    @ViewBuilder private var needsModelStatus: some View {
        switch setupPhase {
        case .downloading(let progress):
            Text("Waiting for setup · \(Int((progress * 100).rounded()))%")
                .font(Tokens.caption)
                .foregroundStyle(Tokens.textSecondary)
        case .failed:
            HStack(spacing: 8) {
                Text("Setup failed")
                    .font(Tokens.caption.weight(.semibold))
                    .foregroundStyle(Tokens.warningAmberText)
                if let onInstallModel {
                    Button("Retry", action: onInstallModel)
                        .buttonStyle(.quietBlueOutline)
                        .help("No speech model is installed yet. Click to retry setup — this meeting transcribes automatically once a model is ready.")
                        .axID(.rowRetryDownloadButton)
                }
            }
        case .done, nil:
            // Setup finished (or unknown, e.g. previews) — this meeting is
            // just waiting its turn in the queue, same as `.queued`.
            Text("Waiting to transcribe")
                .font(Tokens.caption)
                .foregroundStyle(Tokens.textSecondary)
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

/// A thin (typically 4pt-tall) determinate progress bar — `ProgressView`'s
/// native macOS style doesn't shrink below its intrinsic height, so the
/// row's transcribing status uses this instead.
struct ThinProgressBar: View {
    var progress: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Tokens.chipBackground)
                Capsule()
                    .fill(Tokens.accentBlue)
                    .frame(width: geometry.size.width * min(max(progress, 0), 1))
            }
        }
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
