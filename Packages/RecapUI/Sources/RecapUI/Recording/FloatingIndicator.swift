import AppKit
import RecapCore
import SwiftUI

/// Pure visibility rule for the floating recording indicator: visible only
/// while a recording is active and Recap itself isn't the frontmost app.
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
/// and Recap is backgrounded — a Granola-style confidence indicator. Phase 3C:
/// this is now a thin wrapper around `SessionCapsule(.floating)` — the one
/// capsule component family, shared with the docked capsule `RecordingView`
/// hosts, rather than a separate hand-rolled implementation. Unlike the old
/// click-only capsule, the floating variant now carries real pause/stop
/// buttons (nested `Button`s inside the outer activate button — the
/// innermost view claims the tap first, so pause/stop don't also activate
/// Recap); tapping anywhere else on the capsule still activates Recap and
/// brings the live meeting forward.
struct FloatingIndicatorView: View {
    var clock: RecordingClock
    var isPaused: Bool
    var levels: [Float]
    var onActivate: () -> Void
    var onPauseToggle: () -> Void
    var onStop: () -> Void

    var body: some View {
        Button(action: onActivate) {
            SessionCapsule(
                variant: .floating, clock: clock, isPaused: isPaused, levels: levels,
                onPauseToggle: onPauseToggle, onStop: onStop
            )
        }
        // `SessionCapsule` already draws its own capsule background/stroke/
        // shadow — this wrapper contributes no chrome of its own, it only
        // turns "tap anywhere on the capsule" into `onActivate`.
        .buttonStyle(FloatingIndicatorActivateButtonStyle())
    }
}

private struct FloatingIndicatorActivateButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

#Preview("States") {
    VStack(alignment: .leading, spacing: 16) {
        FloatingIndicatorView(
            clock: RecordingClock(startedAt: .now.addingTimeInterval(-761)),
            isPaused: false,
            levels: (0..<4).map { _ in Float.random(in: 0.2...0.9) },
            onActivate: {}, onPauseToggle: {}, onStop: {}
        )
        FloatingIndicatorView(
            clock: {
                var clock = RecordingClock(startedAt: .now.addingTimeInterval(-761))
                clock.pause(at: .now)
                return clock
            }(),
            isPaused: true,
            levels: [Float](repeating: 0, count: 4),
            onActivate: {}, onPauseToggle: {}, onStop: {}
        )
    }
    .padding(40)
    .background(
        LinearGradient(colors: [Color(red: 0.24, green: 0.29, blue: 0.36), Color(red: 0.16, green: 0.19, blue: 0.25)], startPoint: .top, endPoint: .bottom)
    )
}
