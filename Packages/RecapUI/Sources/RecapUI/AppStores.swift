import Carbon.HIToolbox
import Foundation
import OSLog
import RecapCore
import RecapTranscription

private let storesLog = Logger(subsystem: "com.gregfoster.recap", category: "AppStores")

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
@Observable
public final class AppStores {
    public let settings: SettingsStore
    public let library: LibraryStore
    public let models: WhisperModelManager
    public let session: MeetingSessionStore
    public let queue: QueueStore?
    public let router = AppRouter()

    /// ⌥⌘R anywhere toggles recording. nil when another app owns the combo.
    @ObservationIgnored private var recordHotKey: GlobalHotKey?

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
            recordHotKey = GlobalHotKey(keyCode: kVK_ANSI_R, modifiers: cmdKey | optionKey) { [weak self] in
                self?.toggleRecording()
            }
            if recordHotKey == nil {
                storesLog.error("⌥⌘R global hot key registration failed (taken by another app?)")
            } else {
                storesLog.info("⌥⌘R global hot key registered")
            }
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

    // MARK: Recording control

    /// The one start-recording flow, shared by the Record button, the menu
    /// bar extra, and the global hot key.
    public func startRecording() {
        guard !session.isRecording, let record = library.startNewMeeting() else { return }
        Task {
            await session.start(
                record: record,
                engine: models.activeEngine(),
                includeSystemAudio: settings.includeSystemAudio
            )
            if session.permissionDenied {
                library.markError(record, message: "Microphone access denied")
            }
        }
    }

    /// The one stop flow: finish the recording and queue transcription.
    public func stopRecording() {
        Task {
            if let (record, duration) = await session.stop() {
                library.finishRecording(record, duration: duration)
                queue?.enqueueTranscription(for: record.meeting.id)
            }
        }
    }

    public func toggleRecording() {
        session.isRecording ? stopRecording() : startRecording()
    }

    /// Navigates to a meeting (used by the menu bar extra's jump items).
    public func showMeeting(_ id: UUID) {
        router.section = .library
        library.selectedMeetingID = id
    }
}
