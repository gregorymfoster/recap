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
    /// Audio was salvaged from a spool after an app quit/crash mid-recording
    /// (Phase 0 scaffolding for the recovery-flow redesign). Treated like
    /// `.queued` everywhere: it's a waiting-to-be-processed state, not a
    /// terminal one.
    case recovered
}

/// Which notes view the user last chose to look at for a meeting with
/// enhanced notes. `nil` (the default, both on a fresh `Meeting` and when
/// decoding older `meeting.json` files written before this field existed)
/// means "default to Enhanced whenever it's available."
public enum NotesViewPreference: String, Codable, Equatable, Sendable {
    case enhanced
    case original
}

/// A recoverable problem encountered while producing or delivering a meeting.
///
/// Values deliberately describe only the failed stage, never an underlying
/// system error or meeting content. That gives the UI a stable recovery action
/// and a support-safe diagnostic code without persisting private details.
public enum ProcessingIssue: String, Codable, CaseIterable, Equatable, Identifiable, Sendable {
    case recordingFileMissing
    case transcriptionFailed
    case enhancementFailed
    case mirrorBackupFailed
    /// Crash-spool salvage (rebuilding the m4a from a leftover .caf) failed.
    /// The raw audio is still safe on disk (salvage never deletes the spool
    /// on failure) — distinct from `recordingFileMissing`, where there is no
    /// audio left to recover at all.
    case recordingSalvageFailed

    public var id: String { rawValue }

    public var diagnosticCode: String {
        switch self {
        case .recordingFileMissing: "REC-AUDIO-001"
        case .transcriptionFailed: "REC-TRANSCRIBE-001"
        case .enhancementFailed: "REC-ENHANCE-001"
        case .mirrorBackupFailed: "REC-BACKUP-001"
        case .recordingSalvageFailed: "REC-AUDIO-002"
        }
    }
}

/// Shared, stable copy for status messages that more than one type needs to
/// match on exactly (`JobExecutor` writes it, `LaunchRecovery` pattern-matches
/// it) — a single source of truth keeps them from drifting apart.
public enum RecoveryMessages {
    public static let salvageFailed = "Couldn't restore recording"
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
    /// The user's last explicit choice between enhanced and original notes
    /// for this meeting. Optional so pre-existing `meeting.json` files decode
    /// unchanged; nil defaults to showing Enhanced whenever it's available.
    public var preferredNotesView: NotesViewPreference?
    /// A short, model-generated one-line subtitle summarizing the meeting,
    /// produced during on-device enhancement. Optional so pre-existing
    /// `meeting.json` files decode unchanged; nil when enhancement hasn't run
    /// yet or subtitle generation failed/was skipped.
    public var subtitle: String?
    /// Recoverable pipeline/export problems that still need attention. Older
    /// metadata decodes as an empty array, preserving the established on-disk
    /// format without a migration.
    public var processingIssues: [ProcessingIssue]

    public init(
        id: UUID = UUID(),
        title: String,
        date: Date,
        duration: TimeInterval = 0,
        attendees: [String] = [],
        status: MeetingStatus = .recording,
        updatedAt: Date? = nil,
        lastBackupDate: Date? = nil,
        preferredNotesView: NotesViewPreference? = nil,
        subtitle: String? = nil,
        processingIssues: [ProcessingIssue] = []
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.duration = duration
        self.attendees = attendees
        self.status = status
        self.updatedAt = updatedAt
        self.lastBackupDate = lastBackupDate
        self.preferredNotesView = preferredNotesView
        self.subtitle = subtitle
        self.processingIssues = processingIssues
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, date, duration, attendees, status, updatedAt
        case lastBackupDate, preferredNotesView, subtitle, processingIssues
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        date = try container.decode(Date.self, forKey: .date)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        attendees = try container.decode([String].self, forKey: .attendees)
        status = try container.decode(MeetingStatus.self, forKey: .status)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        lastBackupDate = try container.decodeIfPresent(Date.self, forKey: .lastBackupDate)
        preferredNotesView = try container.decodeIfPresent(NotesViewPreference.self, forKey: .preferredNotesView)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        processingIssues = try container.decodeIfPresent([ProcessingIssue].self, forKey: .processingIssues) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(date, forKey: .date)
        try container.encode(duration, forKey: .duration)
        try container.encode(attendees, forKey: .attendees)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(lastBackupDate, forKey: .lastBackupDate)
        try container.encodeIfPresent(preferredNotesView, forKey: .preferredNotesView)
        try container.encodeIfPresent(subtitle, forKey: .subtitle)
        try container.encode(processingIssues, forKey: .processingIssues)
    }
}
