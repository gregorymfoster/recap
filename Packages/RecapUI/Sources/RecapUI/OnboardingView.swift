import RecapAudio
import RecapTranscription
import SwiftUI

/// First-run sheet: privacy promise → guided model download → permissions.
/// Design spec 8b: page dots at the bottom, a "promise" step 1, an
/// accent-tinted recommended-model card on step 2, and permission rows with
/// live granted state on step 3. Continue is never blocked by the model
/// download or by permissions — both can be finished later.
struct OnboardingView: View {
    @Environment(WhisperModelManager.self) private var models
    @Environment(SettingsStore.self) private var settings
    @State private var step = 0
    @State private var micGranted: Bool?
    @State private var systemAudioResult: SystemAudioProbeResult?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Group {
                switch step {
                case 0: promiseStep
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

    // MARK: Step 1 — promise

    private var promiseStep: some View {
        VStack(spacing: 16) {
            RecapLogo(size: 56)
            Text("Your meetings stay here")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Tokens.textPrimary)
            Text("Recap records and transcribes your meetings entirely on this Mac using open-source models.")
                .font(.system(size: 12.5))
                .lineSpacing(4)
                .multilineTextAlignment(.center)
                .foregroundStyle(Tokens.textSecondary)
            VStack(alignment: .leading, spacing: 8) {
                promiseBullet("No cloud, no account")
                promiseBullet("Plain Markdown + audio in ~/Recap")
                promiseBullet("Works offline")
            }
        }
    }

    private func promiseBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Tokens.successGreenText)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(Tokens.textSecondary)
        }
    }

    // MARK: Step 2 — model

    private var modelStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Tokens.accentBlue)
            Text("Download a speech model")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Tokens.textPrimary)
            Text("Recap transcribes with Whisper, downloaded once from Hugging Face.")
                .font(.system(size: 13))
                .lineSpacing(4)
                .multilineTextAlignment(.center)
                .foregroundStyle(Tokens.textSecondary)

            recommendedModelCard
            secondaryModelRow

            Text("Downloads continue in the background — Continue is never blocked.")
                .font(Tokens.caption)
                .foregroundStyle(Tokens.textTertiary)
                .multilineTextAlignment(.center)
        }
    }

    private var recommendedModelCard: some View {
        let model = ModelCatalog.recommended
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                        .font(Tokens.rowTitle)
                        .foregroundStyle(Tokens.textPrimary)
                    Text(model.qualityHint)
                        .font(Tokens.caption)
                        .foregroundStyle(Tokens.textSecondary)
                }
                Spacer()
                modelTrailing(model)
            }
            if case .downloading(let progress) = models.states[model.id] ?? .available {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: max(0.02, progress))
                        .tint(Tokens.accentBlue)
                    Text("\(Int(progress * Double(model.approximateSizeMB))) of \(model.approximateSizeMB) MB")
                        .font(Tokens.caption)
                        .foregroundStyle(Tokens.textSecondary)
                }
            }
        }
        .padding(14)
        .background(Tokens.accentBlue.opacity(0.1), in: RoundedRectangle(cornerRadius: Tokens.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.radiusCard)
                .strokeBorder(Tokens.accentBlue.opacity(0.3))
        )
    }

    @ViewBuilder
    private func modelTrailing(_ model: ModelInfo) -> some View {
        switch models.states[model.id] ?? .available {
        case .available:
            Button {
                models.download(model)
                // Kick off the small live-transcription model alongside the
                // main one so it's ready before the first recording instead
                // of loading cold at that moment.
                models.ensureStreamingModelDownloading()
            } label: {
                Text("Download")
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(Tokens.accentBlue)
            .controlSize(.small)
        case .downloading:
            ProgressView()
                .controlSize(.small)
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .font(Tokens.caption)
                .foregroundStyle(Tokens.successGreenText)
        }
    }

    private var secondaryModelRow: some View {
        let tiny = ModelCatalog.all.first { $0.id == "tiny" } ?? ModelCatalog.streamingDefault
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(tiny.displayName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                Text(tiny.qualityHint)
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.textTertiary)
            }
            Spacer()
            switch models.states[tiny.id] ?? .available {
            case .available:
                Button("Choose") {
                    models.download(tiny)
                }
                .controlSize(.small)
            case .downloading:
                ProgressView().controlSize(.small)
            case .installed:
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.successGreenText)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Tokens.subtleBackground, in: RoundedRectangle(cornerRadius: Tokens.radiusCard))
    }

    // MARK: Step 3 — permissions

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
                    title: "System audio",
                    detail: "Other participants — no bot joins the call",
                    trailing: {
                        if systemAudioResult == .captured {
                            Label("Granted", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(Tokens.successGreenText)
                                .font(Tokens.caption)
                        } else {
                            SystemAudioProbeButton(label: "Grant") { result in
                                systemAudioResult = result
                                settings.lastSystemAudioTapFailed = (result != .captured)
                            }
                            .tint(Tokens.accentBlue)
                        }
                    }
                )
            }
            .padding(16)
            .background(Tokens.subtleBackground, in: RoundedRectangle(cornerRadius: Tokens.radiusCard))

            Text("You can grant these later — Recap asks again on first record.")
                .font(Tokens.caption)
                .foregroundStyle(Tokens.textTertiary)
                .multilineTextAlignment(.center)
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
