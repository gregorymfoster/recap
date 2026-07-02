import RecapCore
import SwiftUI

/// Left pane of the split meeting view (design mock 1b): live or saved
/// transcript with the in-progress utterance at 40% opacity.
struct TranscriptPane: View {
    var utterances: [Utterance]
    var partial: Utterance?
    var isLive: Bool
    /// Health of the live pipeline, when `isLive` — nil for saved meetings.
    var liveState: LiveState?
    var onDownloadStreamingModel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(isLive ? "LIVE TRANSCRIPT" : "TRANSCRIPT")
                    .font(Tokens.microLabel)
                    .kerning(0.5)
                    .foregroundStyle(Tokens.textTertiary)
                if isLive {
                    liveStatusBadge
                } else {
                    OnDeviceBadge(label: "on-device")
                }
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 10)

            if utterances.isEmpty && partial == nil {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(utterances.enumerated()), id: \.element.id) { index, utterance in
                                let previous = index > 0 ? utterances[index - 1].speakerID : nil
                                if let speaker = utterance.speakerID, speaker != previous {
                                    speakerLabel(speaker)
                                        .padding(.top, index > 0 ? 6 : 0)
                                }
                                row(utterance)
                            }
                            if let partial {
                                row(partial)
                                    .opacity(0.4)
                                    .id("partial")
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(.horizontal, 22)
                        .padding(.bottom, 16)
                    }
                    .onChange(of: utterances.count) {
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .onChange(of: partial?.text) {
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }
        }
        .background(Tokens.subtleBackground)
    }

    /// Small header badge showing exactly where the live pipeline stands —
    /// replaces the plain "on-device" badge while recording so loading,
    /// live, missing-model, and failure states are visually distinct instead
    /// of all reading as an indefinite "Listening…".
    @ViewBuilder
    private var liveStatusBadge: some View {
        switch liveState {
        case .live, nil:
            HStack(spacing: 4) {
                Circle()
                    .fill(Tokens.successGreen)
                    .frame(width: 6, height: 6)
                Text("Live")
                    .font(Tokens.microLabel)
            }
            .foregroundStyle(Tokens.successGreenText)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Tokens.successGreenTint, in: RoundedRectangle(cornerRadius: Tokens.radiusChip))
        case .loadingModel:
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                Text("Loading live transcription…")
                    .font(Tokens.microLabel)
            }
            .foregroundStyle(Tokens.textSecondary)
        case .noModelInstalled:
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 9, weight: .semibold))
                Text("No transcription model installed")
                    .font(Tokens.microLabel)
            }
            .foregroundStyle(Tokens.warningAmberText)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Tokens.warningAmberTint, in: RoundedRectangle(cornerRadius: Tokens.radiusChip))
        case .failed:
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .semibold))
                Text("Live transcription unavailable")
                    .font(Tokens.microLabel)
            }
            .foregroundStyle(Tokens.warningAmberText)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Tokens.warningAmberTint, in: RoundedRectangle(cornerRadius: Tokens.radiusChip))
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch (isLive, liveState) {
        case (true, .noModelInstalled):
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Tokens.textTertiary)
                Text("No transcription model installed")
                    .font(Tokens.transcript)
                    .foregroundStyle(Tokens.textSecondary)
                Text("The full transcript will still be created after the meeting once a model is installed.")
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
                if let onDownloadStreamingModel {
                    Button("Download") { onDownloadStreamingModel() }
                        .buttonStyle(.borderedProminent)
                        .tint(Tokens.accentBlue)
                        .controlSize(.small)
                }
            }
        case (true, .failed):
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Tokens.textTertiary)
                Text("Live transcription unavailable")
                    .font(Tokens.transcript)
                    .foregroundStyle(Tokens.textSecondary)
                Text("The full transcript will still be created after the meeting.")
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.textTertiary)
            }
        case (true, .loadingModel):
            VStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading live transcription…")
                    .font(Tokens.transcript)
                    .foregroundStyle(Tokens.textTertiary)
            }
        case (true, .live), (true, nil):
            VStack(spacing: 6) {
                Text("Listening…")
                    .font(Tokens.transcript)
                    .foregroundStyle(Tokens.textTertiary)
                Text("Transcript appears a few seconds behind the conversation.")
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.textTertiary)
            }
        case (false, _):
            Text("No transcript yet")
                .font(Tokens.transcript)
                .foregroundStyle(Tokens.textTertiary)
        }
    }

    private func row(_ utterance: Utterance) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(timestamp(utterance.start))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Tokens.textTertiary)
                .frame(width: 38, alignment: .trailing)
            Text(utterance.text)
                .font(Tokens.transcript)
                .lineSpacing(4)
                .foregroundStyle(Tokens.textBody)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "S1" → "Speaker 1", colored consistently per speaker (mock 1b).
    private func speakerLabel(_ speakerID: String) -> some View {
        Text(displayName(for: speakerID))
            .font(Tokens.microLabel)
            .kerning(0.4)
            .foregroundStyle(color(for: speakerID))
            .padding(.leading, 48)  // aligns with the text column
    }

    private func displayName(for speakerID: String) -> String {
        if let number = speakerNumber(speakerID) { return "Speaker \(number)" }
        return speakerID
    }

    private func color(for speakerID: String) -> Color {
        guard let number = speakerNumber(speakerID), number >= 1 else { return Tokens.textSecondary }
        return Tokens.speakerPalette[(number - 1) % Tokens.speakerPalette.count]
    }

    private func speakerNumber(_ speakerID: String) -> Int? {
        guard speakerID.hasPrefix("S") else { return nil }
        return Int(speakerID.dropFirst())
    }

    private func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

#Preview("Live") {
    TranscriptPane(
        utterances: [
            Utterance(speakerID: "S1", start: 0, end: 4, text: "Hello everyone, thanks for joining."),
            Utterance(speakerID: "S1", start: 4, end: 9, text: "Today we're walking through the Q3 roadmap and the onboarding revamp."),
            Utterance(speakerID: "S2", start: 9, end: 14, text: "Sounds good — I have the metrics from last week ready to share."),
        ],
        partial: Utterance(start: 14, end: 16, text: "Maya, do you want to start with"),
        isLive: true,
        liveState: .live
    )
    .frame(width: 420, height: 500)
}

#Preview("No model installed") {
    TranscriptPane(utterances: [], partial: nil, isLive: true, liveState: .noModelInstalled, onDownloadStreamingModel: {})
        .frame(width: 420, height: 500)
}

#Preview("Loading") {
    TranscriptPane(utterances: [], partial: nil, isLive: true, liveState: .loadingModel)
        .frame(width: 420, height: 500)
}

#Preview("Failed") {
    TranscriptPane(utterances: [], partial: nil, isLive: true, liveState: .failed(reason: "load error"))
        .frame(width: 420, height: 500)
}
