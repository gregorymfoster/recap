import AppKit
import Observation
import SwiftUI

/// Owns a borderless, non-activating floating panel that shows a compact
/// recording indicator whenever Recap is recording and backgrounded — the
/// Granola-style "still recording" confidence capsule.
///
/// Show/hide is driven by three independent signals, all observed without
/// polling:
///   - App activation: `NSApplication.didBecomeActiveNotification` /
///     `didResignActiveNotification` via `NotificationCenter`.
///   - Session state: `session.isRecording` / `session.isPaused` via a
///     self-re-arming `withObservationTracking` loop (the standard pattern
///     for observing `@Observable` state outside SwiftUI view bodies).
///   - Settings: `settings.floatingCapsuleStyle` via the same
///     `withObservationTracking` mechanism — flipping to `.off` hides the
///     panel immediately even mid-recording.
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
    /// Position the user dragged the panel to, reused across show/hide
    /// cycles instead of resetting to the default corner. Persisted to
    /// UserDefaults so it survives relaunches too; validated against the
    /// currently connected screens before reuse, since a saved position from
    /// a since-disconnected external monitor must not strand the capsule
    /// offscreen.
    private var lastOrigin: NSPoint?
    private let positionStore: FloatingIndicatorPositionStore
    /// Style last used to size the panel's content — tracked so a
    /// `.minimal` ↔ `.full` change (different content width) triggers a
    /// re-fit instead of leaving stale dead space or clipping.
    private var lastStyle: FloatingCapsuleStyle?

    public init(stores: AppStores, positionStore: FloatingIndicatorPositionStore = FloatingIndicatorPositionStore()) {
        self.stores = stores
        self.positionStore = positionStore
        lastOrigin = positionStore.position
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
            _ = stores.settings.floatingCapsuleStyle
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshVisibility()
                self?.observeSessionState()
            }
        }
    }

    private func refreshVisibility() {
        let style = stores.settings.floatingCapsuleStyle
        let visible = FloatingIndicatorVisibility.isVisible(
            isRecording: stores.session.isRecording, isAppActive: isAppActive, style: style
        )
        if visible {
            showPanel(style: style)
        } else {
            hidePanel()
        }
    }

    // MARK: Panel lifecycle

    private func showPanel(style: FloatingCapsuleStyle) {
        if panel == nil {
            panel = makePanel()
            lastStyle = style
        } else if lastStyle != style {
            // `.minimal` and `.full` fit different content widths — resize in
            // place rather than tearing down and recreating the panel, which
            // would also drop the user's dragged position for this show.
            lastStyle = style
            refit(panel!)
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
        // Size the panel to exactly fit the capsule, so no invisible dead
        // area blocks clicks on windows underneath.
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
        placeAtStartingOrigin(panel)

        // Remember wherever the user drags it (in-memory for the rest of the
        // session, and persisted to UserDefaults for the next launch).
        let moveToken = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self, weak panel] _ in
            MainActor.assumeIsolated {
                guard let origin = panel?.frame.origin else { return }
                self?.lastOrigin = origin
                self?.positionStore.position = origin
            }
        }
        notificationTokens.append(moveToken)

        return panel
    }

    /// Re-fits an already-shown panel's content after a style change
    /// (`.minimal` ↔ `.full` sizes differently) without disturbing its
    /// current on-screen position, so the capsule doesn't jump to the
    /// default corner just because the user toggled a Settings option while
    /// it happened to be visible.
    private func refit(_ panel: NSPanel) {
        guard let hosting = panel.contentView as? FirstMouseHostingView<FloatingIndicatorHostView> else { return }
        let origin = panel.frame.origin
        let newSize = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: newSize)
        panel.setContentSize(newSize)
        panel.setFrameOrigin(origin)
    }

    /// Places a freshly created panel: reuses the last known/persisted
    /// position if it's still on some connected screen, otherwise falls
    /// back to the default bottom-right corner (e.g. first-ever launch, or
    /// an external monitor holding the saved position got disconnected).
    private func placeAtStartingOrigin(_ panel: NSPanel) {
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        if let origin = lastOrigin,
            FloatingIndicatorPlacement.isOnScreen(origin: origin, panelSize: panel.frame.size, visibleFrames: visibleFrames)
        {
            panel.setFrameOrigin(origin)
        } else if let screen = NSScreen.main {
            let origin = FloatingIndicatorPlacement.defaultOrigin(
                panelSize: panel.frame.size, visibleFrame: screen.visibleFrame
            )
            panel.setFrameOrigin(origin)
            lastOrigin = origin
        }
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
/// `MeetingSessionStore`/`SettingsStore`, so the hosting view re-renders on
/// the same `@Observable` change tracking as the rest of the app.
struct FloatingIndicatorHostView: View {
    let stores: AppStores
    let onActivate: () -> Void

    var body: some View {
        FloatingIndicatorView(
            style: stores.settings.floatingCapsuleStyle,
            isPaused: stores.session.isPaused,
            levels: WaveformDownsample.bars(from: stores.session.levels, count: 4),
            elapsedLabel: stores.session.menuBarElapsedLabel,
            onActivate: onActivate
        )
        .fixedSize()
    }
}
