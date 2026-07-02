import Foundation
import Observation
import RecapAudio
import RecapCore

/// The active recording: owns the recorder, exposes timer state and
/// waveform levels to the pill, and hands the finished meeting back
/// to the library on stop.
@MainActor
@Observable
public final class MeetingSessionStore {
    public private(set) var activeRecord: MeetingRecord?
    public private(set) var startedAt: Date?
    /// Rolling window of recent RMS levels driving the pill's waveform bars.
    public private(set) var levels: [Float] = MeetingSessionStore.idleLevels
    public private(set) var permissionDenied = false

    /// Live transcript state (split view). Provisional — the post-stop file
    /// pass produces the canonical transcript.
    public private(set) var liveUtterances: [Utterance] = []
    public private(set) var partialUtterance: Utterance?

    /// True while recording, when the system-audio tap couldn't start —
    /// other meeting participants aren't being captured.
    public private(set) var systemAudioUnavailable = false

    /// Set when recording can't continue safely (e.g. disk full) — the
    /// session auto-stops so the audio captured so far is salvaged.
    public private(set) var recordingFailureMessage: String?

    /// Why the last `start()` failed, beyond mic permission (e.g. disk full).
    public private(set) var startFailureMessage: String?

    /// The mic device actually in use, for display in the live header/pill.
    public private(set) var activeInputDeviceName: String?

    /// A brief note about a mid-recording input switch ("Input switched to
    /// AirPods Pro"), cleared automatically after a few seconds.
    public private(set) var inputSwitchNote: String?
    private var inputSwitchNoteTask: Task<Void, Never>?

    private static let idleLevels = [Float](repeating: 0, count: 16)
    private let recorder = MeetingRecorder()
    private var levelTask: Task<Void, Never>?
    private var transcriptTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?

    /// Called when the session stops itself (write failure) rather than via
    /// the user; AppStores routes this through the normal stop flow so the
    /// meeting still gets transcribed.
    public var onAutoStop: (@MainActor () -> Void)?

    public init() {}

    public var isRecording: Bool { activeRecord != nil }

    /// Starts capture; when a transcription engine is available, live
    /// transcription runs alongside it feeding the split view.
    public func start(
        record: MeetingRecord,
        engine: (any TranscriptionEngine)? = nil,
        includeSystemAudio: Bool = true,
        preferredInputUID: String? = nil
    ) async {
        guard activeRecord == nil else { return }
        guard await MeetingRecorder.requestMicPermission() else {
            permissionDenied = true
            return
        }
        permissionDenied = false
        startFailureMessage = nil
        recordingFailureMessage = nil
        do {
            let output = try recorder.start(
                writingTo: record.audioURL, includeSystemAudio: includeSystemAudio,
                preferredInputUID: preferredInputUID
            )
            systemAudioUnavailable = includeSystemAudio && !recorder.systemAudioActive
            activeRecord = record
            startedAt = .now
            liveUtterances = []
            partialUtterance = nil
            activeInputDeviceName = recorder.activeInputDeviceName
            levelTask = Task { [weak self] in
                for await level in output.levels {
                    self?.pushLevel(level)
                }
            }
            eventTask = Task { [weak self] in
                for await event in output.events {
                    self?.handle(event)
                }
            }
            if let engine {
                let updates = engine.transcribe(stream: output.chunks)
                transcriptTask = Task { [weak self] in
                    for await update in updates {
                        self?.apply(update)
                    }
                }
            }
        } catch MeetingRecorder.RecorderError.diskFull {
            activeRecord = nil
            startFailureMessage = "Not enough free disk space"
        } catch {
            activeRecord = nil
            startFailureMessage = "Couldn't start recording"
        }
    }

    /// Switches the input device mid-recording. Goes through the recorder's
    /// existing debounced rebuild path; `.inputRebuilt` (surfaced via
    /// `handle(_:)`) confirms the switch once it lands.
    public func setPreferredInputUID(_ uid: String?) {
        guard isRecording else { return }
        recorder.setPreferredInputUID(uid)
    }

    private func handle(_ event: RecorderEvent) {
        switch event {
        case .inputRebuilt(let reason):
            // The mic graph survived a device switch — levels resuming is
            // the main signal, but a brief note confirms which device won.
            activeInputDeviceName = recorder.activeInputDeviceName
            showInputSwitchNote(reason)
        case .writeFailed:
            // Audio can't reach disk — stop now so what was captured
            // survives, and tell the user why the recording ended.
            recordingFailureMessage = "Recording stopped — couldn't write audio (disk full?)"
            onAutoStop?()
        }
    }

    /// Shows `reason` as a transient note and clears it a few seconds later.
    private func showInputSwitchNote(_ reason: String) {
        let note = reason.prefix(1).uppercased() + reason.dropFirst()
        inputSwitchNote = note
        inputSwitchNoteTask?.cancel()
        inputSwitchNoteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            if self?.inputSwitchNote == note {
                self?.inputSwitchNote = nil
            }
        }
    }

    private func apply(_ update: TranscriptionUpdate) {
        switch update {
        case .confirmed(let utterance):
            liveUtterances.append(utterance)
            partialUtterance = nil
        case .partial(let utterance):
            partialUtterance = utterance
        case .progress:
            break
        }
    }

    /// Stops capture and returns the finished record with its duration.
    @discardableResult
    public func stop() async -> (record: MeetingRecord, duration: TimeInterval)? {
        guard let record = activeRecord else { return nil }
        let duration = await recorder.stop()
        levelTask?.cancel()
        levelTask = nil
        transcriptTask?.cancel()
        transcriptTask = nil
        eventTask?.cancel()
        eventTask = nil
        activeRecord = nil
        startedAt = nil
        levels = Self.idleLevels
        systemAudioUnavailable = false
        liveUtterances = []
        partialUtterance = nil
        activeInputDeviceName = nil
        inputSwitchNoteTask?.cancel()
        inputSwitchNoteTask = nil
        inputSwitchNote = nil
        return (record, duration)
    }

    private func pushLevel(_ level: Float) {
        levels.removeFirst()
        // Perceptual boost: raw speech RMS sits around 0.02–0.2.
        levels.append(min(1, level * 6))
    }
}
