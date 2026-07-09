import Foundation

/// Interleaves a transcript's `Utterance`s with a meeting's `TimedNote`s into
/// one time-ordered list for display (Phase 0 scaffolding for the timed-notes
/// redesign).
public enum TranscriptMerge {
    public enum Item: Equatable, Identifiable {
        case utterance(Utterance)
        case note(TimedNote)

        public var id: UUID {
            switch self {
            case .utterance(let utterance): utterance.id
            case .note(let note): note.id
            }
        }
    }

    /// Orders `utterances` and `notes` by time. A note at offset `t` sorts
    /// before the first utterance whose `start >= t` (ties resolve
    /// note-first); a note whose offset is past every utterance's start
    /// naturally sorts to the end. Stable within each type — equal-time
    /// utterances/notes keep their input order.
    public static func merged(utterances: [Utterance], notes: [TimedNote]) -> [Item] {
        // `typeRank` breaks (time) ties note-before-utterance; `inputOrder`
        // keeps the sort stable for equal (time, type) pairs regardless of
        // whether the underlying `sorted(by:)` implementation is stable.
        let utteranceEntries = utterances.enumerated().map { index, utterance in
            (time: utterance.start, typeRank: 1, inputOrder: index, item: Item.utterance(utterance))
        }
        let noteEntries = notes.enumerated().map { index, note in
            (time: note.offset, typeRank: 0, inputOrder: index, item: Item.note(note))
        }

        return (utteranceEntries + noteEntries)
            .sorted { lhs, rhs in
                if lhs.time != rhs.time { return lhs.time < rhs.time }
                if lhs.typeRank != rhs.typeRank { return lhs.typeRank < rhs.typeRank }
                return lhs.inputOrder < rhs.inputOrder
            }
            .map(\.item)
    }
}
