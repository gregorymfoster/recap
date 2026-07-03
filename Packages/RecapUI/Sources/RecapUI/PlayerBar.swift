import SwiftUI

/// Audio player bar docked at the bottom of the meeting detail view (where
/// the status bar sits) while the meeting has playable audio: play/pause,
/// elapsed, scrubber, total, speed chip. Spec: design handoff v2 §8d.
struct PlayerBar: View {
    let playback: PlaybackStore

    var body: some View {
        HStack(spacing: 10) {
            Button(action: { playback.togglePlayPause() }) {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.plain)
            Text(Self.timestamp(playback.position))
                .font(Tokens.caption.monospacedDigit())
            Slider(
                value: Binding(
                    get: { playback.position },
                    set: { playback.seek(to: $0) }
                ),
                in: 0...max(playback.duration, 1)
            )
            Text(Self.timestamp(playback.duration))
                .font(Tokens.caption.monospacedDigit())
            Button(action: { playback.cycleRate() }) {
                Text(Self.rateLabel(playback.rate))
                    .font(Tokens.caption.monospacedDigit())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let (m, s) = (total / 60, total % 60)
        return String(format: "%d:%02d", m, s)
    }

    static func rateLabel(_ rate: Double) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : "\(rate)×"
    }
}
