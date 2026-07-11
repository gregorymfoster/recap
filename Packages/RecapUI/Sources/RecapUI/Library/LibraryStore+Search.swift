import Foundation
import RecapCore

// MARK: Search

extension LibraryStore {
    /// Full-text search over titles, notes, enhanced notes, and transcripts.
    public func search(_ query: String) -> [SearchHit] {
        guard let index else {
            // Fixture mode: filter titles so the overlay is previewable.
            return meetings
                .filter { $0.meeting.title.localizedCaseInsensitiveContains(query) }
                .map { SearchHit(meetingID: $0.meeting.id, title: $0.meeting.title, snippet: "") }
        }
        return (try? index.search(query)) ?? []
    }

    /// Async overload of `search(_:)`, running the FTS query off the
    /// MainActor via `SearchIndex`'s async variant — used by `SearchOverlay`
    /// so a large index never blocks the UI while the user types.
    public func search(_ query: String) async -> [SearchHit] {
        guard let index else {
            // Fixture mode: filter titles so the overlay is previewable.
            return meetings
                .filter { $0.meeting.title.localizedCaseInsensitiveContains(query) }
                .map { SearchHit(meetingID: $0.meeting.id, title: $0.meeting.title, snippet: "") }
        }
        return (try? await index.search(query)) ?? []
    }
}
