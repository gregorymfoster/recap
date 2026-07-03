import AVFoundation
import EventKit
import SwiftUI

/// A permission's status as shown in the Permissions section. Distinct from
/// the raw system enums, since the system-audio tap has no query API and
/// needs states the others don't (a "worked/failed last time" pair, plus a
/// transient "checking" state while a probe is running).
enum PermissionStatus: Equatable {
    case granted
    case denied
    case notDetermined
    /// System-audio only: a probe or recording is currently in flight.
    case checking
    /// System-audio only: the tap failed the last time it was attempted
    /// (either a real recording or an explicit "Test" probe).
    case unavailable
    /// System-audio only: the tap succeeded the last time it was attempted.
    /// Unlike mic/calendar, there's no query API to re-verify this live, so
    /// it's a distinct, more honest state than "Granted" — the permission
    /// could have been revoked since.
    case workedLastTime

    var label: String {
        switch self {
        case .granted: "Granted"
        case .denied: "Denied"
        case .notDetermined: "Not yet asked"
        case .checking: "Checking…"
        case .unavailable: "Unavailable at last attempt"
        case .workedLastTime: "Worked at last attempt"
        }
    }

    var color: Color {
        switch self {
        case .granted, .workedLastTime: Tokens.successGreenText
        case .denied, .unavailable: Tokens.warningAmberText
        case .notDetermined, .checking: Tokens.textTertiary
        }
    }

    var systemImage: String {
        switch self {
        case .granted, .workedLastTime: "checkmark.circle.fill"
        case .denied, .unavailable: "exclamationmark.triangle.fill"
        case .notDetermined: "circle.dashed"
        case .checking: "circle.dotted"
        }
    }
}

extension AVAudioApplication.recordPermission {
    var permissionStatus: PermissionStatus {
        switch self {
        case .granted: .granted
        case .denied: .denied
        default: .notDetermined
        }
    }
}

extension EKAuthorizationStatus {
    var permissionStatus: PermissionStatus {
        switch self {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }
}

extension PermissionStatus {
    /// System audio has no query API — only the outcome of the last tap
    /// attempt (a real recording or an explicit "Test" probe), persisted by
    /// `AppStores.startRecording()` / the Settings "Test" button.
    static func systemAudio(lastTapFailed: Bool?) -> PermissionStatus {
        switch lastTapFailed {
        case .some(true): .unavailable
        case .some(false): .workedLastTime
        case nil: .notDetermined
        }
    }
}

/// Which action a permission row should offer, as a pure function of status.
/// Modeled once so every row (Settings, Onboarding) stays in sync and the
/// mapping is exhaustively testable without a live view.
enum PermissionAction: Equatable {
    /// Request access in place (mic/calendar, when never asked).
    case allow
    /// Probe the system-audio tap in place — both requester and verifier,
    /// since macOS has no query API for this permission. Shown in every
    /// system-audio state, not just "not yet asked".
    case test
    /// Deep-link to the relevant System Settings pane (denied/unavailable).
    case openSystemSettings
    /// Nothing to do — granted, or a probe is currently running.
    case none
}

enum PermissionKind: Equatable {
    case microphone
    case calendar
    case systemAudio
}

extension PermissionStatus {
    /// The primary action a row should offer for the given permission kind.
    /// For system audio, `.denied`/`.unavailable` put "Open System Settings"
    /// in the primary slot, but the probe button stays available alongside it
    /// (see `showsSystemAudioProbe`) — after flipping the toggle there, a
    /// re-test is the only way the status can recover, since macOS has no
    /// query API for this permission.
    func action(for kind: PermissionKind) -> PermissionAction {
        switch kind {
        case .microphone, .calendar:
            switch self {
            case .notDetermined: .allow
            case .denied: .openSystemSettings
            case .granted, .checking, .unavailable, .workedLastTime: .none
            }
        case .systemAudio:
            switch self {
            case .checking: .none
            case .denied, .unavailable: .openSystemSettings
            case .granted, .notDetermined, .workedLastTime: .test
            }
        }
    }

    /// System audio only: whether the row should offer the probe button. The
    /// probe is the sole way to (re-)verify this permission, so every state
    /// offers it except an in-flight check — including `.denied` and
    /// `.unavailable`, where it's how the row recovers once the user has
    /// flipped the toggle in System Settings.
    var showsSystemAudioProbe: Bool {
        self != .checking
    }

    /// Probe button title: "Test Again" once an attempt has failed, so the
    /// recovery path after fixing System Settings reads naturally.
    var systemAudioProbeLabel: String {
        switch self {
        case .denied, .unavailable: "Test Again"
        case .granted, .notDetermined, .checking, .workedLastTime: "Test"
        }
    }

    /// One-line secondary text shown under a row that needs the user to go
    /// fix something in System Settings, or nil when there's nothing to add.
    func fixItHint(for kind: PermissionKind) -> String? {
        switch kind {
        case .microphone:
            switch self {
            case .denied: RecapCopy.microphoneDeniedHint
            default: nil
            }
        case .calendar:
            switch self {
            case .denied: RecapCopy.calendarDeniedHint
            default: nil
            }
        case .systemAudio:
            switch self {
            case .denied, .unavailable: RecapCopy.systemAudioDeniedHint
            case .notDetermined: RecapCopy.systemAudioNotDeterminedHint
            default: nil
            }
        }
    }
}
