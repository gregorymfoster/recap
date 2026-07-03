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

    @Test func decodesLegacyJSONWithoutLastBackupDate() throws {
        // A meeting.json written before `lastBackupDate` (and `updatedAt`)
        // existed must still decode — old libraries never migrate.
        let legacyJSON = """
        {
          "id": "6F1E2D3C-4B5A-6978-8899-AABBCCDDEEFF",
          "title": "Weekly standup",
          "date": 700000000,
          "duration": 900,
          "attendees": ["Maya"],
          "status": {"ready": {}}
        }
        """
        let meeting = try JSONDecoder().decode(Meeting.self, from: Data(legacyJSON.utf8))
        #expect(meeting.lastBackupDate == nil)
        #expect(meeting.updatedAt == nil)
        #expect(meeting.status == .ready)
        #expect(meeting.title == "Weekly standup")
    }

    @Test func decodesLegacyJSONWithoutPreferredNotesView() throws {
        // A meeting.json written before `preferredNotesView` existed must
        // still decode, defaulting to nil (Enhanced-when-available).
        let legacyJSON = """
        {
          "id": "6F1E2D3C-4B5A-6978-8899-AABBCCDDEEFF",
          "title": "Weekly standup",
          "date": 700000000,
          "duration": 900,
          "attendees": ["Maya"],
          "status": {"ready": {}}
        }
        """
        let meeting = try JSONDecoder().decode(Meeting.self, from: Data(legacyJSON.utf8))
        #expect(meeting.preferredNotesView == nil)
    }

    @Test func preferredNotesViewRoundTripsThroughJSON() throws {
        let meeting = Meeting(
            title: "Weekly standup",
            date: Date(timeIntervalSince1970: 1_780_000_000),
            status: .ready,
            preferredNotesView: .original
        )
        let data = try JSONEncoder().encode(meeting)
        let decoded = try JSONDecoder().decode(Meeting.self, from: data)
        #expect(decoded.preferredNotesView == .original)
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
