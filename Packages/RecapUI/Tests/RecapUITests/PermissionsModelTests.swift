import AVFoundation
import EventKit
import Testing
@testable import RecapUI

@Suite struct PermissionsModelTests {
    // MARK: - AVAudioApplication.recordPermission → PermissionStatus

    @Test(arguments: [
        (AVAudioApplication.recordPermission.granted, PermissionStatus.granted),
        (.denied, .denied),
        (.undetermined, .notDetermined),
    ])
    func micPermissionStatusMapsExhaustively(
        input: AVAudioApplication.recordPermission, expected: PermissionStatus
    ) {
        #expect(input.permissionStatus == expected)
    }

    // MARK: - EKAuthorizationStatus → PermissionStatus

    @Test(arguments: [
        (EKAuthorizationStatus.fullAccess, PermissionStatus.granted),
        (.notDetermined, .notDetermined),
        (.denied, .denied),
        (.restricted, .denied),
        (.writeOnly, .denied),
    ])
    func calendarPermissionStatusMapsExhaustively(
        input: EKAuthorizationStatus, expected: PermissionStatus
    ) {
        #expect(input.permissionStatus == expected)
    }

    // MARK: - System audio tri-state

    @Test func systemAudioStatusNilMeansNotDetermined() {
        #expect(PermissionStatus.systemAudio(lastTapFailed: nil) == .notDetermined)
    }

    @Test func systemAudioStatusFalseMeansWorkedLastTime() {
        #expect(PermissionStatus.systemAudio(lastTapFailed: false) == .workedLastTime)
    }

    @Test func systemAudioStatusTrueMeansUnavailable() {
        #expect(PermissionStatus.systemAudio(lastTapFailed: true) == .unavailable)
    }

    // MARK: - PermissionAction: microphone & calendar

    @Test(arguments: [
        (PermissionStatus.notDetermined, PermissionAction.allow),
        (.denied, .openSystemSettings),
        (.granted, .none),
        (.checking, .none),
        (.unavailable, .none),
        (.workedLastTime, .none),
    ])
    func microphoneActionIsPureFunctionOfStatus(status: PermissionStatus, expected: PermissionAction) {
        #expect(status.action(for: .microphone) == expected)
    }

    @Test(arguments: [
        (PermissionStatus.notDetermined, PermissionAction.allow),
        (.denied, .openSystemSettings),
        (.granted, .none),
        (.checking, .none),
        (.unavailable, .none),
        (.workedLastTime, .none),
    ])
    func calendarActionIsPureFunctionOfStatus(status: PermissionStatus, expected: PermissionAction) {
        #expect(status.action(for: .calendar) == expected)
    }

    // MARK: - PermissionAction: system audio (every state offers .test except denied/unavailable/checking)

    @Test(arguments: [
        (PermissionStatus.notDetermined, PermissionAction.test),
        (.granted, .test),
        (.workedLastTime, .test),
        (.denied, .openSystemSettings),
        (.unavailable, .openSystemSettings),
        (.checking, .none),
    ])
    func systemAudioActionIsPureFunctionOfStatus(status: PermissionStatus, expected: PermissionAction) {
        #expect(status.action(for: .systemAudio) == expected)
    }

    // MARK: - System audio probe availability & label

    @Test(arguments: [
        PermissionStatus.granted, .denied, .notDetermined, .unavailable, .workedLastTime,
    ])
    func everySettledStatusOffersSystemAudioProbe(status: PermissionStatus) {
        #expect(status.showsSystemAudioProbe)
    }

    @Test func checkingHidesSystemAudioProbe() {
        #expect(!PermissionStatus.checking.showsSystemAudioProbe)
    }

    @Test(arguments: [
        (PermissionStatus.denied, "Test Again"),
        (.unavailable, "Test Again"),
        (.granted, "Test"),
        (.notDetermined, "Test"),
        (.workedLastTime, "Test"),
    ])
    func probeLabelReflectsFailureState(status: PermissionStatus, expected: String) {
        #expect(status.systemAudioProbeLabel == expected)
    }

    // MARK: - Fix-it hints

    @Test func microphoneDeniedShowsHint() {
        #expect(PermissionStatus.denied.fixItHint(for: .microphone) == RecapCopy.microphoneDeniedHint)
    }

    @Test(arguments: [PermissionStatus.granted, .notDetermined, .checking, .unavailable, .workedLastTime])
    func microphoneNonDeniedShowsNoHint(status: PermissionStatus) {
        #expect(status.fixItHint(for: .microphone) == nil)
    }

    @Test func calendarDeniedShowsHint() {
        #expect(PermissionStatus.denied.fixItHint(for: .calendar) == RecapCopy.calendarDeniedHint)
    }

    @Test(arguments: [PermissionStatus.granted, .notDetermined, .checking, .unavailable, .workedLastTime])
    func calendarNonDeniedShowsNoHint(status: PermissionStatus) {
        #expect(status.fixItHint(for: .calendar) == nil)
    }

    @Test(arguments: [PermissionStatus.denied, .unavailable])
    func systemAudioDeniedOrUnavailableShowsDeniedHint(status: PermissionStatus) {
        #expect(status.fixItHint(for: .systemAudio) == RecapCopy.systemAudioDeniedHint)
    }

    @Test func systemAudioNotDeterminedShowsExpectationHint() {
        #expect(PermissionStatus.notDetermined.fixItHint(for: .systemAudio) == RecapCopy.systemAudioNotDeterminedHint)
    }

    @Test(arguments: [PermissionStatus.granted, .checking, .workedLastTime])
    func systemAudioOtherStatesShowNoHint(status: PermissionStatus) {
        #expect(status.fixItHint(for: .systemAudio) == nil)
    }

    // MARK: - Label / systemImage exhaustiveness (sanity, not colors — see color test below)

    @Test(arguments: [
        PermissionStatus.granted, .denied, .notDetermined, .checking, .unavailable, .workedLastTime,
    ])
    func everyStatusHasANonEmptyLabelAndSystemImage(status: PermissionStatus) {
        #expect(!status.label.isEmpty)
        #expect(!status.systemImage.isEmpty)
    }

    // MARK: - Colors
    //
    // Dynamic NSColor `.resolve(in:)` (used under the hood by Tokens' dynamic
    // colors) deadlocks off-main, so any test touching `.color` must be
    // @MainActor.

    @MainActor
    @Test(arguments: [PermissionStatus.granted, .workedLastTime])
    func successStatusesUseSuccessColor(status: PermissionStatus) {
        #expect(status.color == Tokens.successGreenText)
    }

    @MainActor
    @Test(arguments: [PermissionStatus.denied, .unavailable])
    func problemStatusesUseWarningColor(status: PermissionStatus) {
        #expect(status.color == Tokens.warningAmberText)
    }

    @MainActor
    @Test(arguments: [PermissionStatus.notDetermined, .checking])
    func neutralStatusesUseTertiaryColor(status: PermissionStatus) {
        #expect(status.color == Tokens.textTertiary)
    }
}
