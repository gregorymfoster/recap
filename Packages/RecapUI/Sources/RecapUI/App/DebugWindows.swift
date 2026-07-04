import RecapCore
import SwiftUI

/// Content view for the `-show-menubar-content` debug window: the menu bar
/// extra's popover normally lives in the status-item overflow, which screen
/// capture and UI-automation tooling can't reach headlessly, so this hosts
/// the same `MenuBarContent` view in an ordinary, screenshot-able window.
public struct MenuBarContentDebugView: View {
    let stores: AppStores

    public init(stores: AppStores) {
        self.stores = stores
    }

    public var body: some View {
        MenuBarContent(stores: stores)
            .background(Tokens.surface)
    }
}

/// Opens the (launch-suppressed) debug windows at launch when their flags
/// are passed. Lives on `RootView`'s window rather than the debug windows'
/// own bodies, since `openWindow` needs a scene that's actually created to
/// call from — a suppressed window's content view never runs its body until
/// something opens it. Which windows open is decided by the parsed
/// `LaunchConfiguration` (see `opensMenuBarContentWindow` /
/// `opensNudgePreviewWindow`), so the decision itself is unit-tested.
public struct DebugWindowOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    let configuration: LaunchConfiguration

    public init(configuration: LaunchConfiguration) {
        self.configuration = configuration
    }

    public func body(content: Content) -> some View {
        content.task {
            if configuration.opensMenuBarContentWindow {
                openWindow(id: DebugWindowID.menuBarContent)
            }
            if configuration.opensNudgePreviewWindow {
                openWindow(id: DebugWindowID.nudgePreview)
            }
        }
    }
}

/// Scene IDs for the debug windows — shared between the app shell's scene
/// declarations and `DebugWindowOpener` so they can't drift apart.
public enum DebugWindowID {
    public static let menuBarContent = "menubar-content-debug"
    public static let nudgePreview = "nudge-preview-debug"
}

/// Content view for the `-fixtures -show-nudge` debug window: stacks all
/// three `MeetingNudgeView` variants (ask with a calendar match, ask
/// app-only, and the auto-record confirmation) so the fixture app can
/// screenshot every state of design mock 9b in one shot. Pure view hosting —
/// no `MeetingNudgePanelController`, no `MeetingNudgeCenter` — so nothing
/// here can misfire a real nudge.
public struct NudgePreviewDebugView: View {
    private static let now = Date.now

    private static let matchedEvent = CalendarEventSnapshot(
        id: "nudge-preview-match",
        title: "Design crit — mobile",
        start: now.addingTimeInterval(-30),
        end: now.addingTimeInterval(30 * 60),
        otherAttendees: ["Maya Chen", "Priya Patel"],
        hasConferenceURL: true,
        conferenceProvider: "Zoom"
    )

    private static let recordingEvent = CalendarEventSnapshot(
        id: "nudge-preview-recording",
        title: "Roadmap review",
        start: now.addingTimeInterval(-40),
        end: now.addingTimeInterval(20 * 60),
        otherAttendees: ["Jordan Lee"],
        hasConferenceURL: true,
        conferenceProvider: "Zoom"
    )

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            MeetingNudgeView(
                nudge: .ask(appID: "us.zoom.xos", appName: "Zoom", match: Self.matchedEvent),
                onRecord: {}, onNotNow: {}, onDontAsk: {}
            )
            MeetingNudgeView(
                nudge: .ask(appID: "com.microsoft.teams2", appName: "Microsoft Teams", match: nil),
                onRecord: {}, onNotNow: {}, onDontAsk: {}
            )
            MeetingNudgeView(
                nudge: .recordingStarted(event: Self.recordingEvent, missedSeconds: 40),
                onRecord: {}, onNotNow: {}, onStop: {}
            )
        }
        .padding(24)
        .background(Tokens.surface)
    }
}
