import Foundation
import Observation
import RecapTranscription

/// Narrow seam over `WhisperModelManager` (states, download, setActive,
/// delete, refresh — the subset `TranscriptionSetupStore` drives) so tests
/// can inject a fake instead of touching WhisperKit/the network.
/// `WhisperModelManager` already has matching members, so it conforms for
/// free (see the `extension` below).
@MainActor
public protocol ModelInstalling: AnyObject {
    var states: [String: ModelState] { get }
    var activeModelID: String? { get }
    func download(_ model: ModelInfo)
    func setActive(_ id: String?)
    func delete(_ model: ModelInfo)
    func refresh()
}

extension WhisperModelManager: ModelInstalling {}

/// Drives the redesigned "setting up transcription" flow: on `start()` (and
/// whenever the quality preference changes), reconciles the installed model
/// set against `SettingsStore.transcriptionQuality` via `ModelSelection`,
/// downloads/activates/cleans up as needed, and mirrors progress/failure
/// into `phase` for the UI to show. Replaces the manual, user-facing Models
/// screen — this is the whole "automatic model selection" feature.
@MainActor
@Observable
public final class TranscriptionSetupStore {
    public enum SetupPhase: Equatable {
        case downloading(progress: Double)
        case failed
        case done
    }

    /// Backoff schedule for automatic retries after a failed download:
    /// 5s, 30s, 2m, then hourly forever.
    private static let backoffSchedule: [TimeInterval] = [5, 30, 120]
    private static let hourlyBackoff: TimeInterval = 3600

    public private(set) var phase: SetupPhase = .done

    public var isReady: Bool {
        phase == .done
    }

    private let models: ModelInstalling
    private let settings: SettingsStore
    private let hardware: HardwareProfile
    /// Injectable sleep for the automatic-retry backoff — tests pass an
    /// instant no-op so failure→retry→success doesn't actually wait.
    private let retryTick: (TimeInterval) async -> Void

    private var retryTask: Task<Void, Never>?
    private var retryAttempt = 0

    public init(
        models: ModelInstalling,
        settings: SettingsStore,
        hardware: HardwareProfile = .current(),
        retryTick: @escaping (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.models = models
        self.settings = settings
        self.hardware = hardware
        self.retryTick = retryTick
    }

    /// Runs the initial reconcile. Called once at app startup (production
    /// graph only — fixtures/soak/preview graphs leave the store inert at
    /// its default `.done` phase by simply never calling this).
    public func start() {
        retryAttempt = 0
        reconcile()
    }

    /// Manual re-kick from `.failed`, cancelling any pending automatic retry.
    public func retry() {
        retryTask?.cancel()
        retryAttempt = 0
        reconcile()
    }

    /// Persists the new quality and re-plans: downloads/activates/cleans up
    /// whatever moving to it requires.
    public func setQuality(_ quality: TranscriptionQuality) {
        settings.transcriptionQuality = quality
        retryTask?.cancel()
        retryAttempt = 0
        reconcile()
    }

    // MARK: Private

    private func installedIDs() -> Set<String> {
        Set(models.states.compactMap { id, state in state == .installed ? id : nil })
    }

    private func reconcile() {
        let plan = ModelSelection.reconcile(
            quality: settings.transcriptionQuality,
            hardware: hardware,
            installedIDs: installedIDs(),
            activeID: models.activeModelID
        )
        switch plan {
        case .ready(let activate, let deleteOthers):
            activateAndCleanUp(activate: activate, deleteOthers: deleteOthers)
        case .download(let model, let thenDelete):
            phase = .downloading(progress: 0)
            models.download(model)
            observeDownload(of: model, thenDelete: thenDelete)
        }
    }

    private func activateAndCleanUp(activate: String, deleteOthers: [String]) {
        models.setActive(activate)
        for id in deleteOthers {
            if let info = ModelCatalog.info(for: id) {
                models.delete(info)
            }
        }
        phase = .done
    }

    /// Self-re-arming `withObservationTracking` loop mirroring the manager's
    /// download state into `phase` — the standard pattern for observing
    /// `@Observable` state outside a SwiftUI view body (see
    /// `FloatingIndicatorController`).
    private func observeDownload(of model: ModelInfo, thenDelete: [String]) {
        withObservationTracking {
            _ = models.states[model.id]
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.handleDownloadStateChange(of: model, thenDelete: thenDelete)
            }
        }
    }

    private func handleDownloadStateChange(of model: ModelInfo, thenDelete: [String]) {
        switch models.states[model.id] ?? .available {
        case .downloading(let progress):
            phase = .downloading(progress: progress)
            observeDownload(of: model, thenDelete: thenDelete)
        case .installed:
            activateAndCleanUp(activate: model.id, deleteOthers: thenDelete)
        case .failed:
            phase = .failed
            scheduleRetry()
        case .available:
            // Not expected mid-flow (pause/delete racing the setup store),
            // but keep tracking alive rather than going silent.
            observeDownload(of: model, thenDelete: thenDelete)
        }
    }

    private func scheduleRetry() {
        let delay = Self.backoffSchedule.indices.contains(retryAttempt)
            ? Self.backoffSchedule[retryAttempt]
            : Self.hourlyBackoff
        retryAttempt += 1
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            guard let self else { return }
            await self.retryTick(delay)
            guard !Task.isCancelled else { return }
            self.reconcile()
        }
    }
}
