import Foundation
import OSLog
import RecapCore

private let log = Logger(subsystem: "com.gregfoster.recap", category: "AppStores")

/// Audio-file import (⌘O panel, drag-drop, Finder Open With). Extracted
/// from `AppStores`, which exposes it as `stores.importer` and keeps a thin
/// `importAudioFiles` forwarder for existing call sites.
@MainActor
public final class ImportCoordinator {
    /// nil in fixture/preview graphs, where nothing touches disk.
    private let storage: LibraryStorage?
    private let queue: QueueStore?
    private let library: LibraryStore
    private let toasts: ToastCenter

    init(storage: LibraryStorage?, queue: QueueStore?, library: LibraryStore, toasts: ToastCenter) {
        self.storage = storage
        self.queue = queue
        self.library = library
        self.toasts = toasts
    }

    /// Imports external audio files: each file is validated, transcoded to
    /// audio.m4a, and fully on disk before the meeting appears and
    /// transcription is enqueued — the processor must never race a
    /// half-written file. One detached utility task per batch; files import
    /// sequentially within it. No-op in the fixtures/preview graph (no
    /// storage or queue).
    public func importAudioFiles(_ urls: [URL]) {
        guard let storage, let queue else { return }
        let importer = AudioImporter(storage: storage)
        let library = library
        let toasts = toasts
        Task.detached(priority: .utility) {
            for url in urls {
                do {
                    let record = try importer.importFile(at: url)
                    await MainActor.run {
                        library.insertImported(record)
                        queue.enqueueTranscription(for: record.meeting.id)
                    }
                } catch {
                    log.error("Import failed for \(url.lastPathComponent, privacy: .public): \(error, privacy: .public)")
                    await MainActor.run {
                        toasts.show("Couldn't import \(url.lastPathComponent) — unreadable audio file")
                    }
                }
            }
        }
    }
}
