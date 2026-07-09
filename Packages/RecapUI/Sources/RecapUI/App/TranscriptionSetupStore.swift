import Observation
import RecapTranscription

/// Drives the redesigned "setting up transcription" flow (model download
/// progress, retry, quality switch). Inert stub — implemented in Phase 1 B2;
/// not yet wired into `AppStores`.
@MainActor
@Observable
public final class TranscriptionSetupStore {
    public enum SetupPhase: Equatable {
        case downloading(progress: Double)
        case failed
        case done
    }

    public private(set) var phase: SetupPhase = .done

    public var isReady: Bool {
        phase == .done
    }

    public init() {}

    public func retry() {}

    public func setQuality(_ quality: TranscriptionQuality) {}
}
