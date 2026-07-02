import Foundation
import RecapCore

/// A stretch of audio attributed to one speaker by diarization.
public struct SpeakerTurn: Equatable, Sendable {
    public var speakerID: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(speakerID: String, start: TimeInterval, end: TimeInterval) {
        self.speakerID = speakerID
        self.start = start
        self.end = end
    }
}

/// Merges diarization output into a transcript: each utterance gets the
/// speaker who owns the majority of its time span.
public enum SpeakerAssignment {
    /// Diarization clusters come back in arbitrary order; utterances that
    /// overlap no turn (e.g. transcribed noise in a silent stretch) keep a
    /// nil speakerID. IDs are renumbered so "S1" is the first voice heard.
    public static func label(_ utterances: [Utterance], with turns: [SpeakerTurn]) -> [Utterance] {
        guard !turns.isEmpty else { return utterances }

        var canonical: [String: String] = [:]
        for turn in turns.sorted(by: { $0.start < $1.start }) where canonical[turn.speakerID] == nil {
            canonical[turn.speakerID] = "S\(canonical.count + 1)"
        }

        return utterances.map { utterance in
            var labeled = utterance
            labeled.speakerID = dominantSpeaker(for: utterance, in: turns).flatMap { canonical[$0] }
            return labeled
        }
    }

    private static func dominantSpeaker(for utterance: Utterance, in turns: [SpeakerTurn]) -> String? {
        var overlap: [String: TimeInterval] = [:]
        for turn in turns {
            let shared = min(utterance.end, turn.end) - max(utterance.start, turn.start)
            if shared > 0 { overlap[turn.speakerID, default: 0] += shared }
        }
        return overlap.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key > rhs.key
        }?.key
    }
}
