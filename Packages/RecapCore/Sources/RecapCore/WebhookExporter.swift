import Foundation

/// Posts finished meetings to a user-configured HTTP endpoint as JSON.
/// Best-effort: failures are the caller's to log, never to retry into a
/// user-visible error — the meeting itself is already safe on disk.
public struct WebhookExporter: Sendable {
    public var endpoint: URL

    public init(endpoint: URL) {
        self.endpoint = endpoint
    }

    struct Payload: Encodable {
        var event = "meeting.ready"
        var id: String
        var title: String
        var date: Date
        var durationSeconds: Double
        var attendees: [String]
        var notes: String?
        var enhancedNotes: String?
        var transcript: Transcript?
    }

    static func payload(
        _ meeting: Meeting,
        notes: String?,
        enhanced: String?,
        transcript: Transcript?
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(
            Payload(
                id: meeting.id.uuidString,
                title: meeting.title,
                date: meeting.date,
                durationSeconds: meeting.duration,
                attendees: meeting.attendees,
                notes: notes,
                enhancedNotes: enhanced,
                transcript: transcript
            )
        )
    }

    /// POSTs the meeting; throws on connection failure or a non-2xx reply.
    public func send(
        _ meeting: Meeting,
        notes: String?,
        enhanced: String?,
        transcript: Transcript?
    ) async throws {
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("recap", forHTTPHeaderField: "User-Agent")
        request.httpBody = try Self.payload(meeting, notes: notes, enhanced: enhanced, transcript: transcript)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
