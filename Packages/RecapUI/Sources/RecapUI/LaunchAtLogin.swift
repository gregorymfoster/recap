import Observation
import ServiceManagement

/// Whether launch-at-login is currently registered, in `SMAppService`'s own
/// vocabulary. `.requiresApproval` means the user must flip it on in System
/// Settings → General → Login Items (macOS shows this instead of failing
/// outright the first time an app registers); `.notFound` only appears if the
/// app isn't a proper installed bundle (e.g. running from a build folder).
public enum LaunchAtLoginStatus: Equatable, Sendable {
    case enabled
    case disabled
    case requiresApproval
    case notFound

    init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notFound: self = .notFound
        case .notRegistered: self = .disabled
        @unknown default: self = .disabled
        }
    }

    /// Toggle position: on for `.enabled`/`.requiresApproval` (registered
    /// either way — the user just also needs to flip the System Settings
    /// switch for the latter), off otherwise.
    public var isOn: Bool {
        switch self {
        case .enabled, .requiresApproval: true
        case .disabled, .notFound: false
        }
    }

    /// Footnote shown under the toggle. `nil` in the common case (enabled or
    /// plainly disabled) — only worth a note when something needs the user's
    /// attention.
    public var footnote: String? {
        switch self {
        case .requiresApproval:
            "Recap needs one more step — allow it in System Settings → General → Login Items."
        case .notFound:
            "Launch at login isn't available for this build."
        case .enabled, .disabled:
            nil
        }
    }
}

/// Registers/unregisters Recap as a login item via `SMAppService.mainApp`.
/// A thin, mockable wrapper so `SettingsGeneralTab` never talks to
/// `ServiceManagement` directly — errors (e.g. `SMAppServiceError`) are
/// swallowed into `lastErrorMessage` rather than thrown, since there's no
/// good in-line recovery for a Settings toggle beyond telling the user what
/// happened and leaving the toggle in its actual (unregistered) state.
@MainActor
@Observable
public final class LaunchAtLoginController {
    public private(set) var status: LaunchAtLoginStatus
    public private(set) var lastErrorMessage: String?

    private let service: SMAppService

    public init(service: SMAppService = .mainApp) {
        self.service = service
        status = LaunchAtLoginStatus(service.status)
    }

    public func refresh() {
        status = LaunchAtLoginStatus(service.status)
    }

    public func setEnabled(_ enabled: Bool) {
        lastErrorMessage = nil
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            lastErrorMessage = "Couldn't \(enabled ? "enable" : "disable") launch at login: \(error.localizedDescription)"
        }
        status = LaunchAtLoginStatus(service.status)
    }
}
