import SwiftUI

/// Audio player bar docked at the bottom of the meeting detail view (where
/// the status bar sits) while the meeting has playable audio: play/pause,
/// elapsed, scrubber, total, speed chip. Spec: design handoff v2 §8d.
struct PlayerBar: View {
    let playback: PlaybackStore

    var body: some View {
        HStack(spacing: 10) {
            playPauseButton
            Text(Self.timestamp(playback.position))
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(Tokens.textSecondary)
                .frame(width: 34, alignment: .trailing)
            Slider(
                value: Binding(
                    get: { playback.position },
                    set: { playback.seek(to: $0) }
                ),
                in: 0...max(playback.duration, 1)
            )
            .tint(Tokens.accentBlue)
            Text(Self.timestamp(playback.duration))
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(Tokens.textSecondary)
                .frame(width: 34, alignment: .leading)
            rateChip
        }
        .padding(.horizontal, 16)
        .frame(height: 32)
        .background(Tokens.subtleBackground.opacity(0.9))
        .overlay(alignment: .top) { Divider() }
    }

    /// Round white 28pt play/pause button (mock 8d).
    private var playPauseButton: some View {
        Button(action: { playback.togglePlayPause() }) {
            Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.85))
                .frame(width: 28, height: 28)
                .background(Color.white, in: Circle())
                .overlay(Circle().stroke(Tokens.cardStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(playback.isPlaying ? "Pause" : "Play")
    }

    /// Speed chip cycling 1× / 1.5× / 2×.
    private var rateChip: some View {
        Button(action: { playback.cycleRate() }) {
            Text(Self.rateLabel(playback.rate))
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(Tokens.textSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Tokens.chipBackground, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Playback speed")
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

#Preview("Player bar") {
    let playback = PlaybackStore()
    return PlayerBar(playback: playback)
        .frame(width: 500)
}
