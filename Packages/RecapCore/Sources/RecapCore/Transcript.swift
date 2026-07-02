import Foundation

/// A single stretch of speech. `speakerID` is nil until diarization ships (post-v1);
/// the field exists now so stored transcripts never need migrating.
public struct Utterance: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var speakerID: String?
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public init(
        id: UUID = UUID(),
        speakerID: String? = nil,
        start: TimeInterval,
        end: TimeInterval,
        text: String
    ) {
        self.id = id
        self.speakerID = speakerID
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct Transcript: Codable, Equatable, Sendable {
    public var utterances: [Utterance]
    public var engine: String
    public var model: String
    public var language: String

    public init(utterances: [Utterance], engine: String, model: String, language: String) {
        self.utterances = utterances
        self.engine = engine
        self.model = model
        self.language = language
    }

    public var fullText: String {
        utterances.map(\.text).joined(separator: " ")
    }
}
