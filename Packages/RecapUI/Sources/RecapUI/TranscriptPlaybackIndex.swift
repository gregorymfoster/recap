import Foundation
import RecapCore

/// Pure logic for following audio playback against a transcript: which
/// utterance (by index into a start-sorted array) is "current" for a given
/// playback position. Extracted so the binary search is unit-testable
/// without any SwiftUI/view-hierarchy scaffolding — see the house pattern in
/// `MixBuffer`/`LiveTranscriptState`.
public enum TranscriptPlaybackIndex {
    /// Index of the utterance that contains `position`, i.e. the last
    /// utterance whose `start <= position`. `utterances` must be sorted
    /// ascending by `start` (transcripts always are).
    ///
    /// - Before the first utterance's start: `nil`.
    /// - Between two utterances (in a gap, or past the matched one's `end`):
    ///   still resolves to that last-started utterance — playback follow
    ///   highlights "whoever was talking most recently," not strictly
    ///   "whoever's end/start bracket contains position."
    /// - At or after the last utterance's start (including past its `end`,
    ///   i.e. after the transcript ends): the last utterance.
    /// - Empty array: `nil`.
    public static func currentIndex(for position: TimeInterval, in utterances: [Utterance]) -> Int? {
        guard !utterances.isEmpty else { return nil }
        guard position >= utterances[0].start else { return nil }

        var low = 0
        var high = utterances.count - 1
        var result = 0
        while low <= high {
            let mid = (low + high) / 2
            if utterances[mid].start <= position {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }
}
