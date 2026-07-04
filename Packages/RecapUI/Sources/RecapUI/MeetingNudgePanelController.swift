import AppKit
import SwiftUI

/// Owns a borderless, non-activating floating panel that slides in from the
/// top-right to show the "Meeting started?" nudge (design mock 9b). Panel
/// machinery mirrors `FloatingIndicatorController` (borderless +
/// nonactivating, `.floating` level, all-spaces + full-screen-auxiliary,
/// clear background, first-mouse-accepting host view) — cloned rather than
/// shared since the two controllers' show/hide lifecycles differ (this one
/// slides in/out and auto-dismisses; the capsule doesn't).
@MainActor
public final class MeetingNudgePanelController {
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    /// Inset from the screen's `visibleFrame` top-right corner.
    private static let edgeInset: CGFloat = 16
    /// The panel starts this far above its resting position and slides down
    /// into place.
    private static let slideDistance: CGFloat = 20
    private static let slideDuration: TimeInterval = 0.25
    private static let autoDismissDelay: Duration = .seconds(30)

    /// Wired by the owner (`AppStores`) to the actions a shown nudge can
    /// take. Kept as closures — like `MeetingNudgeCenter` — so this
    /// controller never needs to know about `AppStores` or the center
    /// directly; it only knows how to host and animate a `MeetingNudgeView`.
    public var onRecord: ((MeetingNudge) -> Void)?
    public var onNotNow: ((MeetingNudge) -> Void)?
    public var onDontAsk: ((String) -> Void)?
    public var onStop: (() -> Void)?

    public init() {}

    /// Replaces whatever's currently shown with `nudge`, animating in a
    /// fresh slide if the panel wasn't already visible.
    public func present(_ nudge: MeetingNudge) {
        dismissTask?.cancel()

        let wasVisible = panel?.isVisible ?? false
        let appID: String? = {
            if case .ask(let appID, _, _) = nudge { return appID }
            return nil
        }()
        let content = MeetingNudgeView(
            nudge: nudge,
            onRecord: { [weak self] in
                self?.onRecord?(nudge)
                self?.dismiss()
            },
            onNotNow: { [weak self] in
                self?.onNotNow?(nudge)
                self?.dismiss()
            },
            onDontAsk: appID.map { id in
                { [weak self] in
                    self?.onDontAsk?(id)
                    self?.dismiss()
                }
            },
            onStop: { [weak self] in
                self?.onStop?()
                self?.dismiss()
            }
        )
        .fixedSize()
        let hosting = FirstMouseHostingView(rootView: content)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)

        let panel = self.panel ?? makePanel()
        panel.contentView = hosting
        panel.setContentSize(hosting.frame.size)
        placeAtRestingOrigin(panel)
        self.panel = panel

        if wasVisible {
            panel.orderFrontRegardless()
            panel.animator().alphaValue = 1
        } else {
            slideIn(panel)
        }

        armAutoDismiss()
    }

    /// Animates the panel out (alpha fade), then orders it out.
    public func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.slideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
            }
        }
    }

    private func armAutoDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: Self.autoDismissDelay)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Not draggable — this is a transient nudge, not a persistent
        // capsule; no fake drag affordance either.
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        return panel
    }

    /// Top-right of the main screen's visible frame, inset by `edgeInset`.
    private func restingOrigin(for size: NSSize) -> NSPoint? {
        guard let screen = NSScreen.main else { return nil }
        let frame = screen.visibleFrame
        let x = frame.maxX - size.width - Self.edgeInset
        let y = frame.maxY - size.height - Self.edgeInset
        return NSPoint(x: x, y: y)
    }

    private func placeAtRestingOrigin(_ panel: NSPanel) {
        guard let origin = restingOrigin(for: panel.frame.size) else { return }
        panel.setFrameOrigin(origin)
    }

    /// Slides the panel in: starts `slideDistance` above the resting
    /// position with alpha 0, then animates down to rest with alpha 1.
    private func slideIn(_ panel: NSPanel) {
        guard let restOrigin = restingOrigin(for: panel.frame.size) else {
            panel.orderFrontRegardless()
            return
        }
        let startOrigin = NSPoint(x: restOrigin.x, y: restOrigin.y + Self.slideDistance)
        panel.setFrameOrigin(startOrigin)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.slideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrameOrigin(restOrigin)
            panel.animator().alphaValue = 1
        }
    }
}

/// Hosting view for the non-activating panel: the panel never becomes key,
/// so every click is a "first mouse" — without this override the initial
/// click would only order the window forward instead of reaching the SwiftUI
/// tap gesture. Mirrors `FloatingIndicatorController`'s private equivalent
/// (kept file-private here since Swift has no cross-file `private` sharing
/// without making it internal, and this controller shouldn't reach into
/// the capsule's).
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
