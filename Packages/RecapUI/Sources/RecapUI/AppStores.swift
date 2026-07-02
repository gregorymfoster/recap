import Foundation
import RecapCore
import RecapTranscription

/// App-lifetime store graph, constructed exactly once (held by the App struct).
///
/// SwiftUI re-initializes view values freely, so building stores in a view's
/// `init` creates transient duplicates whose side effects are still live: every
/// extra QueueStore re-enqueued unfinished meetings, and the resulting
/// concurrent WhisperKit loads starved CoreML of file handles (model reads
/// failed, transcripts came back empty, and WhisperModelManager.refresh()
/// would then clear the active model). Owning the graph here guarantees one
/// instance of each store per process.
@MainActor
public final class AppStores {
    public let settings: SettingsStore
    public let library: LibraryStore
    public let models: WhisperModelManager
    public let session: MeetingSessionStore
    public let queue: QueueStore?

    /// Disk-backed graph used by the app. `-fixtures` swaps in sample data
    /// for UI work and screenshots (no queue — fixtures never process).
    public init() {
        if ProcessInfo.processInfo.arguments.contains("-fixtures") {
            settings = .ephemeralOnboarded()
            library = .fixture()
            models = WhisperModelManager()
            session = MeetingSessionStore()
            queue = nil
        } else {
            let settings = SettingsStore()
            let storage = LibraryStorage(rootURL: settings.saveRootURL)
            let index = (try? SearchIndex(databaseURL: SearchIndex.defaultDatabaseURL)) ?? (try! SearchIndex())
            let library = LibraryStore(storage: storage, index: index)
            let models = WhisperModelManager()
            self.settings = settings
            self.library = library
            self.models = models
            session = MeetingSessionStore()
            queue = QueueStore(library: library, storage: storage, models: models)
        }
    }

    /// Preview graph around the given library.
    init(library: LibraryStore) {
        settings = .ephemeralOnboarded()
        self.library = library
        models = WhisperModelManager()
        session = MeetingSessionStore()
        queue = nil
    }
}
