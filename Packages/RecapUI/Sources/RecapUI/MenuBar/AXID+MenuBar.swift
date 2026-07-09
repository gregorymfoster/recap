import SwiftUI

/// Accessibility identifiers for `MenuBar/` — the menu bar extra's popover
/// content. The global `.menuBarContent` root anchor lives in
/// `Shared/AccessibilityIdentifiers.swift`; everything below is specific to
/// controls inside it. Reachable for automation via the `-show-menubar-content`
/// debug window (combined with `-fixtures`).
extension AXID {
    /// Idle-state "Start recording" row.
    public static let menuBarStartRecordingButton = AXID("menu-bar-start-recording-button")

    /// Recording-header pause/resume toggle button.
    public static let menuBarPauseButton = AXID("menu-bar-pause-button")

    /// Recording-header "Stop" button.
    public static let menuBarStopButton = AXID("menu-bar-stop-button")

    /// "Open meeting" row (recording state) — jumps to the active meeting.
    public static let menuBarOpenMeetingButton = AXID("menu-bar-open-meeting-button")

    /// "Open Recap" row (idle state) — activates the main window.
    public static let menuBarOpenAppButton = AXID("menu-bar-open-app-button")

    /// "Settings…" row.
    public static let menuBarSettingsButton = AXID("menu-bar-settings-button")

    /// "Quit Recap" row.
    public static let menuBarQuitButton = AXID("menu-bar-quit-button")

    /// "Update Available — Install…" row, shown only when a background
    /// Sparkle check found a newer version.
    public static let menuBarUpdateAvailableButton = AXID("menu-bar-update-available-button")

    /// "Record" button on the "Up next · Calendar" row.
    public static let menuBarUpNextRecordButton = AXID("menu-bar-up-next-record-button")

    /// A single row in the "Recent" section, keyed by the meeting's id.
    public static func menuBarRecentRow(_ id: String) -> AXID { AXID("menu-bar-recent-row-\(id)") }

    /// The menu bar popover's input-device menu (`InputDeviceMenu`,
    /// Phase 0 scaffolding for the redesigned popover).
    public static let menuBarDeviceMenu = AXID("menu-bar-device-menu")
}
