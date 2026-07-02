import Foundation
import Testing
@testable import RecapCore

@Suite struct WebhookExporterTests {
    @Test func payloadCarriesMeetingAndContent() throws {
        let meeting = Meeting(
            title: "Sync", date: Date(timeIntervalSince1970: 1_780_000_000),
            duration: 120, attendees: ["Maya"], status: .ready
        )
        let transcript = Transcript(
            utterances: [Utterance(speakerID: "S1", start: 0, end: 2, text: "Hi.")],
            engine: "whisperkit", model: "m", language: "en"
        )
        let data = try WebhookExporter.payload(
            meeting, notes: "raw", enhanced: "- done", transcript: transcript
        )
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(json["event"] as? String == "meeting.ready")
        #expect(json["title"] as? String == "Sync")
        #expect(json["durationSeconds"] as? Double == 120)
        #expect(json["attendees"] as? [String] == ["Maya"])
        #expect(json["enhancedNotes"] as? String == "- done")
        let transcriptJSON = try #require(json["transcript"] as? [String: Any])
        let utterances = try #require(transcriptJSON["utterances"] as? [[String: Any]])
        #expect(utterances.first?["speakerID"] as? String == "S1")
    }

    @Test func nilFieldsAreOmittedOrNull() throws {
        let meeting = Meeting(title: "Solo", date: .now, status: .ready)
        let data = try WebhookExporter.payload(meeting, notes: nil, enhanced: nil, transcript: nil)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["notes"] == nil || json["notes"] is NSNull)
    }
}
