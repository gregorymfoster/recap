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
/// bottom-right corner (above the Dock, via `visibleFrame`), inset from the
/// trailing/bottom edges.
@Suite struct FloatingIndicatorPlacementTests {
    // A 1512x945 visible frame at a 25pt menu-bar offset, like a 14" MBP.
    private let frame = CGRect(x: 0, y: 0, width: 1512, height: 920)
    private let panel = CGSize(width: 150, height: 30)

    @Test func hugsTrailingEdgeWithInset() {
        let origin = FloatingIndicatorPlacement.defaultOrigin(panelSize: panel, visibleFrame: frame)
        #expect(origin.x == frame.maxX - 16 - panel.width)
    }

    @Test func hugsBottomEdgeWithInset() {
        let origin = FloatingIndicatorPlacement.defaultOrigin(panelSize: panel, visibleFrame: frame)
        // AppKit y grows upward, so "bottom" is minY + inset.
        #expect(origin.y == frame.minY + 16)
    }

    @Test func respectsCustomInset() {
        let origin = FloatingIndicatorPlacement.defaultOrigin(
            panelSize: panel, visibleFrame: frame, inset: 32
        )
        #expect(origin.x == frame.maxX - 32 - panel.width)
        #expect(origin.y == frame.minY + 32)
    }

    @Test func honorsNonZeroFrameOrigin() {
        // Secondary display arranged to the right and above the main one.
        let offset = CGRect(x: 1512, y: 200, width: 1000, height: 700)
        let origin = FloatingIndicatorPlacement.defaultOrigin(panelSize: panel, visibleFrame: offset)
        #expect(origin.x == offset.maxX - 16 - panel.width)
        #expect(origin.y == offset.minY + 16)
    }
}

/// `FloatingIndicatorPlacement.isOnScreen` — validates a persisted position
/// still lands fully inside some connected screen before reusing it.
@Suite struct FloatingIndicatorOnScreenTests {
    private let panel = CGSize(width: 150, height: 30)
    private let mainScreen = CGRect(x: 0, y: 0, width: 1512, height: 920)

    @Test func onScreenWhenFullyInsideAKnownFrame() {
        let origin = CGPoint(x: 1000, y: 100)
        #expect(FloatingIndicatorPlacement.isOnScreen(origin: origin, panelSize: panel, visibleFrames: [mainScreen]))
    }

    @Test func offScreenWhenNoFrameContainsIt() {
        // A saved position from a since-disconnected external monitor.
        let origin = CGPoint(x: 3000, y: 100)
        #expect(!FloatingIndicatorPlacement.isOnScreen(origin: origin, panelSize: panel, visibleFrames: [mainScreen]))
    }

    @Test func offScreenWhenPartiallyOffTheEdge() {
        let origin = CGPoint(x: mainScreen.maxX - 10, y: 100)
        #expect(!FloatingIndicatorPlacement.isOnScreen(origin: origin, panelSize: panel, visibleFrames: [mainScreen]))
    }

    @Test func onScreenWhenAnySecondDisplayContainsIt() {
        let secondDisplay = CGRect(x: 1512, y: 0, width: 1000, height: 700)
        let origin = CGPoint(x: 1600, y: 50)
        #expect(FloatingIndicatorPlacement.isOnScreen(
            origin: origin, panelSize: panel, visibleFrames: [mainScreen, secondDisplay]
        ))
    }

    @Test func offScreenWithNoScreensAtAll() {
        #expect(!FloatingIndicatorPlacement.isOnScreen(origin: .zero, panelSize: panel, visibleFrames: []))
    }
}
