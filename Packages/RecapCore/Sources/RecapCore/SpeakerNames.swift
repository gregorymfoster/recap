import Foundation

/// Per-meeting speaker rename mapping: diarization label ("S1", "S2"…) →
/// user-chosen display name ("Maya"). Persisted as `speakers.json` in the
/// meeting folder via `LibraryStorage`, following the same load/save shape
/// as notes and enhanced notes.
///
/// Scope decision: renames are per-meeting only for this release. Cross-
/// meeting voice-print identity (the same speaker recognized across
/// different recordings) is explicitly out of scope — nothing here reads or
/// writes any identity beyond a single meeting's folder.
public struct SpeakerNames: Codable, Equatable, Sendable {
    public var names: [String: String]

    public init(names: [String: String] = [:]) {
        self.names = names
    }

    public var isEmpty: Bool { names.isEmpty }

    public subscript(speakerID: String) -> String? {
        get { names[speakerID] }
        set { names[speakerID] = newValue }
    }
}
