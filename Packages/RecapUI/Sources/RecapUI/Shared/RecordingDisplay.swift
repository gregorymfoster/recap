import SwiftUI

/// Shared display helpers for every recording-state surface (`SessionCapsule`,
/// `RecordingView`, `MenuBarContent`, `FloatingIndicatorView`) — one capsule
/// component family per the Phase 3C redesign, so the pulsing dot, waveform
/// downsampling, and elapsed-time formatting live in exactly one place
/// instead of being duplicated per surface. Hoisted out of the now-deleted
/// `RecordingPill.swift`.

/// Downsamples the session's rolling RMS-level window to a small fixed count
/// of bars for compact waveform/meter displays — pure so it's testable
/// without `MeetingSessionStore`. Picks evenly spaced samples from the source
/// window rather than averaging, so a single loud syllable still visibly
/// pokes a bar instead of getting smoothed away.
enum WaveformDownsample {
    static func bars(from levels: [Float], count: Int) -> [Float] {
        guard count > 0 else { return [] }
        guard !levels.isEmpty else { return [Float](repeating: 0, count: count) }
        guard levels.count != count else { return levels }
        return (0..<count).map { i in
            let sourceIndex = levels.count == 1 ? 0 : (i * (levels.count - 1)) / max(1, count - 1)
            return levels[sourceIndex]
        }
    }
}

/// Formats a recording elapsed-time count as "MM:SS", or "H:MM:SS" once past
/// an hour — shared by the menu bar label, `SessionCapsule`'s timer, and
/// `RecordingView`'s live note-input placeholder tick.
enum ElapsedLabel {
    static func format(seconds: Int) -> String {
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// A small breathing dot indicating live recording — red while recording,
/// steady amber while paused (a repeating animation must not keep breathing
/// once the recording is frozen).
struct PulsingDot: View {
    var color: Color = Tokens.recordRed
    var pulsing: Bool = true
    var size: CGFloat = 9
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(pulsing && dimmed ? 0.35 : 1)
            .animation(
                pulsing ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .easeOut(duration: 0.15),
                value: dimmed
            )
            .onAppear { dimmed = pulsing }
            .onChange(of: pulsing) { _, pulsing in
                dimmed = pulsing
            }
    }
}
