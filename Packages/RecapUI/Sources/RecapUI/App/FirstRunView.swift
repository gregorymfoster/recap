import AVFoundation
import RecapAudio
import RecapTranscription
import SwiftUI

/// Pure byte-progress label for the "setting up transcription" card — a
/// fraction (from `TranscriptionSetupStore.SetupPhase.downloading`) times a
/// model's `approximateSizeMB`, rendered "213 MB of 626 MB" style. Kept as a
/// free function so it's unit-testable without a view.
enum FirstRunModelProgress {
    static func byteLabel(progress: Double, totalMB: Int) -> String {
        let downloaded = Int((progress.clamped01 * Double(totalMB)).rounded())
        return "\(downloaded) MB of \(totalMB) MB"
    }
}

private extension Double {
    var clamped01: Double { min(max(self, 0), 1) }
}

/// The single first-run sheet (design spec 11b): app identity, two
/// skippable permission rows, an automatic "setting up transcription" card
/// driven by `TranscriptionSetupStore`, and a primary action that's never
/// gated on either — recording works immediately, permissions and the model
/// download both happen in the background or get asked for again on first
/// record (`RecordingPreflight`). Replaces the old 3-step `OnboardingView`.
struct FirstRunView: View {
    /// Passed explicitly (not via `@Environment`) since `AppStores.setup`
    /// isn't threaded into `RootView`'s environment chain — keeps the
    /// `RootView` edit to a single call-site change.
    let setup: TranscriptionSetupStore
    @Environment(SettingsStore.self) private var settings
    @State private var micStatus = AVAudioApplication.shared.recordPermission

    var body: some View {
        VStack(spacing: 20) {
            header
            VStack(spacing: 14) {
                permissionsCard
                VStack(spacing: 8) {
                    modelCard
                    Text("Downloads once, then works offline. Picked automatically for this Mac.")
                        .font(Tokens.caption)
                        .foregroundStyle(Tokens.textTertiary)
                        .multilineTextAlignment(.center)
                }
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(24)
        .frame(width: 440, height: 560)
        .background(Tokens.surface)
        .interactiveDismissDisabled()
        .axID(.firstRunView)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 8) {
            RecapLogo(size: 40)
            Text("Recap")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(Tokens.textPrimary)
            Text("Record meetings, get transcripts, back up automatically — all on this Mac.")
                .font(.system(size: 12.5))
                .lineSpacing(7)
                .multilineTextAlignment(.center)
                .foregroundStyle(Tokens.textPrimary.opacity(0.55))
        }
    }

    // MARK: Permissions

    private var permissionsCard: some View {
        VStack(spacing: 0) {
            permissionRow(
                title: "Microphone",
                detail: "Only while recording",
                granted: micStatus == .granted,
                axID: .firstRunAllowMic
            ) {
                Task {
                    _ = await MeetingRecorder.requestMicPermission()
                    micStatus = AVAudioApplication.shared.recordPermission
                }
            }
            Divider()
                .foregroundStyle(Tokens.cardStroke)
            systemAudioRow
        }
        .background(Tokens.subtleBackground, in: RoundedRectangle(cornerRadius: Tokens.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.radiusCard)
                .strokeBorder(Tokens.cardStroke)
        )
    }

    private var systemAudioStatus: PermissionStatus {
        .systemAudio(lastTapFailed: settings.lastSystemAudioTapFailed)
    }

    @ViewBuilder
    private var systemAudioRow: some View {
        let granted = systemAudioStatus == .granted || systemAudioStatus == .workedLastTime
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Other participants")
                    .font(Tokens.rowTitle)
                    .foregroundStyle(Tokens.textPrimary)
                Text("System audio from Zoom, Meet, Teams")
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.textSecondary)
            }
            Spacer()
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.successGreenText)
            } else {
                SystemAudioProbeButton(label: "Allow") { result in
                    settings.lastSystemAudioTapFailed = (result != .captured)
                }
                .buttonStyle(.borderedProminent)
                .tint(Tokens.accentBlue)
                .controlSize(.small)
                .axID(.firstRunAllowSystemAudio)
            }
        }
        .padding(14)
    }

    private func permissionRow(
        title: String, detail: String, granted: Bool, axID: AXID, onAllow: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Tokens.rowTitle)
                    .foregroundStyle(Tokens.textPrimary)
                Text(detail)
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.textSecondary)
            }
            Spacer()
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.successGreenText)
            } else {
                Button("Allow", action: onAllow)
                    .buttonStyle(.borderedProminent)
                    .tint(Tokens.accentBlue)
                    .controlSize(.small)
                    .axID(axID)
            }
        }
        .padding(14)
    }

    // MARK: Setting up transcription

    @ViewBuilder
    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch setup.phase {
            case .downloading(let progress):
                HStack {
                    Text("Setting up transcription")
                        .font(Tokens.rowTitle)
                        .foregroundStyle(Tokens.textPrimary)
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: max(0.02, progress))
                        .tint(Tokens.accentBlue)
                    Text(FirstRunModelProgress.byteLabel(progress: progress, totalMB: ModelCatalog.recommended.approximateSizeMB))
                        .font(Tokens.caption)
                        .foregroundStyle(Tokens.textSecondary)
                }
            case .done:
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .font(Tokens.rowTitle)
                    .foregroundStyle(Tokens.successGreenText)
            case .failed:
                HStack {
                    Label("Couldn't set up transcription", systemImage: "exclamationmark.triangle.fill")
                        .font(Tokens.rowTitle)
                        .foregroundStyle(Tokens.warningAmberText)
                    Spacer()
                    Button("Retry") { setup.retry() }
                        .controlSize(.small)
                }
            }
        }
        .padding(14)
        .background(Tokens.subtleBackground, in: RoundedRectangle(cornerRadius: Tokens.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.radiusCard)
                .strokeBorder(Tokens.cardStroke)
        )
        .axID(.firstRunModelCard)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 10) {
            Button("Start using Recap") {
                settings.hasOnboarded = true
            }
            .buttonStyle(.borderedProminent)
            .tint(Tokens.accentBlue)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .axID(.firstRunStartButton)

            Text("You can record right away — transcripts appear when setup finishes.")
                .font(Tokens.caption)
                .foregroundStyle(Tokens.textTertiary)
                .multilineTextAlignment(.center)
        }
    }
}

#Preview("Light") {
    let settings = SettingsStore()
    FirstRunView(setup: TranscriptionSetupStore(models: WhisperModelManager(), settings: settings))
        .environment(settings)
}

#Preview("Dark") {
    let settings = SettingsStore()
    FirstRunView(setup: TranscriptionSetupStore(models: WhisperModelManager(), settings: settings))
        .environment(settings)
        .preferredColorScheme(.dark)
}
