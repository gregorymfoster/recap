import AppKit
import RecapCore
import SwiftUI

/// Pure visibility rule for the floating recording indicator: visible only
/// while a recording is active AND Recap itself isn't the frontmost app.
/// Extracted so the show/hide decision is unit-testable without an NSPanel,
/// NSApplication activation notifications, or `withObservationTracking`.
public enum FloatingIndicatorVisibility {
    /// - Parameters:
    ///   - isRecording: `MeetingSessionStore.isRecording` — true for the
    ///     whole recording, including while paused.
    ///   - isAppActive: Whether Recap is the frontmost application
    ///     (`NSApplication.shared.isActive`, tracked via
    ///     `didBecomeActive`/`didResignActive` notifications).
    public static func isVisible(isRecording: Bool, isAppActive: Bool) -> Bool {
        isRecording && !isAppActive
    }
}

/// Pure placement math for the floating panel's first show: trailing edge of
/// the screen's visible frame, panel center at the upper third, inset from
/// the edges, clamped so a tall panel or tiny screen never lands offscreen.
/// Extracted from `FloatingIndicatorController` (house pattern) so it's
/// testable without an `NSScreen`.
public enum FloatingIndicatorPlacement {
    public static func defaultOrigin(
        panelSize: CGSize, visibleFrame frame: CGRect, inset: CGFloat = 16
    ) -> CGPoint {
        let x = max(frame.minX + inset, frame.maxX - inset - panelSize.width)
        // "Upper third" visually: panel center 2/3 of the way up the visible
        // frame (AppKit y grows upward), then clamped inside the frame.
        var y = frame.minY + frame.height * 2 / 3 - panelSize.height / 2
        y = min(y, frame.maxY - inset - panelSize.height)
        y = max(y, frame.minY + inset)
        return CGPoint(x: x, y: y)
    }
}

/// Compact always-on-top capsule shown at the screen edge while recording
/// and Recap is backgrounded — a Granola-style confidence indicator.
/// Visually a smaller sibling of `RecordingPill`: same dark-surface chrome,
/// `PulsingDot`, and waveform, but with only a click target (no pause/stop
/// controls) since it's meant to be glanced at, not operated.
struct FloatingIndicatorView: View {
    var isPaused: Bool
    var levels: [Float]
    var elapsedLabel: String?
    var lastHeardText: String?
    var onActivate: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            PulsingDot(
                color: isPaused ? Tokens.warningAmber : Tokens.recordRed,
                pulsing: !isPaused,
                size: 8
            )
            if let elapsedLabel {
                Text(elapsedLabel)
                    .font(Tokens.timer)
                    .foregroundStyle(.white)
                    .fixedSize()
            }
            waveform
            if let lastHeardText, !lastHeardText.isEmpty {
                Text(lastHeardText)
                    .font(Tokens.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        // Fixed width: the panel is sized once from the hosting view's
        // fitting size, so the capsule must not grow/shrink as the elapsed
        // label or "last heard" snippet changes.
        .frame(width: 260, alignment: .leading)
        .background(Tokens.darkSurface, in: Capsule())
        .overlay {
            Capsule().stroke(Tokens.darkSurfaceStroke, lineWidth: 1)
        }
        // No SwiftUI .shadow here: it would clip at the panel's bounds. The
        // NSPanel draws the drop shadow (hasShadow) around the capsule
        // silhouette instead.
        .contentShape(Capsule())
        .onTapGesture(perform: onActivate)
    }

    private var waveform: some View {
        HStack(spacing: 2) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(.white.opacity(0.75))
                    .frame(width: 2, height: max(2, CGFloat(levels[i]) * 12))
            }
        }
        .frame(height: 12)
        .animation(.easeOut(duration: 0.12), value: levels)
    }
}
