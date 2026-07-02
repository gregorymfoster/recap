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
    @ObservationIgnored private var calendarWatcher: CalendarWatcher?
    @ObservationIgnored private var recordPrompter: RecordPrompter?
    /// True when calendar auto-record is enabled in Settings but macOS
    /// calendar access was denied — surfaced as a warning there.
    public private(set) var calendarAccessDenied = false

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
            applyCalendarAutoRecordSetting()
            // A recorder-initiated stop (disk full) still runs the normal
            // stop flow so the salvaged audio gets transcribed.
            session.onAutoStop = { [weak self] in
                self?.stopRecording()
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
    /// bar extra, the global hot key, and calendar auto-record.
    public func startRecording(title: String = "Untitled meeting", attendees: [String] = []) {
        guard !session.isRecording,
              let record = library.startNewMeeting(title: title, attendees: attendees)
        else { return }
        Task {
            await session.start(
                record: record,
                engine: models.activeEngine(),
                includeSystemAudio: settings.includeSystemAudio
            )
            if session.permissionDenied {
                library.markError(record, message: "Microphone access denied")
            } else if let message = session.startFailureMessage {
                library.markError(record, message: message)
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

    // MARK: Calendar auto-record

    /// Starts or stops the calendar watcher to match Settings. Called at
    /// launch and whenever the setting changes.
    public func applyCalendarAutoRecordSetting() {
        guard settings.calendarAutoRecord != .off else {
            calendarWatcher?.stop()
            calendarAccessDenied = false
            return
        }
        if calendarWatcher == nil {
            calendarWatcher = CalendarWatcher { [weak self] event in
                self?.meetingEventStarting(event)
            }
        }
        if recordPrompter == nil {
            recordPrompter = RecordPrompter { [weak self] event in
                self?.startRecording(for: event)
            }
        }
        Task {
            let granted = await calendarWatcher?.start() ?? false
            calendarAccessDenied = !granted
        }
    }

    private func meetingEventStarting(_ event: CalendarEventSnapshot) {
        guard !session.isRecording else { return }
        switch settings.calendarAutoRecord {
        case .off:
            break
        case .prompt:
            recordPrompter?.promptToRecord(event)
        case .auto:
            startRecording(for: event)
        }
    }

    private func startRecording(for event: CalendarEventSnapshot) {
        startRecording(title: event.title, attendees: event.otherAttendees)
    }
}
