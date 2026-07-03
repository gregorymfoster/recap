import Foundation
import Testing
@testable import RecapCore

@Suite struct TranscriptFormatterTests {
    @Test func emptyListProducesEmptyString() {
        #expect(TranscriptFormatter.plainText(utterances: []) == "")
    }

    @Test func utterancesWithoutSpeakersOmitTheSpeakerLabel() {
        let utterances = [
            Utterance(start: 0, end: 4, text: "Hello everyone."),
            Utterance(start: 65, end: 70, text: "Let's get started."),
        ]
        #expect(TranscriptFormatter.plainText(utterances: utterances) == """
        [0:00] Hello everyone.
        [1:05] Let's get started.
        """)
    }

    @Test func speakerIDsRenderWithTheUIDisplayConvention() {
        let utterances = [
            Utterance(speakerID: "S1", start: 0, end: 4, text: "Hello everyone."),
            Utterance(speakerID: "S2", start: 4, end: 9, text: "Hi!"),
            Utterance(speakerID: "guest", start: 9, end: 12, text: "Morning."),
        ]
        #expect(TranscriptFormatter.plainText(utterances: utterances) == """
        [0:00] Speaker 1: Hello everyone.
        [0:04] Speaker 2: Hi!
        [0:09] guest: Morning.
        """)
    }

    @Test func hourPlusTimestampsRollToHours() {
        let utterances = [
            Utterance(start: 3_599, end: 3_600, text: "Almost an hour."),
            Utterance(start: 3_600, end: 3_605, text: "One hour in."),
            Utterance(start: 7_384, end: 7_390, text: "Two hours plus."),
        ]
        #expect(TranscriptFormatter.plainText(utterances: utterances) == """
        [59:59] Almost an hour.
        [1:00:00] One hour in.
        [2:03:04] Two hours plus.
        """)
    }

    @Test func speakerDisplayNameParsesOnlyNumericSLabels() {
        #expect(TranscriptFormatter.speakerDisplayName("S1") == "Speaker 1")
        #expect(TranscriptFormatter.speakerDisplayName("S12") == "Speaker 12")
        #expect(TranscriptFormatter.speakerDisplayName("Sam") == "Sam")
        #expect(TranscriptFormatter.speakerDisplayName("speaker-a") == "speaker-a")
    }
}
