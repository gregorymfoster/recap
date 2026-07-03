import Foundation

/// Processing lifecycle of a meeting: recording → queued → transcribing(pct) → enhancing → ready.
/// `needsModel` is a recoverable pause (audio is saved, but no speech model is
/// installed yet); `error` is a genuine failure.
public enum MeetingStatus: Codable, Equatable, Sendable {
    case recording
    case queued
    case transcribing(progress: Double)
    case enhancing
    case ready
    /// Recorded and saved, but transcription is blocked until a speech model
    /// is installed. Auto-retries once one becomes available.
    case needsModel
    case error(message: String)
}

public struct Meeting: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var date: Date
    public var duration: TimeInterval
    public var attendees: [String]
    public var status: MeetingStatus
    /// Last time this meeting's metadata or content changed. Optional so
    /// pre-existing `meeting.json` files (written before this field existed)
    /// decode unchanged. CloudKit sync (Milestone C) uses this for
    /// last-writer-wins conflict resolution.
    public var updatedAt: Date?
    /// When the folder-mirror backup last succeeded for this meeting; nil if
    /// it never has. Optional so pre-existing `meeting.json` files decode
    /// unchanged.
    public var lastBackupDate: Date?

    public init(
        id: UUID = UUID(),
        title: String,
        date: Date,
        duration: TimeInterval = 0,
        attendees: [String] = [],
        status: MeetingStatus = .recording,
        updatedAt: Date? = nil,
        lastBackupDate: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.duration = duration
        self.attendees = attendees
        self.status = status
        self.updatedAt = updatedAt
        self.lastBackupDate = lastBackupDate
    }
}
