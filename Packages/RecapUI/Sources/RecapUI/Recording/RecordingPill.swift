import RecapCore
import SwiftUI

/// The docked recording pill shown in-window while recording (design mock
/// 6c): pulsing red dot, elapsed timer, live waveform, hairline divider,
/// round pause button, white Stop pill. Deliberately uncrowded — the privacy
/// badge lives in the meeting header now, the input-device name isn't shown
/// here, and there's no live-transcript snippet (the transcript pane already
/// shows that). While paused the dot goes static amber, a PAUSED micro-label
/// appears, and the timer freezes to a static string (a ticking
/// `Text(style: .timer)` cannot be frozen — rendering switches instead).
struct RecordingPill: View {
    var clock: RecordingClock
    var isPaused: Bool
    var levels: [Float]
    var onPauseToggle: () -> Void
    var onStop: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            PulsingDot(
                color: isPaused ? Tokens.warningAmber : Tokens.recordRed,
                pulsing: !isPaused
            )
            timer
            if isPaused {
                Text("PAUSED")
                    .font(Tokens.microLabel)
                    .foregroundStyle(Tokens.warningAmber)
                    .fixedSize()
            }
            waveform
            // stays: white-on-darkSurface hairline divider in both modes
            Rectangle()
                .fill(.white.opacity(0.15))
                .frame(width: 1, height: 18)
            Button(action: onPauseToggle) {
                // stays: dark glyph pinned to black on a solid white control-button
                // in both modes (Tokens.textPrimary would invert to near-white here)
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 27, height: 27)
                    .background(.white, in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("p", modifiers: [.command, .option])
            .help(isPaused ? "Resume recording (⌥⌘P)" : "Pause recording (⌥⌘P)")
            .axID(.recordingPauseButton)
            Button(action: onStop) {
                // stays: dark text pinned to black on a solid white control-button
                // in both modes (Tokens.textPrimary would invert to near-white here)
                Text("Stop")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(.white, in: Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(".", modifiers: .command)
            .axID(.recordingStopButton)
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .background(Tokens.darkSurface, in: Capsule())
        .overlay {
            // Separates the dark pill from an equally-dark window behind it.
            Capsule().stroke(Tokens.darkSurfaceStroke, lineWidth: 1)
        }
        // stays: shadow stays black in both modes
        .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
        // The bottom overlay proposes a narrow width; without this the HStack
        // compresses.
        .fixedSize()
        .accessibilityElement(children: .contain)
        .axID(.recordingPill)
    }

    /// Running: a TimelineView ticking from the clock's synthetic start date
    /// (so pauses already served are folded in). Paused: a static string.
    @ViewBuilder private var timer: some View {
        if isPaused {
            // stays: white-on-darkSurface pill internals in both modes
            Text(Self.elapsedLabel(seconds: Int(clock.elapsed(at: .now))))
                .font(Tokens.timer)
                .foregroundStyle(.white.opacity(0.7))
        } else {
            let start = clock.syntheticStartDate(at: .now)
            TimelineView(.periodic(from: start, by: 1)) { context in
                // stays: white-on-darkSurface pill internals in both modes
                Text(Self.elapsedLabel(seconds: max(0, Int(context.date.timeIntervalSince(start)))))
                    .font(Tokens.timer)
                    .foregroundStyle(.white)
            }
        }
    }

    private var waveform: some View {
        HStack(spacing: 2.5) {
            ForEach(levels.indices, id: \.self) { i in
                // stays: white-on-darkSurface pill internals in both modes
                Capsule()
                    .fill(.white.opacity(0.75))
                    .frame(width: 2.5, height: max(3, CGFloat(levels[i]) * 18))
            }
        }
        .frame(height: 18)
        .animation(.easeOut(duration: 0.12), value: levels)
    }

    static func elapsedLabel(seconds: Int) -> String {
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Downsamples the session's rolling RMS-level window to a small fixed count
/// of bars for compact waveform displays (the pill's 5 bars, the capsule's
/// 4) — pure so it's testable without `MeetingSessionStore`. Picks evenly
/// spaced samples from the source window rather than averaging, so a single
/// loud syllable still visibly pokes a bar instead of getting smoothed away.
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

struct PulsingDot: View {
    var color: Color = Tokens.recordRed
    /// False renders a steady dot (paused state) — a repeating animation
    /// must not keep breathing once the recording is frozen.
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

#Preview {
    VStack(spacing: 24) {
        RecordingPill(
            clock: RecordingClock(startedAt: .now.addingTimeInterval(-1453)),
            isPaused: false,
            levels: (0..<5).map { _ in Float.random(in: 0.1...0.9) },
            onPauseToggle: {},
            onStop: {}
        )
        RecordingPill(
            clock: {
                var clock = RecordingClock(startedAt: .now.addingTimeInterval(-1453))
                clock.pause(at: .now)
                return clock
            }(),
            isPaused: true,
            levels: [Float](repeating: 0, count: 5),
            onPauseToggle: {},
            onStop: {}
        )
    }
    .padding(40)
    .background(Tokens.surface)
}

#Preview("Dark") {
    VStack(spacing: 24) {
        RecordingPill(
            clock: RecordingClock(startedAt: .now.addingTimeInterval(-1453)),
            isPaused: false,
            levels: (0..<5).map { _ in Float.random(in: 0.1...0.9) },
            onPauseToggle: {},
            onStop: {}
        )
        RecordingPill(
            clock: {
                var clock = RecordingClock(startedAt: .now.addingTimeInterval(-1453))
                clock.pause(at: .now)
                return clock
            }(),
            isPaused: true,
            levels: [Float](repeating: 0, count: 5),
            onPauseToggle: {},
            onStop: {}
        )
    }
    .padding(40)
    .background(Tokens.surface)
    .preferredColorScheme(.dark)
}
