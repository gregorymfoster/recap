import Foundation

/// A user-authored note pinned to an offset into a meeting's audio/transcript
/// timeline (Phase 0 scaffolding for the timed-notes redesign) — merges with
/// `Utterance`s via `TranscriptMerge` for display.
public struct TimedNote: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var offset: TimeInterval
    public var text: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        offset: TimeInterval,
        text: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.offset = offset
        self.text = text
        self.createdAt = createdAt
    }
}
