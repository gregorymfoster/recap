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
    /// Opens Sparkle's standard update dialog. Set by the app target.
    @ObservationIgnored public var install: (() -> Void)?

    public init() {}

    public func markAvailable() { isAvailable = true }

    /// The indicator was clicked — present the update dialog. Sparkle owns the
    /// availability state from here, so we don't clear `isAvailable` ourselves.
    public func triggerInstall() { install?() }
}
