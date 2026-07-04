import Foundation

/// Accessibility identifiers for the Queue feature.
///
/// `QueueStore.swift` and `ProcessorSettings.swift` are pure logic/store
/// types with no views of their own — the actual queue-summary widget UI is
/// rendered by `Sidebar.swift` (Library feature, owned by a different
/// agent/folder). These IDs are reserved here for that consumer to adopt;
/// nothing in Queue/ currently has a view to tag.
extension AXID {
    /// The sidebar's aggregate processing-queue widget (`QueueWidget` in
    /// `Library/Sidebar.swift`).
    public static let queueWidget = AXID("queue-widget")

    /// A single row representing one queued/processing meeting, keyed by the
    /// meeting's own id (see `AXID.meetingRow(_:)` for the naming pattern).
    public static func queueRow(_ id: String) -> AXID { AXID("queue-row-\(id)") }

    /// Retry / re-transcribe action for a queue row.
    public static func queueRetryButton(_ id: String) -> AXID { AXID("queue-retry-button-\(id)") }

    /// Cancel action for a queue row.
    public static func queueCancelButton(_ id: String) -> AXID { AXID("queue-cancel-button-\(id)") }
}
