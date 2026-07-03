import AVFoundation
import Foundation
import RecapAudio
import RecapCore

/// Imports one external audio file into the library: validate → create the
/// meeting folder → materialize `audio.m4a` (copy or transcode) → probe the
/// real duration → save metadata. Everything is on disk before the record is
/// returned, so callers can insert + enqueue without the transcription
/// pipeline ever seeing a half-written file.
///
/// Blocking (AVAudioFile decode of a long file takes a while) — run off the
/// main actor.
public struct AudioImporter: Sendable {
    public enum ImportError: Error {
        /// The source isn't a decodable audio file.
        case unreadableSource
    }

    private let storage: LibraryStorage

    public init(storage: LibraryStorage) {
        self.storage = storage
    }

    public func importFile(at url: URL) throws -> MeetingRecord {
        // Validate before creating anything on disk.
        guard (try? AVAudioFile(forReading: url)) != nil else {
            throw ImportError.unreadableSource
        }

        let title = url.deletingPathExtension().lastPathComponent
        let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .now
        var record = try storage.createImportedMeeting(title: title, date: date, duration: 0)
        do {
            // The pipeline hardcodes audio.m4a (salvage, transcription,
            // mirrors), so everything is normalized to AAC; an m4a source is
            // copied as-is.
            if url.pathExtension.lowercased() == "m4a" {
                try FileManager.default.copyItem(at: url, to: record.audioURL)
            } else {
                try AudioTranscoder.transcodeToAAC(from: url, to: record.audioURL)
            }
            // The materialized file is the duration source of truth.
            if let duration = AudioTranscoder.duration(of: record.audioURL) {
                record.meeting.duration = duration
                try storage.saveMetadata(record)
            }
        } catch {
            // Don't leave a queued meeting with no audio behind — it would
            // resurface as an error row on next launch.
            try? FileManager.default.removeItem(at: record.folderURL)
            throw error
        }
        return record
    }
}
