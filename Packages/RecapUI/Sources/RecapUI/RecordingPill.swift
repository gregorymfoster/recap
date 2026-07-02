import SwiftUI

/// The floating dark capsule shown while recording (design mock 1a):
/// pulsing red dot, elapsed timer, live waveform, "local" caption, Stop.
struct RecordingPill: View {
    var startedAt: Date
    var levels: [Float]
    var onStop: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            PulsingDot()
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text(elapsedLabel(at: context.date))
                    .font(Tokens.timer)
                    .foregroundStyle(.white)
            }
            waveform
            HStack(spacing: 4) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8))
                Text("local")
                    .font(Tokens.microLabel)
                    .fixedSize()
            }
            .foregroundStyle(.white.opacity(0.55))
            .padding(.leading, 12)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(.white.opacity(0.15))
                    .frame(width: 1, height: 18)
            }
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
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .background(Tokens.darkSurface, in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
        // The bottom overlay proposes a narrow width; without this the HStack
        // compresses — "local" wraps and the Stop label truncates to "…".
        .fixedSize()
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

    private func elapsedLabel(at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(startedAt)))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct PulsingDot: View {
    var color: Color = Tokens.recordRed
    var size: CGFloat = 9
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(dimmed ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: dimmed)
            .onAppear { dimmed = true }
    }
}

#Preview {
    RecordingPill(
        startedAt: .now.addingTimeInterval(-1453),
        levels: (0..<16).map { _ in Float.random(in: 0.1...0.9) },
        onStop: {}
    )
    .padding(40)
    .background(.white)
}
