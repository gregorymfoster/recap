import Foundation
import Observation
import RecapTranscription
import Testing
@testable import RecapUI

/// In-memory `ModelInstalling` fake: `download` transitions through
/// `.downloading(progress:)` steps across a couple of run-loop turns (so
/// `withObservationTracking` in `TranscriptionSetupStore` gets distinct
/// change notifications to mirror into `phase`, the way a real download
/// would) before landing on `.installed` or `.failed`.
@MainActor
@Observable
private final class FakeModelInstalling: ModelInstalling {
    enum Outcome {
        case succeed
        case fail
    }

    var states: [String: ModelState] = [:]
    var activeModelID: String?
    private(set) var downloadedIDs: [String] = []
    private(set) var deletedIDs: [String] = []
    private(set) var activatedIDs: [String?] = []
    /// Decides the outcome of the *next* `download(_:)` call for a given
    /// model id — tests mutate this between calls to script failure-then-
    /// success sequences.
    var nextOutcome: (String) -> Outcome = { _ in .succeed }

    func download(_ model: ModelInfo) {
        downloadedIDs.append(model.id)
        states[model.id] = .downloading(progress: 0)
        let outcome = nextOutcome(model.id)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(5))
            self.states[model.id] = .downloading(progress: 0.5)
            try? await Task.sleep(for: .milliseconds(5))
            switch outcome {
            case .succeed:
                self.states[model.id] = .installed
            case .fail:
                self.states[model.id] = .failed
            }
        }
    }

    func setActive(_ id: String?) {
        activatedIDs.append(id)
        activeModelID = id
    }

    func delete(_ model: ModelInfo) {
        deletedIDs.append(model.id)
        states[model.id] = .available
    }

    func refresh() {}
}

@MainActor
@Suite struct TranscriptionSetupStoreTests {
    private let appleSilicon = HardwareProfile(isAppleSilicon: true, physicalMemoryGB: 16)
    private let bestQualityModelID = "large-v3-v20240930_626MB"
    private let fasterModelID = "small"

    private func ephemeralSettings() -> SettingsStore {
        let suite = UserDefaults(suiteName: "recap.tests.transcriptionsetupstore.\(UUID().uuidString)")!
        return SettingsStore(defaults: suite)
    }

    /// No real delay — lets the automatic-retry backoff run instantly.
    private let instantTick: (TimeInterval) async -> Void = { _ in }

    private func settle(_ iterations: Int = 100) async {
        for _ in 0..<iterations {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: default-quality migration

    @Test func defaultQualityMigrationIsBestQualityWhenKeyAbsent() {
        let settings = ephemeralSettings()
        #expect(settings.transcriptionQuality == .bestQuality)
    }

    // MARK: fresh install

    @Test func freshInstallDownloadsMirrorsProgressThenActivatesAndCompletes() async {
        let models = FakeModelInstalling()
        let settings = ephemeralSettings()
        let store = TranscriptionSetupStore(models: models, settings: settings, hardware: appleSilicon, retryTick: instantTick)

        store.start()
        #expect(store.phase == .downloading(progress: 0))

        await settle()

        #expect(store.phase == .done)
        #expect(models.downloadedIDs == [bestQualityModelID])
        #expect(models.activeModelID == bestQualityModelID)
        #expect(models.activatedIDs == [bestQualityModelID])
    }

    // MARK: already installed

    @Test func alreadyInstalledGoesStraightToDoneAndDeletesOthers() {
        let models = FakeModelInstalling()
        models.states = [bestQualityModelID: .installed, fasterModelID: .installed]
        models.activeModelID = fasterModelID
        let settings = ephemeralSettings()
        let store = TranscriptionSetupStore(models: models, settings: settings, hardware: appleSilicon, retryTick: instantTick)

        store.start()

        #expect(store.phase == .done)
        #expect(models.activatedIDs == [bestQualityModelID])
        #expect(models.deletedIDs == [fasterModelID])
        #expect(models.downloadedIDs.isEmpty)
    }

    // MARK: quality switch

    @Test func settingQualitySwitchesToNewPlan() async {
        let models = FakeModelInstalling()
        models.states = [fasterModelID: .installed]
        models.activeModelID = fasterModelID
        let settings = ephemeralSettings()
        settings.transcriptionQuality = .faster
        let store = TranscriptionSetupStore(models: models, settings: settings, hardware: appleSilicon, retryTick: instantTick)

        store.start()
        #expect(store.phase == .done)
        #expect(models.downloadedIDs.isEmpty)

        store.setQuality(.bestQuality)
        #expect(settings.transcriptionQuality == .bestQuality)
        #expect(store.phase == .downloading(progress: 0))

        await settle()

        #expect(store.phase == .done)
        #expect(models.downloadedIDs == [bestQualityModelID])
        #expect(models.activeModelID == bestQualityModelID)
        #expect(models.deletedIDs.contains(fasterModelID))
    }

    // MARK: failure → automatic retry

    @Test func failureEntersFailedThenAutomaticRetrySucceeds() async {
        let models = FakeModelInstalling()
        var attempt = 0
        models.nextOutcome = { _ in
            attempt += 1
            return attempt == 1 ? .fail : .succeed
        }
        let settings = ephemeralSettings()
        let store = TranscriptionSetupStore(models: models, settings: settings, hardware: appleSilicon, retryTick: instantTick)

        store.start()
        await settle()

        #expect(store.phase == .done)
        #expect(models.downloadedIDs == [bestQualityModelID, bestQualityModelID])
        #expect(models.activeModelID == bestQualityModelID)
    }

    // MARK: manual retry

    @Test func manualRetryReKicksFromFailed() async {
        let models = FakeModelInstalling()
        models.nextOutcome = { _ in .fail }
        let settings = ephemeralSettings()
        // A retry tick that never resolves during the test window, so the
        // automatic backoff retry never fires — isolates `retry()`'s manual
        // re-kick from the automatic-retry behavior covered by
        // `failureEntersFailedThenAutomaticRetrySucceeds`.
        let neverTicks: (TimeInterval) async -> Void = { _ in try? await Task.sleep(for: .seconds(3600)) }
        let store = TranscriptionSetupStore(models: models, settings: settings, hardware: appleSilicon, retryTick: neverTicks)

        store.start()
        await settle()
        #expect(store.phase == .failed)

        models.nextOutcome = { _ in .succeed }
        store.retry()
        await settle()

        #expect(store.phase == .done)
        #expect(models.activeModelID == bestQualityModelID)
    }

    // MARK: fixtures-only phase override

    /// `setPhaseForFixtures` is the seam the `firstRun` fixture scenario uses
    /// to force a downloading/failed/done "setting up transcription" card
    /// without a real `ModelInstalling` driving it — it must set `phase`
    /// directly and never touch `models`.
    @Test func setPhaseForFixturesOverridesPhaseWithoutTouchingModels() {
        let models = FakeModelInstalling()
        let settings = ephemeralSettings()
        let store = TranscriptionSetupStore(models: models, settings: settings, hardware: appleSilicon, retryTick: instantTick)
        #expect(store.phase == .done)

        store.setPhaseForFixtures(.downloading(progress: 0.34))
        #expect(store.phase == .downloading(progress: 0.34))
        #expect(models.downloadedIDs.isEmpty)

        store.setPhaseForFixtures(.failed)
        #expect(store.phase == .failed)

        store.setPhaseForFixtures(.done)
        #expect(store.phase == .done)
    }
}
