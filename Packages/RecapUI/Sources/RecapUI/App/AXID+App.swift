import SwiftUI

/// Accessibility identifiers for `App/` — the app root, onboarding sheet, and
/// the Library-back-navigation toolbar item. See `Shared/AccessibilityIdentifiers.swift`
/// for the naming convention.
extension AXID {
    // MARK: Root

    /// The `RootView`'s top-level `NavigationSplitView` root.
    public static let rootView = AXID("root-view")

    /// "‹ Library" back button shown in the meeting detail toolbar.
    public static let libraryBackButton = AXID("library-back-button")

    // MARK: Onboarding — footer

    /// Footer "Back" button (steps 2-3).
    public static let onboardingBackButton = AXID("onboarding-back-button")

    /// Footer "Continue" / "Skip for now" button (steps 1-2).
    public static let onboardingContinueButton = AXID("onboarding-continue-button")

    /// Footer "Start using Recap" button (step 3, final).
    public static let onboardingFinishButton = AXID("onboarding-finish-button")

    // MARK: Onboarding — model step

    /// "Download" button on the recommended-model card.
    public static let onboardingDownloadRecommendedModelButton = AXID("onboarding-download-recommended-model-button")

    /// "Choose" button on the secondary (tiny) model row.
    public static let onboardingChooseSecondaryModelButton = AXID("onboarding-choose-secondary-model-button")

    // MARK: Onboarding — permissions step

    /// Microphone permission row's action button ("Allow" or "Open Settings").
    public static let onboardingPermissionMicButton = AXID("onboarding-permission-mic-button")

    /// System-audio permission row's "Grant" probe button.
    public static let onboardingPermissionSystemAudioButton = AXID("onboarding-permission-system-audio-button")
}
