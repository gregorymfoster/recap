import Foundation
import RecapCore

/// Pure logic for one streaming-transcription pass over the rolling buffer.
///
/// Heuristic: every segment except the trailing one is stable — Whisper only
/// revises the segment it is still hearing. Stable segments are confirmed and
/// their audio is trimmed from the buffer; the trailing segment is emitted as
/// the provisional in-progress row (40% opacity in the UI).
enum StreamingPass {
    struct Segment {
        var start: TimeInterval
        var end: TimeInterval
        var text: String

        init(start: TimeInterval, end: TimeInterval, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    struct Outcome {
        var confirmed: [Utterance] = []
        var partial: Utterance?
        /// Samples to drop from the front of the buffer.
        var trimSamples = 0
    }

    static func process(
        segments: [Segment],
        bufferStart: TimeInterval,
        bufferSampleCount: Int,
        sampleRate: Double
    ) -> Outcome {
        var outcome = Outcome()
        let cleaned = segments
            .map { Segment(start: $0.start, end: $0.end, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.text.isEmpty }
        guard !cleaned.isEmpty else { return outcome }

        for segment in cleaned.dropLast() {
            outcome.confirmed.append(utterance(from: segment, offset: bufferStart))
        }
        let last = cleaned[cleaned.count - 1]
        outcome.partial = utterance(from: last, offset: bufferStart)
        outcome.trimSamples = min(bufferSampleCount, max(0, Int(last.start * sampleRate)))
        return outcome
    }

    /// Extra samples to drop from the front of the buffer so it never exceeds `maxBuffer`.
    /// Needed because segment-based trimming (`trimSamples` above) makes no progress during a
    /// continuous monologue — Whisper returns one long segment whose start stays ~0 — so relying
    /// on it alone would let the buffer grow unbounded.
    static func overflowDrop(bufferCount: Int, maxBuffer: Int) -> Int {
        max(0, bufferCount - maxBuffer)
    }

    private static func utterance(from segment: Segment, offset: TimeInterval) -> Utterance {
        Utterance(start: offset + segment.start, end: offset + segment.end, text: segment.text)
    }
}
