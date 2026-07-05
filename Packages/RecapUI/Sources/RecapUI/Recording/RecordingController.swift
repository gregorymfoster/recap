import Carbon.HIToolbox
import Foundation
import OSLog
import RecapCore
import RecapTranscription

private let log = Logger(subsystem: "com.gregfoster.recap", category: "AppStores")

/// Recording control: the one start/stop/pause flow shared by the Record
/// button, the menu bar extra, the ⌥⌘R global hot key, and calendar
/// auto-record. Extracted from `AppStores`, which exposes it as
/// `stores.recording` and keeps thin forwarders for the many existing
/// call sites.
@MainActor
public final class RecordingController {
    private let session: MeetingSessionStore
    private let library: LibraryStore
    private let models: WhisperModelManager
    private let settings: SettingsStore
    private let toasts: ToastCenter
    private let queue: QueueStore?
    /// Navigation hook (`AppStores.showMeeting`): jump to the live meeting
    /// as soon as recording starts.
    private let showMeeting: @MainActor (UUID) -> Void

    /// ⌥⌘R anywhere toggles recording. nil when another app owns the combo.
    private var recordHotKey: GlobalHotKey?
    /// True from a start trigger until its preflight + start settle; see
    /// `startRecording` for why `session.isRecording` alone isn't enough.
    private var recordingStartInFlight = false

    init(
        session: MeetingSessionStore,
        library: LibraryStore,
        models: WhisperModelManager,
        settings: SettingsStore,
        toasts: ToastCenter,
        queue: QueueStore?,
        showMeeting: @escaping @MainActor (UUID) -> Void
    ) {
        self.session = session
        self.library = library
        self.models = models
        self.settings = settings
        self.toasts = toasts
        self.queue = queue
        self.showMeeting = showMeeting
    }

    /// Registers the ⌥⌘R global hot key and wires the session's
    /// recorder-initiated callbacks (auto-stop on disk full, input-rebuilt
    /// toast). Called by the production graph and by tests that opt in via
    /// `registersHotKey` — never by the fixtures/preview graphs.
    func registerGlobalControls() {
        recordHotKey = GlobalHotKey(keyCode: kVK_ANSI_R, modifiers: cmdKey | optionKey) { [weak self] in
            self?.toggleRecording()
        }
        if recordHotKey == nil {
            log.error("⌥⌘R global hot key registration failed (taken by another app?)")
        } else {
            log.info("⌥⌘R global hot key registered")
        }
        // A recorder-initiated stop (disk full) still runs the normal
        // stop flow so the salvaged audio gets transcribed.
        session.onAutoStop = { [weak self] in
            if let message = self?.session.recordingFailureMessage {
                self?.toasts.show(message)
            }
            self?.stopRecording()
        }
        session.onInputRebuilt = { [weak self] reason, deviceName in
            self?.toasts.show(MicLossToast.message(reason: reason, deviceName: deviceName), style: .warning, actionTitle: "Change…") {
                SettingsOpener.open()
            }
        }
    }

    /// The one start-recording flow, shared by the Record button, the menu
    /// bar extra, the global hot key, and calendar auto-record.
    public func startRecording(title: String = "Untitled meeting", attendees: [String] = []) {
        // `session.isRecording` only flips once capture is actually running,
        // but preflight below can stay suspended for seconds (mic prompt,
        // tap probe + TCC prompt). Without this latch, a second trigger in
        // that window would run a whole second preflight/start in parallel.
        guard !session.isRecording, !recordingStartInFlight else { return }
        recordingStartInFlight = true
        // Keep the light streaming model topped up in the background — first
        // recording on a fresh install won't have it yet, and this makes
        // sure it's there for the next one even if this one starts without it.
        models.ensureStreamingModelDownloading()
        Task {
            defer { recordingStartInFlight = false }
            let (outcome, probeResult) = await session.preflight(
                includeSystemAudio: settings.includeSystemAudio,
                lastTapFailed: settings.lastSystemAudioTapFailed
            )
            if let probeResult {
                settings.lastSystemAudioTapFailed = (probeResult != .captured)
            }
            switch outcome {
            case .blocked:
                // No usable audio source — don't create a meeting record at
                // all; there's nothing worth transcribing.
                toasts.show(
                    RecapCopy.noAudioAccessMessage, actionTitle: "Open Settings"
                ) {
                    SettingsOpener.open()
                    PrivacyPane.open(PrivacyPane.microphone)
                }
            case .proceed(let includeMic, let includeSystemAudio):
                guard let record = library.startNewMeeting(title: title, attendees: attendees) else { return }
                await session.start(
                    record: record,
                    engine: models.streamingEngine(language: settings.transcriptionLanguage),
                    includeSystemAudio: includeSystemAudio,
                    includeMic: includeMic,
                    preferredInputUID: settings.preferredInputUID
                )
                if session.isRecording {
                    // Jump straight to the live meeting so the live transcript
                    // pane (on by default for live meetings) is visible from
                    // the first second of recording.
                    showMeeting(record.meeting.id)
                }
                if session.permissionDenied {
                    library.markError(record, message: "Microphone access denied")
                    toasts.show(
                        "Microphone access denied", actionTitle: "Open Settings"
                    ) {
                        SettingsOpener.open()
                        PrivacyPane.open(PrivacyPane.microphone)
                    }
                } else if let message = session.startFailureMessage {
                    library.markError(record, message: message)
                    toasts.show(message)
                } else if session.micUnavailable {
                    // Recording is running system-audio only; the pill shows the
                    // "mic off" badge, and this offers the fix.
                    toasts.show(
                        "Microphone access off — recording system audio only",
                        actionTitle: "Open Settings"
                    ) {
                        SettingsOpener.open()
                        PrivacyPane.open(PrivacyPane.microphone)
                    }
                } else if session.systemAudioUnavailable {
                    settings.lastSystemAudioTapFailed = true
                    toasts.show(
                        RecapCopy.systemAudioUnavailableMessage, actionTitle: "Open Settings"
                    ) {
                        SettingsOpener.open()
                        PrivacyPane.open(PrivacyPane.systemAudio)
                    }
                } else if includeSystemAudio {
                    settings.lastSystemAudioTapFailed = false
                }
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

    /// Pause/resume gate capture without ending the meeting. ⌥⌘P is a local
    /// shortcut only (pill + menu bar extra) — no new GlobalHotKey in v1.
    public func pauseRecording() {
        Task { await session.pause() }
    }

    public func resumeRecording() {
        Task { await session.resume() }
    }

    public func togglePause() {
        session.isPaused ? resumeRecording() : pauseRecording()
    }
}
