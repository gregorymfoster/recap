import RecapAudio
import RecapTranscription
import SwiftUI

/// First-run sheet: privacy promise → guided model download → permissions.
struct OnboardingView: View {
    @Environment(WhisperModelManager.self) private var models
    @Environment(SettingsStore.self) private var settings
    @State private var step = 0
    @State private var micGranted: Bool?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Group {
                switch step {
                case 0: privacyStep
                case 1: modelStep
                default: permissionsStep
                }
            }
            .frame(maxWidth: 420)
            Spacer()
            footer
        }
        .padding(32)
        .frame(width: 560, height: 480)
        .background(Tokens.surface)
        .interactiveDismissDisabled()
    }

    // MARK: Steps

    private var privacyStep: some View {
        VStack(spacing: 16) {
            RecapLogo(size: 56)
            Text("Meetings that stay on your Mac")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Tokens.textPrimary)
            Text("Recap records and transcribes your meetings entirely on this Mac using open-source models. No account, no cloud, no bot joining your calls — your audio and notes never leave this computer.")
                .font(.system(size: 13))
                .lineSpacing(4)
                .multilineTextAlignment(.center)
                .foregroundStyle(Tokens.textSecondary)
            OnDeviceBadge(label: "Everything stays on your Mac")
        }
    }

    private var modelStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Tokens.accentBlue)
            Text("Download a speech model")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Tokens.textPrimary)
            Text("Recap transcribes with Whisper, downloaded once from Hugging Face. Whisper Small (~500 MB) is the best balance of speed and accuracy for meetings.")
                .font(.system(size: 13))
                .lineSpacing(4)
                .multilineTextAlignment(.center)
                .foregroundStyle(Tokens.textSecondary)

            let model = ModelCatalog.recommended
            switch models.states[model.id] ?? .available {
            case .available:
                Button {
                    models.download(model)
                    // Kick off the small live-transcription model alongside
                    // the main one so it's ready before the first recording
                    // instead of loading cold at that moment.
                    models.ensureStreamingModelDownloading()
                } label: {
                    Text("Download \(model.displayName)")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Tokens.accentBlue)
            case .downloading(let progress):
                VStack(spacing: 6) {
                    ProgressView(value: max(0.02, progress))
                        .tint(Tokens.accentBlue)
                        .frame(width: 260)
                    Text("\(Int(progress * 100))% — you can keep going, the download continues")
                        .font(Tokens.caption)
                        .foregroundStyle(Tokens.textSecondary)
                }
            case .installed:
                Label("\(model.displayName) installed", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.successGreenText)
            }
        }
    }

    private var permissionsStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Tokens.recordRed)
            Text("Two permissions")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Tokens.textPrimary)
            VStack(alignment: .leading, spacing: 12) {
                permissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    detail: "Your side of the conversation.",
                    trailing: {
                        if micGranted == true {
                            Label("Granted", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(Tokens.successGreenText)
                                .font(Tokens.caption)
                        } else if micGranted == false {
                            Button("Open Settings") {
                                PrivacyPane.open(PrivacyPane.microphone)
                            }
                            .controlSize(.small)
                        } else {
                            Button("Allow") {
                                Task { micGranted = await MeetingRecorder.requestMicPermission() }
                            }
                            .controlSize(.small)
                        }
                    }
                )
                permissionRow(
                    icon: "speaker.wave.2.fill",
                    title: "System Audio Recording",
                    detail: "The other participants, without a bot in the call. macOS asks the first time you record.",
                    trailing: { EmptyView() }
                )
            }
            .padding(16)
            .background(Tokens.subtleBackground, in: RoundedRectangle(cornerRadius: Tokens.radiusCard))
        }
    }

    private func permissionRow(
        icon: String, title: String, detail: String, @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(Tokens.textSecondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Tokens.rowTitle)
                    .foregroundStyle(Tokens.textPrimary)
                Text(detail)
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.textSecondary)
            }
            Spacer()
            trailing()
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if step > 0 {
                Button("Back") { step -= 1 }
                    .buttonStyle(.borderless)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { dot in
                    Circle()
                        .fill(dot == step ? Tokens.textPrimary : Tokens.cardStroke)
                        .frame(width: 6, height: 6)
                }
            }
            Spacer()
            if step < 2 {
                Button(step == 1 && models.states[ModelCatalog.recommended.id] != .installed ? "Skip for now" : "Continue") {
                    step += 1
                }
                .buttonStyle(.borderedProminent)
                .tint(Tokens.textPrimary)
            } else {
                Button("Start using Recap") {
                    settings.hasOnboarded = true
                }
                .buttonStyle(.borderedProminent)
                .tint(Tokens.textPrimary)
            }
        }
    }
}

#Preview("Light") {
    OnboardingView()
        .environment(WhisperModelManager())
        .environment(SettingsStore())
}

#Preview("Dark") {
    OnboardingView()
        .environment(WhisperModelManager())
        .environment(SettingsStore())
        .preferredColorScheme(.dark)
}
