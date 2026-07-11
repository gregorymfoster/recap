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

    /// - Parameter hasTranscript: Only consulted for `.queued` — a meeting
    ///   queued with a transcript already on disk crashed between
    ///   transcription finishing and enhancement starting, so it resumes at
    ///   `.requeueEnhance` instead of re-transcribing from scratch.
    ///   `.transcribing` always restarts transcription regardless (a
    ///   partial/no transcript either way). Defaults to `false` so existing
    ///   single-argument callers keep their original behavior.
    public static func action(for status: MeetingStatus, hasTranscript: Bool = false) -> Action {
        switch status {
        case .queued:
            return hasTranscript ? .requeueEnhance : .requeueTranscribe
        case .transcribing:
            return .requeueTranscribe
        case .recording, .recovered:
            return .markRecovered
        case .enhancing:
            return .requeueEnhance
        case .error(RecoveryMessages.salvageFailed):
            // Auto re-salvage at next launch — the raw audio is safe (see
            // `ProcessingIssue.recordingSalvageFailed`), so this is a
            // transient environment issue (e.g. disk was full), not a
            // permanent dead end.
            return .requeueTranscribe
        case .error("No speech model installed"):
            return .migrateToNeedsModel
        case .needsModel, .ready, .error:
            return .none
        }
    }

    /// Pure predicate behind "recover pending exports at launch": true when a
    /// meeting finished processing (`.ready`) with folder-mirror backup
    /// turned on, and still needs a mirror per `BackupAggregate.isPending`
    /// (never backed up, or edited after its last backup — e.g. Recap quit
    /// between the pipeline completing and the debounced change-bus export
    /// firing, or backup was enabled while the app wasn't running). Shared by
    /// `BackupStatusStore.backfill()`'s filter and directly unit-tested here,
    /// so the launch-recovery decision is exhaustively testable without a
    /// real `LibraryStorage`/`BackupStatusStore` graph.
    public static func needsExportRecovery(
        mirrorBackupEnabled: Bool, status: MeetingStatus, lastBackupDate: Date?, updatedAt: Date?
    ) -> Bool {
        guard mirrorBackupEnabled, status == .ready else { return false }
        return BackupAggregate.isPending(lastBackupDate: lastBackupDate, updatedAt: updatedAt)
    }
}
