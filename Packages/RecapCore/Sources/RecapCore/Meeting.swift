import Foundation

/// Processing lifecycle of a meeting: recording → queued → transcribing(pct) → enhancing → ready | error.
public enum MeetingStatus: Codable, Equatable, Sendable {
    case recording
    case queued
    case transcribing(progress: Double)
    case enhancing
    case ready
    case error(message: String)
}

public struct Meeting: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var date: Date
    public var duration: TimeInterval
    public var attendees: [String]
    public var status: MeetingStatus

    public init(
        id: UUID = UUID(),
        title: String,
        date: Date,
        duration: TimeInterval = 0,
        attendees: [String] = [],
        status: MeetingStatus = .recording
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.duration = duration
        self.attendees = attendees
        self.status = status
    }
}
