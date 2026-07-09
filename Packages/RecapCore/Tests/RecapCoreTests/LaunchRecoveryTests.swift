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

    @Test func recordingRequeuesTranscribe() {
        #expect(LaunchRecovery.action(for: .recording) == .requeueTranscribe)
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
}
