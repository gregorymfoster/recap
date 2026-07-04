import SwiftUI

/// Accessibility identifiers for the Calendar feature's "Meeting started?"
/// nudge (design mock 9b). Covers all three `MeetingNudgeView` variants
/// (ask-with-match, ask-app-only, recordingStarted) since they share one
/// view — see `-fixtures -show-nudge` / `NudgePreviewDebugView`.
extension AXID {
    /// The nudge card container (`MeetingNudgeView`'s root `VStack`).
    public static let nudgePanel = AXID("nudge-panel")

    /// The red "Record" pill button, shown for `.ask` nudges
    /// (`MeetingNudgeView.recordButton`).
    public static let nudgeRecordButton = AXID("nudge-record-button")

    /// The "Not now" dismiss button, shown for `.ask` nudges
    /// (`MeetingNudgeView.notNowButton`).
    public static let nudgeDismissButton = AXID("nudge-dismiss-button")

    /// The "Don't ask for <app>" link, shown for `.ask` nudges triggered by a
    /// call app (`MeetingNudgeView.actionRow`).
    public static let nudgeDontAskButton = AXID("nudge-dont-ask-button")

    /// The "Stop" button, shown for `.recordingStarted` nudges
    /// (`MeetingNudgeView.actionRow`).
    public static let nudgeStopButton = AXID("nudge-stop-button")
}
