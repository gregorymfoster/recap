import Foundation

/// Pure decision for what happens to a meeting's queued/in-flight work at
/// launch, keyed only on its persisted `MeetingStatus`. Extracted from
/// `QueueStore.recoverUnfinishedWork` (house pattern: pure logic out of the
/// framework-coupled caller) so the launch-recovery matrix is exhaustively
/// testable without a real `ProcessingQueue`/`LibraryStore`.
public enum LaunchRecovery {
    public enum Action: Equatable, Sendable {
        /// Reset to `.queued` and enqueue a `.transcribe` job.
        case requeueTranscribe
        /// Reset to `.queued` and enqueue an `.enhance` job.
        case requeueEnhance
        /// A crash-salvaged recording found at launch stays parked in
        /// `.recovered` — the user explicitly presses Transcribe later,
        /// rather than the pipeline silently picking it back up.
        case markRecovered
        /// Migrate a pre-`.needsModel` "No speech model installed" error into
        /// the modern `.needsModel` state, retried once a model installs.
        case migrateToNeedsModel
        /// Nothing to do: a terminal state (`.ready`, a genuine `.error`) or
        /// a state already retried elsewhere (`.needsModel`).
        case none
    }

    public static func action(for status: MeetingStatus) -> Action {
        switch status {
        case .queued, .transcribing:
            return .requeueTranscribe
        case .recording, .recovered:
            return .markRecovered
        case .enhancing:
            return .requeueEnhance
        case .error("No speech model installed"):
            return .migrateToNeedsModel
        case .needsModel, .ready, .error:
            return .none
        }
    }
}
