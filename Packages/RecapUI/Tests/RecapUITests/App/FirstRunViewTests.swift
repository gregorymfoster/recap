import Foundation
import Testing
@testable import RecapUI

@Suite struct FirstRunModelProgressTests {
    @Test func byteLabelRoundsProgressToNearestMB() {
        // 0.34 * 626 = 212.84 → rounds to 213, matching the design spec's
        // "213 MB of 626 MB" example verbatim.
        #expect(FirstRunModelProgress.byteLabel(progress: 0.34, totalMB: 626) == "213 MB of 626 MB")
    }

    @Test func byteLabelAtZeroProgress() {
        #expect(FirstRunModelProgress.byteLabel(progress: 0, totalMB: 626) == "0 MB of 626 MB")
    }

    @Test func byteLabelAtFullProgress() {
        #expect(FirstRunModelProgress.byteLabel(progress: 1, totalMB: 626) == "626 MB of 626 MB")
    }

    @Test func byteLabelClampsOutOfRangeProgress() {
        // Defensive: a stray negative or >1 fraction (shouldn't happen, but
        // this is rendered straight from observed state) must never produce
        // a negative or over-total byte count.
        #expect(FirstRunModelProgress.byteLabel(progress: -0.2, totalMB: 100) == "0 MB of 100 MB")
        #expect(FirstRunModelProgress.byteLabel(progress: 1.5, totalMB: 100) == "100 MB of 100 MB")
    }
}

/// First-run gating: `RootView` shows the sheet iff `!settings.hasOnboarded`
/// (see `RootView.body`'s `.sheet(isPresented: .constant(!settings.hasOnboarded))`).
/// `SettingsStore.ephemeral(onboarded:)` is the seam the `firstRun` fixture
/// scenario (and this test) uses to control that gate without touching real
/// `UserDefaults`.
@MainActor
@Suite struct FirstRunGatingTests {
    @Test func ephemeralOnboardedFalseGatesFirstRunVisible() {
        let store = SettingsStore.ephemeral(onboarded: false)
        #expect(store.hasOnboarded == false)
    }

    @Test func ephemeralOnboardedTrueGatesFirstRunHidden() {
        let store = SettingsStore.ephemeral(onboarded: true)
        #expect(store.hasOnboarded == true)
    }

    @Test func startButtonActionOnboardsRegardlessOfSetupOrPermissionState() {
        // Mirrors `FirstRunView`'s "Start using Recap" action: it always
        // sets `hasOnboarded = true` unconditionally — never gated on
        // `TranscriptionSetupStore.phase` or permission status.
        let store = SettingsStore.ephemeral(onboarded: false)
        #expect(store.hasOnboarded == false)
        store.hasOnboarded = true
        #expect(store.hasOnboarded == true)
    }

    @Test func ephemeralIsIsolatedPerCallLikeEphemeralOnboarded() {
        let first = SettingsStore.ephemeral(onboarded: false)
        first.mirrorBackupEnabled = true

        let second = SettingsStore.ephemeral(onboarded: false)
        #expect(second.mirrorBackupEnabled == false)
    }
}

/// First-run's system-audio row previously dead-ended after a denied tap: the
/// "Allow" button just re-ran the probe forever with no way to reach System
/// Settings. `FirstRunSystemAudioCopy.probeLabel(for:)` is the pure mapping
/// that now also drives showing an "Open System Settings…" fix-it alongside
/// the probe once `PermissionStatus.action(for: .systemAudio)` says so.
@Suite struct FirstRunSystemAudioCopyTests {
    @Test(arguments: [
        (PermissionStatus.notDetermined, "Allow"),
        (.granted, "Allow"),
        (.workedLastTime, "Allow"),
        (.checking, "Allow"),
        (.denied, "Allow"),
        (.unavailable, "Test Again"),
    ])
    func probeLabelIsAllowExceptAfterAFailedTap(status: PermissionStatus, expected: String) {
        #expect(FirstRunSystemAudioCopy.probeLabel(for: status) == expected)
    }
}
