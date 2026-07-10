import Observation

/// UI-facing update state, framework-agnostic so `RecapUI` stays Sparkle-free.
/// The app target owns the real updater (see `Recap/Updater.swift`), flips
/// `isAvailable` when a background check finds a new version, and wires
/// `install` to present Sparkle's standard update dialog.
@MainActor
@Observable
public final class UpdateStatus {
    /// True once a background ("scheduled") check has found a newer version.
    public private(set) var isAvailable = false
    /// The newest version a background check has found, when Sparkle
    /// supplied one (e.g. "1.4.0"). `nil` when unknown — copy sites fall
    /// back to a version-less phrasing.
    public private(set) var availableVersion: String?
    /// True once the Library update banner has been dismissed for the
    /// current `availableVersion`. A genuinely newer version (a different
    /// non-nil `availableVersion`) resets this so the banner reappears.
    public private(set) var isBannerDismissed = false
    /// Opens Sparkle's standard update dialog. Set by the app target.
    @ObservationIgnored public var install: (@MainActor () -> Void)?

    public init() {}

    /// Records that a newer version is available. A DIFFERENT non-nil
    /// `version` than the current `availableVersion` resets `isBannerDismissed`
    /// so the banner reappears for the newly-found version; the same version
    /// leaves dismissal alone (repeated scheduled checks re-confirming the
    /// same update shouldn't un-dismiss a banner the user already closed).
    /// Never overwrites a known `availableVersion` with `nil`.
    public func markAvailable(version: String? = nil) {
        if let version, version != availableVersion {
            isBannerDismissed = false
        }
        isAvailable = true
        if let version {
            availableVersion = version
        }
    }

    /// The Library banner's dismiss control — hides the banner without
    /// clearing `isAvailable` (the menu bar's install affordance stays put).
    public func dismissBanner() {
        isBannerDismissed = true
    }

    /// Whether the Library update banner should render: available, and not
    /// dismissed for the currently-known version.
    public var showsBanner: Bool { isAvailable && !isBannerDismissed }

    /// The indicator was clicked — present the update dialog. Sparkle owns the
    /// availability state from here, so we don't clear `isAvailable` ourselves.
    public func triggerInstall() { install?() }
}
