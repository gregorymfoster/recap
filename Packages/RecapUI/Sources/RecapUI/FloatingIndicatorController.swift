import AppKit
import Observation
import SwiftUI

/// Owns a borderless, non-activating floating panel that shows a compact
/// recording indicator whenever Recap is recording and backgrounded — the
/// Granola-style "still recording" confidence capsule.
///
/// Show/hide is driven by two independent signals, both observed without
/// polling:
///   - App activation: `NSApplication.didBecomeActiveNotification` /
///     `didResignActiveNotification` via `NotificationCenter`.
///   - Session state: `session.isRecording` / `session.isPaused` via a
///     self-re-arming `withObservationTracking` loop (the standard pattern
///     for observing `@Observable` state outside SwiftUI view bodies).
@MainActor
public final class FloatingIndicatorController {
    private let stores: AppStores
    private var panel: NSPanel?
    // `NSApp` is still nil when this controller is constructed in
    // `RecapApp.init` (before `NSApplicationMain` finishes wiring the shared
    // application), so reading `NSApp.isActive` there force-unwrap-crashes on
    // launch. The app isn't active yet at init regardless; the first
    // `didBecomeActiveNotification` (observed below) flips this true.
    private var isAppActive = NSApp?.isActive ?? false
    private var notificationTokens: [NSObjectProtocol] = []
    /// Position the user dragged the panel to this session; reused across
    /// show/hide cycles instead of resetting to the default corner. Not
    /// persisted to disk — in-memory only, per the spec.
    private var lastOrigin: NSPoint?

    public init(stores: AppStores) {
        self.stores = stores
        observeAppActivation()
        observeSessionState()
    }

    // No deinit-time observer teardown: this controller is owned by
    // `RecapApp` for the whole process lifetime (constructed once in
    // `RecapApp.init`, never released), so there is no meaningful
    // "controller goes away while the app keeps running" case to clean up
    // for. Swift 6 also disallows touching non-Sendable stored state (an
    // `[NSObjectProtocol]` of notification tokens) from a nonisolated
    // `deinit`, so this isn't just skippable but actively blocked without an
    // unsafe opt-out.

    // MARK: App activation

    private func observeAppActivation() {
        let center = NotificationCenter.default
        let becomeActive = center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isAppActive = true
                self?.refreshVisibility()
            }
        }
        let resignActive = center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isAppActive = false
                self?.refreshVisibility()
            }
        }
        notificationTokens = [becomeActive, resignActive]
    }

    // MARK: Session observation

    /// A clean re-arming `withObservationTracking` loop: the closure reads
    /// the properties we care about (arming tracking for them), and the
    /// `onChange` handler re-invokes this same function so tracking never
    /// lapses. No Timer, no polling.
    private func observeSessionState() {
        withObservationTracking {
            _ = stores.session.isRecording
            _ = stores.session.isPaused
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshVisibility()
                self?.observeSessionState()
            }
        }
    }

    private func refreshVisibility() {
        let visible = FloatingIndicatorVisibility.isVisible(
            isRecording: stores.session.isRecording, isAppActive: isAppActive
        )
        if visible {
            showPanel()
        } else {
            hidePanel()
        }
    }

    // MARK: Panel lifecycle

    private func showPanel() {
        if panel == nil {
            panel = makePanel()
        }
        panel?.orderFrontRegardless()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let content = FloatingIndicatorHostView(stores: stores) { [weak self] in
            self?.activate()
        }
        let hosting = FirstMouseHostingView(rootView: content)
        // Size the panel to exactly fit the capsule (the view has a fixed
        // 260pt width), so no invisible dead area blocks clicks on windows
        // underneath.
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)

        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // AppKit draws the drop shadow around the capsule's silhouette; the
        // SwiftUI view deliberately has no .shadow (it would clip at the
        // panel's bounds).
        panel.hasShadow = true
        // NSPanel defaults this to true, which would hide the panel the
        // moment Recap deactivates — the exact moment it must appear.
        panel.hidesOnDeactivate = false
        // We only ever orderOut, never close, but don't risk AppKit
        // releasing the panel out from under our strong reference.
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        panel.setContentSize(hosting.frame.size)

        if let origin = lastOrigin {
            panel.setFrameOrigin(origin)
        } else if let screen = NSScreen.main {
            panel.setFrameOrigin(FloatingIndicatorPlacement.defaultOrigin(
                panelSize: panel.frame.size, visibleFrame: screen.visibleFrame
            ))
        }

        // Remember wherever the user drags it, for the rest of the session.
        let moveToken = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self, weak panel] _ in
            MainActor.assumeIsolated {
                self?.lastOrigin = panel?.frame.origin
            }
        }
        notificationTokens.append(moveToken)

        return panel
    }

    // MARK: Click action

    /// Activates Recap, brings forward (or recreates) the main window, and
    /// navigates to the currently-recording meeting.
    private func activate() {
        // Route first so the window shows the live meeting from its first
        // frame, whether it's merely ordered forward or fully recreated.
        if let record = stores.session.activeRecord {
            stores.showMeeting(record.meeting.id)
        }
        NSApp.activate(ignoringOtherApps: true)
        // SwiftUI names WindowGroup windows "<id>-AppWindow-<n>"
        // ("main-AppWindow-1"), so match on the prefix, not equality.
        if let mainWindow = NSApp.windows.first(where: {
            let id = $0.identifier?.rawValue
            return id == "main" || id?.hasPrefix("main-") == true
        }) {
            mainWindow.makeKeyAndOrderFront(nil)
        } else {
            // The window was fully closed. `openWindow` is only reachable
            // from a View/Scene @Environment, so instead route through the
            // standard reopen path — the same one a Dock-icon click takes —
            // which SwiftUI's application delegate answers by recreating the
            // WindowGroup window.
            _ = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
        }
    }
}

/// Hosting view for the non-activating panel: the panel never becomes key,
/// so every click is a "first mouse" — without this override the initial
/// click would only order the window forward instead of reaching the SwiftUI
/// tap gesture.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Thin SwiftUI wrapper feeding `FloatingIndicatorView` from the live
/// `MeetingSessionStore`, so the hosting view re-renders on the same
/// `@Observable` change tracking as the rest of the app.
private struct FloatingIndicatorHostView: View {
    let stores: AppStores
    let onActivate: () -> Void

    var body: some View {
        FloatingIndicatorView(
            isPaused: stores.session.isPaused,
            levels: stores.session.levels,
            elapsedLabel: stores.session.menuBarElapsedLabel,
            lastHeardText: stores.session.lastHeardText,
            onActivate: onActivate
        )
        .fixedSize()
    }
}
