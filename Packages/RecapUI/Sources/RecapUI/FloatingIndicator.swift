import AppKit
import RecapCore
import SwiftUI

/// Pure visibility rule for the floating recording indicator: visible only
/// while a recording is active, Recap itself isn't the frontmost app, AND
/// the user hasn't turned the capsule off in Settings. Extracted so the
/// show/hide decision is unit-testable without an NSPanel, NSApplication
/// activation notifications, or `withObservationTracking`.
public enum FloatingIndicatorVisibility {
    /// - Parameters:
    ///   - isRecording: `MeetingSessionStore.isRecording` — true for the
    ///     whole recording, including while paused.
    ///   - isAppActive: Whether Recap is the frontmost application
    ///     (`NSApplication.shared.isActive`, tracked via
    ///     `didBecomeActive`/`didResignActive` notifications).
    ///   - style: `SettingsStore.floatingCapsuleStyle` — `.off` hides the
    ///     capsule unconditionally, regardless of the other two.
    public static func isVisible(
        isRecording: Bool, isAppActive: Bool, style: FloatingCapsuleStyle
    ) -> Bool {
        style != .off && isRecording && !isAppActive
    }
}

/// Pure placement math for the floating panel's first show: bottom-right
/// corner of the screen's visible frame (above the Dock, since
/// `visibleFrame` already excludes it), inset from the trailing/bottom
/// edges. Extracted from `FloatingIndicatorController` (house pattern) so
/// it's testable without an `NSScreen`.
public enum FloatingIndicatorPlacement {
    public static func defaultOrigin(
        panelSize: CGSize, visibleFrame frame: CGRect, inset: CGFloat = 16
    ) -> CGPoint {
        let x = max(frame.minX + inset, frame.maxX - inset - panelSize.width)
        let y = frame.minY + inset
        return CGPoint(x: x, y: y)
    }

    /// Whether a persisted panel origin still places the panel fully inside
    /// some connected screen's visible frame — used to reject a
    /// stale/offscreen saved position (external monitor disconnected,
    /// resolution changed) at restore, falling back to `defaultOrigin`
    /// instead of appearing off the edge of the world.
    public static func isOnScreen(
        origin: CGPoint, panelSize: CGSize, visibleFrames: [CGRect]
    ) -> Bool {
        let frame = CGRect(origin: origin, size: panelSize)
        return visibleFrames.contains { $0.contains(frame) }
    }
}

/// Compact always-on-top capsule shown at the screen edge while recording
/// and Recap is backgrounded — a Granola-style confidence indicator. Visually
/// a smaller sibling of `RecordingPill`: same dark-surface chrome and
/// `PulsingDot`, but with only a click target (no pause/stop controls) since
/// it's meant to be glanced at, not operated. Content follows
/// `SettingsStore.floatingCapsuleStyle`: `.minimal` is dot + timer only,
/// `.full` adds a small waveform. On hover the capsule brightens and the
/// waveform (when present) swaps for an "Open Recap ↗" label.
struct FloatingIndicatorView: View {
    var style: FloatingCapsuleStyle
    var isPaused: Bool
    var levels: [Float]
    var elapsedLabel: String?
    var onActivate: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            PulsingDot(
                color: isPaused ? Tokens.warningAmber : Tokens.recordRed,
                pulsing: !isPaused,
                size: 7
            )
            if isPaused {
                Text("Paused")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            if let elapsedLabel {
                Text(elapsedLabel)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(isPaused ? 0.45 : 0.85))
                    .fixedSize()
            }
            if isHovering {
                // stays: white-on-darkSurface hairline divider + label in both modes
                Rectangle()
                    .fill(.white.opacity(0.15))
                    .frame(width: 1, height: 12)
                HStack(spacing: 4) {
                    Text("Open Recap")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .fixedSize()
            } else if style == .full, !isPaused {
                waveform
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            (isHovering ? FloatingIndicatorTokens.hoverSurface : FloatingIndicatorTokens.idleSurface),
            in: Capsule()
        )
        .overlay {
            Capsule().stroke(.white.opacity(isHovering ? 0.14 : 0.08), lineWidth: 1)
        }
        // No SwiftUI .shadow here: it would clip at the panel's bounds. The
        // NSPanel draws the drop shadow (hasShadow) around the capsule
        // silhouette instead.
        .contentShape(Capsule())
        .onTapGesture(perform: onActivate)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var waveform: some View {
        HStack(spacing: 2) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(.white.opacity(0.4))
                    .frame(width: 2, height: max(2, CGFloat(levels[i]) * 10))
            }
        }
        .frame(height: 10)
        .animation(.easeOut(duration: 0.12), value: levels)
    }
}

/// Fixed (non-dynamic) surface colors for the capsule's idle/hover states —
/// per design mock 7a these are specific alpha values on a near-black,
/// independent of `Tokens.darkSurface`'s light/dark split, since the capsule
/// always floats over arbitrary desktop content rather than app chrome.
private enum FloatingIndicatorTokens {
    static let idleSurface = Color(red: 32 / 255, green: 32 / 255, blue: 34 / 255).opacity(0.88)
    static let hoverSurface = Color(red: 40 / 255, green: 40 / 255, blue: 42 / 255).opacity(0.98)
}

#Preview("States") {
    VStack(alignment: .leading, spacing: 16) {
        FloatingIndicatorView(
            style: .full, isPaused: false,
            levels: (0..<4).map { _ in Float.random(in: 0.2...0.9) },
            elapsedLabel: "12:41", onActivate: {}
        )
        FloatingIndicatorView(
            style: .minimal, isPaused: false,
            levels: [], elapsedLabel: "12:41", onActivate: {}
        )
        FloatingIndicatorView(
            style: .full, isPaused: true,
            levels: [Float](repeating: 0, count: 4),
            elapsedLabel: "12:41", onActivate: {}
        )
    }
    .padding(40)
    .background(
        LinearGradient(colors: [Color(red: 0.24, green: 0.29, blue: 0.36), Color(red: 0.16, green: 0.19, blue: 0.25)], startPoint: .top, endPoint: .bottom)
    )
}
