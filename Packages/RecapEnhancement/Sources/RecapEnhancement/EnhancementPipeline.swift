import Foundation
import RecapCore

/// Placeholder for the FoundationModels-backed enhancer (M8).
/// Will gate on `SystemLanguageModel.default.availability` and run a
/// map-reduce pipeline over the transcript to fit the on-device context window.
public struct UnavailableEnhancer: NoteEnhancer {
    public init() {}

    public var isAvailable: Bool { false }

    public func enhance(rawNotes: String, transcript: Transcript) async throws -> String {
        throw EnhancementError.unavailable
    }
}

public enum EnhancementError: Error, Equatable {
    /// Apple Intelligence is off or unsupported on this Mac — meeting stays transcript-only.
    case unavailable
}
