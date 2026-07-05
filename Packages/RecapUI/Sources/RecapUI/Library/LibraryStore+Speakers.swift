import Foundation
import RecapCore

// MARK: Speakers

extension LibraryStore {
    /// Per-meeting speaker renames (design handoff v2 §8e). Fixture mode (no
    /// `storage`) returns an empty mapping — previews just show "Speaker N".
    public func loadSpeakerNames(for record: MeetingRecord) -> [String: String] {
        guard let storage else { return [:] }
        return ((try? storage.loadSpeakerNames(in: record)) ?? SpeakerNames()).names
    }

    /// Renames one diarized speaker within a single meeting and persists it to
    /// `speakers.json`, then posts a change-bus event so any open view (this
    /// meeting's detail view, an export watcher) refreshes. No-ops in fixture
    /// mode — there's no real folder to persist into for a `/dev/null` record.
    public func renameSpeaker(_ speakerID: String, to name: String, in record: MeetingRecord) {
        guard let storage else { return }
        var speakerNames = (try? storage.loadSpeakerNames(in: record)) ?? SpeakerNames()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        speakerNames[speakerID] = trimmed.isEmpty ? nil : trimmed
        guard (try? storage.saveSpeakerNames(speakerNames, in: record)) != nil else { return }
        changeBus?.post(.meetingChanged(record.meeting.id))
    }
}
