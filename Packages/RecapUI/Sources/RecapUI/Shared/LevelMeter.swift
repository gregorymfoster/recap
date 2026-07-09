import SwiftUI

/// Five vertical audio-level bars, downsampled from an arbitrary-length
/// levels buffer via `WaveformDownsample` — small and fixed-size so it drops
/// into both the session capsule and a Settings row unchanged.
struct LevelMeter: View {
    var levels: [Float]
    var barCount: Int = 5
    var barWidth: CGFloat = 3
    var maxBarHeight: CGFloat = 14
    var minBarHeight: CGFloat = 3

    private var bars: [Float] {
        WaveformDownsample.bars(from: levels, count: barCount)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, level in
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(level > 0.05 ? Tokens.meterActive : Tokens.meterInactive)
                    .frame(width: barWidth, height: barHeight(for: level))
            }
        }
        .frame(height: maxBarHeight)
        .animation(.easeOut(duration: 0.1), value: bars)
    }

    private func barHeight(for level: Float) -> CGFloat {
        let clamped = max(0, min(1, CGFloat(level)))
        return minBarHeight + (maxBarHeight - minBarHeight) * clamped
    }
}
