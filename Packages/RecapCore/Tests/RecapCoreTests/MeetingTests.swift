import Foundation
import Testing
@testable import RecapCore

@Suite struct MeetingTests {
    @Test func meetingRoundTripsThroughJSON() throws {
        let meeting = Meeting(
            title: "Design sync — Q3 roadmap",
            date: Date(timeIntervalSince1970: 1_780_000_000),
            duration: 1855,
            attendees: ["Maya", "Sam"],
            status: .transcribing(progress: 0.4)
        )
        let data = try JSONEncoder().encode(meeting)
        let decoded = try JSONDecoder().decode(Meeting.self, from: data)
        #expect(decoded == meeting)
    }

    @Test func transcriptFullTextJoinsUtterances() {
        let transcript = Transcript(
            utterances: [
                Utterance(start: 0, end: 2, text: "Hello everyone."),
                Utterance(start: 2, end: 4, text: "Let's get started."),
            ],
            engine: "whisperkit",
            model: "openai_whisper-small",
            language: "en"
        )
        #expect(transcript.fullText == "Hello everyone. Let's get started.")
        #expect(transcript.utterances.allSatisfy { $0.speakerID == nil })
    }
}
