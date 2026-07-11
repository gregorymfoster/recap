import Foundation
import Testing
@testable import RecapCore

/// Exhaustive matrix of `LaunchRecovery.action(for:)` — the pure decision
/// behind `QueueStore.recoverUnfinishedWork`.
@Suite struct LaunchRecoveryTests {
    @Test func queuedRequeuesTranscribe() {
        #expect(LaunchRecovery.action(for: .queued) == .requeueTranscribe)
    }

    @Test func transcribingRequeuesTranscribe() {
        #expect(LaunchRecovery.action(for: .transcribing(progress: 0.4)) == .requeueTranscribe)
    }

    // MARK: hasTranscript matrix — only `.queued` consults it

    @Test func queuedWithTranscriptRequeuesEnhance() {
        #expect(LaunchRecovery.action(for: .queued, hasTranscript: true) == .requeueEnhance)
    }

    @Test func queuedWithoutTranscriptRequeuesTranscribe() {
        #expect(LaunchRecovery.action(for: .queued, hasTranscript: false) == .requeueTranscribe)
    }

    @Test func transcribingRequeuesTranscribeRegardlessOfTranscript() {
        #expect(LaunchRecovery.action(for: .transcribing(progress: 0.4), hasTranscript: true) == .requeueTranscribe)
        #expect(LaunchRecovery.action(for: .transcribing(progress: 0.4), hasTranscript: false) == .requeueTranscribe)
    }

    @Test func recordingMarksRecoveredRegardlessOfTranscript() {
        #expect(LaunchRecovery.action(for: .recording, hasTranscript: true) == .markRecovered)
        #expect(LaunchRecovery.action(for: .recording, hasTranscript: false) == .markRecovered)
    }

    @Test func recoveredStaysRecoveredRegardlessOfTranscript() {
        #expect(LaunchRecovery.action(for: .recovered, hasTranscript: true) == .markRecovered)
        #expect(LaunchRecovery.action(for: .recovered, hasTranscript: false) == .markRecovered)
    }

    @Test func enhancingRequeuesEnhanceRegardlessOfTranscript() {
        #expect(LaunchRecovery.action(for: .enhancing, hasTranscript: true) == .requeueEnhance)
        #expect(LaunchRecovery.action(for: .enhancing, hasTranscript: false) == .requeueEnhance)
    }

    @Test func legacyNoSpeechModelErrorMigratesRegardlessOfTranscript() {
        #expect(
            LaunchRecovery.action(for: .error(message: "No speech model installed"), hasTranscript: true)
                == .migrateToNeedsModel
        )
        #expect(
            LaunchRecovery.action(for: .error(message: "No speech model installed"), hasTranscript: false)
                == .migrateToNeedsModel
        )
    }

    @Test func genericErrorIsANoOpRegardlessOfTranscript() {
        #expect(LaunchRecovery.action(for: .error(message: "Transcription failed"), hasTranscript: true) == .none)
        #expect(LaunchRecovery.action(for: .error(message: "Transcription failed"), hasTranscript: false) == .none)
    }

    @Test func needsModelIsANoOpRegardlessOfTranscript() {
        #expect(LaunchRecovery.action(for: .needsModel, hasTranscript: true) == .none)
        #expect(LaunchRecovery.action(for: .needsModel, hasTranscript: false) == .none)
    }

    @Test func readyIsANoOpRegardlessOfTranscript() {
        #expect(LaunchRecovery.action(for: .ready, hasTranscript: true) == .none)
        #expect(LaunchRecovery.action(for: .ready, hasTranscript: false) == .none)
    }

    // MARK: Salvage-failed message

    @Test func salvageFailedMessageRequeuesTranscribe() {
        #expect(LaunchRecovery.action(for: .error(message: RecoveryMessages.salvageFailed)) == .requeueTranscribe)
    }

    @Test func arbitraryOtherErrorMessageIsANoOp() {
        #expect(LaunchRecovery.action(for: .error(message: "Some other failure")) == .none)
    }

    /// A meeting still `.recording` at launch means Recap crashed mid-recording.
    /// The salvaged audio is parked in `.recovered`, not silently requeued for
    /// transcription — the user explicitly presses Transcribe later.
    @Test func recordingMarksRecoveredRatherThanAutoRequeuing() {
        #expect(LaunchRecovery.action(for: .recording) == .markRecovered)
    }

    /// A crash-salvaged recording found at launch stays parked — the user
    /// explicitly presses Transcribe later, rather than the pipeline
    /// silently picking it back up.
    @Test func recoveredStaysMarkedRecoveredRatherThanAutoRequeuing() {
        #expect(LaunchRecovery.action(for: .recovered) == .markRecovered)
    }

    @Test func enhancingRequeuesEnhance() {
        #expect(LaunchRecovery.action(for: .enhancing) == .requeueEnhance)
    }

    @Test func legacyNoSpeechModelErrorMigratesToNeedsModel() {
        #expect(LaunchRecovery.action(for: .error(message: "No speech model installed")) == .migrateToNeedsModel)
    }

    @Test func genericErrorIsANoOp() {
        #expect(LaunchRecovery.action(for: .error(message: "Transcription failed")) == .none)
    }

    @Test func needsModelIsANoOp() {
        #expect(LaunchRecovery.action(for: .needsModel) == .none)
    }

    @Test func readyIsANoOp() {
        #expect(LaunchRecovery.action(for: .ready) == .none)
    }

    // MARK: needsExportRecovery

    @Test func needsExportRecoveryIsTrueForReadyNeverBackedUpMeetingWithBackupEnabled() {
        #expect(
            LaunchRecovery.needsExportRecovery(
                mirrorBackupEnabled: true, status: .ready, lastBackupDate: nil, updatedAt: nil
            )
        )
    }

    @Test func needsExportRecoveryIsTrueWhenBackedUpBeforeLastEdit() {
        let backedUp = Date(timeIntervalSince1970: 1_000)
        let editedAfter = Date(timeIntervalSince1970: 2_000)
        #expect(
            LaunchRecovery.needsExportRecovery(
                mirrorBackupEnabled: true, status: .ready, lastBackupDate: backedUp, updatedAt: editedAfter
            )
        )
    }

    @Test func needsExportRecoveryIsFalseWhenAlreadyBackedUpAfterLastEdit() {
        let editedBefore = Date(timeIntervalSince1970: 1_000)
        let backedUpAfter = Date(timeIntervalSince1970: 2_000)
        #expect(
            !LaunchRecovery.needsExportRecovery(
                mirrorBackupEnabled: true, status: .ready, lastBackupDate: backedUpAfter, updatedAt: editedBefore
            )
        )
    }

    @Test func needsExportRecoveryIsFalseWhenMirrorBackupDisabled() {
        #expect(
            !LaunchRecovery.needsExportRecovery(
                mirrorBackupEnabled: false, status: .ready, lastBackupDate: nil, updatedAt: nil
            )
        )
    }

    @Test func needsExportRecoveryIsFalseForNonReadyStatus() {
        #expect(
            !LaunchRecovery.needsExportRecovery(
                mirrorBackupEnabled: true, status: .queued, lastBackupDate: nil, updatedAt: nil
            )
        )
    }
}
