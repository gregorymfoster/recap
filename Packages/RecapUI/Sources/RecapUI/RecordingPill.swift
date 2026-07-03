import RecapCore
import SwiftUI

/// The floating dark capsule shown while recording (design mock 1a):
/// pulsing red dot, elapsed timer, live waveform, "local" caption,
/// pause/resume, Stop. While paused the dot goes static amber, a PAUSED
/// micro-label appears, and the timer freezes to a static string (a ticking
/// `Text(style: .timer)` cannot be frozen — rendering switches instead).
struct RecordingPill: View {
    var clock: RecordingClock
    var isPaused: Bool
    var levels: [Float]
    /// Name of the mic in use, when it's known — shown as a small hoverable
    /// label so the pill stays compact but the device is still visible.
    var inputDeviceName: String?
    /// Latest confirmed live-transcription text, shown as a one-line rolling
    /// snippet under the waveform so confidence is visible even without the
    /// main window open — the whole point of the light streaming pass.
    var lastHeardText: String?
    var onPauseToggle: () -> Void
    var onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8))
                        Text("local")
                            .font(Tokens.microLabel)
                            .fixedSize()
                    }
                    if let inputDeviceName {
                        Text(inputDeviceName)
                            .font(Tokens.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 110, alignment: .leading)
                    }
                }
                .foregroundStyle(.white.opacity(0.55))
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(.white.opacity(0.15))
                        .frame(width: 1, height: 18)
                }
                .help(inputDeviceName.map { "Recording from \($0)" } ?? "")
                Button(action: onPauseToggle) {
                    Image(systemName: isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Tokens.textPrimary)
                        .frame(width: 27, height: 27)
                        .background(.white, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("p", modifiers: [.command, .option])
                .help(isPaused ? "Resume recording (⌥⌘P)" : "Pause recording (⌥⌘P)")
                Button(action: onStop) {
                    Text("Stop")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Tokens.textPrimary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(".", modifiers: .command)
            }
            if let lastHeardText, !lastHeardText.isEmpty {
                Text(lastHeardText)
                    .font(Tokens.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 360, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        // A plain Capsule reads as a pill for the single-line case; once the
        // "last heard" line pushes the pill taller, a Capsule's semicircular
        // ends would look increasingly stretched, so use a fixed radius that
        // stays pill-like at both heights.
        .background(Tokens.darkSurface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
        // The bottom overlay proposes a narrow width; without this the HStack
        // compresses — "local" wraps and the Stop label truncates to "…".
        .fixedSize()
        .animation(.easeOut(duration: 0.15), value: lastHeardText)
    }

    /// Running: a TimelineView ticking from the clock's synthetic start date
    /// (so pauses already served are folded in). Paused: a static string.
    @ViewBuilder private var timer: some View {
        if isPaused {
            Text(Self.elapsedLabel(seconds: Int(clock.elapsed(at: .now))))
                .font(Tokens.timer)
                .foregroundStyle(.white.opacity(0.7))
        } else {
            let start = clock.syntheticStartDate(at: .now)
            TimelineView(.periodic(from: start, by: 1)) { context in
                Text(Self.elapsedLabel(seconds: max(0, Int(context.date.timeIntervalSince(start)))))
                    .font(Tokens.timer)
                    .foregroundStyle(.white)
            }
        }
    }

    private var waveform: some View {
        HStack(spacing: 2.5) {
            ForEach(levels.indices, id: \.self) { i in
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
            levels: (0..<16).map { _ in Float.random(in: 0.1...0.9) },
            inputDeviceName: "AirPods Pro",
            lastHeardText: "…so I think we should ship the onboarding revamp next sprint.",
            onPauseToggle: {},
            onStop: {}
        )
        RecordingPill(
            clock: RecordingClock(startedAt: .now.addingTimeInterval(-1453)),
            isPaused: false,
            levels: (0..<16).map { _ in Float.random(in: 0.1...0.9) },
            inputDeviceName: "AirPods Pro",
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
            levels: [Float](repeating: 0, count: 16),
            inputDeviceName: "AirPods Pro",
            onPauseToggle: {},
            onStop: {}
        )
    }
    .padding(40)
    .background(.white)
}
