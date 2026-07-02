import RecapCore
import SwiftUI

/// Left pane of the split meeting view (design mock 1b): live or saved
/// transcript with the in-progress utterance at 40% opacity.
struct TranscriptPane: View {
    var utterances: [Utterance]
    var partial: Utterance?
    var isLive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(isLive ? "LIVE TRANSCRIPT" : "TRANSCRIPT")
                    .font(Tokens.microLabel)
                    .kerning(0.5)
                    .foregroundStyle(Tokens.textTertiary)
                OnDeviceBadge(label: "on-device")
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 10)

            if utterances.isEmpty && partial == nil {
                VStack(spacing: 6) {
                    if isLive {
                        Text("Listening…")
                            .font(Tokens.transcript)
                            .foregroundStyle(Tokens.textTertiary)
                        Text("Transcript appears a few seconds behind the conversation.")
                            .font(Tokens.caption)
                            .foregroundStyle(Tokens.textTertiary)
                    } else {
                        Text("No transcript yet")
                            .font(Tokens.transcript)
                            .foregroundStyle(Tokens.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(utterances) { utterance in
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

    private func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

#Preview {
    TranscriptPane(
        utterances: [
            Utterance(start: 0, end: 4, text: "Hello everyone, thanks for joining."),
            Utterance(start: 4, end: 9, text: "Today we're walking through the Q3 roadmap and the onboarding revamp."),
        ],
        partial: Utterance(start: 9, end: 11, text: "Maya, do you want to start with"),
        isLive: true
    )
    .frame(width: 420, height: 500)
}
