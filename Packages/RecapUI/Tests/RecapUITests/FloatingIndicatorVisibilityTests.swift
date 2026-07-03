import CoreGraphics
import Testing
@testable import RecapUI

/// `FloatingIndicatorVisibility.isVisible` — the pure show/hide rule for the
/// Granola-style floating recording capsule: visible only while recording
/// AND Recap is not the frontmost app.
@Suite struct FloatingIndicatorVisibilityTests {
    @Test func hiddenWhenNotRecordingAndAppInactive() {
        #expect(!FloatingIndicatorVisibility.isVisible(isRecording: false, isAppActive: false))
    }

    @Test func hiddenWhenNotRecordingAndAppActive() {
        #expect(!FloatingIndicatorVisibility.isVisible(isRecording: false, isAppActive: true))
    }

    @Test func hiddenWhenRecordingButAppActive() {
        #expect(!FloatingIndicatorVisibility.isVisible(isRecording: true, isAppActive: true))
    }

    @Test func visibleWhenRecordingAndAppInactive() {
        #expect(FloatingIndicatorVisibility.isVisible(isRecording: true, isAppActive: false))
    }

    /// Paused recordings are still "recording" per `MeetingSessionStore` —
    /// the visibility rule only takes the flattened `isRecording` bool, so
    /// pause state can never hide the capsule independent of app activation.
    @Test func pausedRecordingStillCountsAsRecordingForVisibility() {
        // isPaused is not a parameter of isVisible at all — this documents
        // that the caller must pass isRecording (activeRecord != nil), not
        // some pause-aware derivative.
        #expect(FloatingIndicatorVisibility.isVisible(isRecording: true, isAppActive: false))
    }
}

/// `FloatingIndicatorPlacement.defaultOrigin` — pure first-show placement:
/// trailing edge, center at the upper third, clamped inside the frame.
@Suite struct FloatingIndicatorPlacementTests {
    // A 1512x945 visible frame at a 25pt menu-bar offset, like a 14" MBP.
    private let frame = CGRect(x: 0, y: 0, width: 1512, height: 920)
    private let panel = CGSize(width: 260, height: 40)

    @Test func hugsTrailingEdgeWithInset() {
        let origin = FloatingIndicatorPlacement.defaultOrigin(panelSize: panel, visibleFrame: frame)
        #expect(origin.x == frame.maxX - 16 - panel.width)
    }

    @Test func centersPanelAtUpperThird() {
        let origin = FloatingIndicatorPlacement.defaultOrigin(panelSize: panel, visibleFrame: frame)
        // Panel center at 2/3 of the frame height (AppKit y grows upward).
        #expect(origin.y == frame.minY + frame.height * 2 / 3 - panel.height / 2)
    }

    @Test func respectsCustomInset() {
        let origin = FloatingIndicatorPlacement.defaultOrigin(
            panelSize: panel, visibleFrame: frame, inset: 32
        )
        #expect(origin.x == frame.maxX - 32 - panel.width)
    }

    @Test func clampsTallPanelInsideShortFrame() {
        let tall = CGSize(width: 260, height: 900)
        let short = CGRect(x: 0, y: 0, width: 1512, height: 400)
        let origin = FloatingIndicatorPlacement.defaultOrigin(panelSize: tall, visibleFrame: short)
        // Bottom clamp wins once the top clamp would push it below minY.
        #expect(origin.y == short.minY + 16)
    }

    @Test func clampsTopEdgeWhenUpperThirdWouldOverflow() {
        let tallish = CGSize(width: 260, height: 320)
        let short = CGRect(x: 0, y: 0, width: 1512, height: 500)
        let origin = FloatingIndicatorPlacement.defaultOrigin(panelSize: tallish, visibleFrame: short)
        #expect(origin.y == short.maxY - 16 - tallish.height)
        #expect(origin.y >= short.minY + 16)
    }

    @Test func honorsNonZeroFrameOrigin() {
        // Secondary display arranged to the right and above the main one.
        let offset = CGRect(x: 1512, y: 200, width: 1000, height: 700)
        let origin = FloatingIndicatorPlacement.defaultOrigin(panelSize: panel, visibleFrame: offset)
        #expect(origin.x == offset.maxX - 16 - panel.width)
        #expect(origin.y == offset.minY + offset.height * 2 / 3 - panel.height / 2)
    }
}
