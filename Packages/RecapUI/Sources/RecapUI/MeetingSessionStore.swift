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
    /// Active-time clock for the current recording; nil while stopped.
    /// A struct — pause/resume reassign it so @Observable sees the change.
    public private(set) var clock: RecordingClock?
    /// Rolling window of recent RMS levels driving the pill's waveform bars.
    public private(set) var levels: [Float] = MeetingSessionStore.idleLevels
    public private(set) var permissionDenied = false

    /// True while recording, when mic access is denied and the recording is
    /// running system-audio only — drives the "mic off" indicator in the pill.
    public private(set) var micUnavailable = false

    /// Live transcript state (split view), reduced from `TranscriptionUpdate`s
    /// by the pure `LiveTranscriptState.applying(_:)`. Provisional — the
    /// post-stop file pass produces the canonical transcript.
    private var liveTranscript = LiveTranscriptState()

    public var liveUtterances: [Utterance] { liveTranscript.utterances }
    public var partialUtterance: Utterance? { liveTranscript.partial }

    /// Health of the live streaming pipeline — drives the transcript pane
    /// header so "Listening…" never lies about a stalled or missing model.
    public var liveState: LiveState { liveTranscript.liveState }

    /// The most recent confirmed utterance's text, for the RecordingPill's
    /// "last heard" snippet — visible even without the main window open.
    public var lastHeardText: String? { liveTranscript.lastHeardText }

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
    private let recorder: MeetingRecorder
    private var levelTask: Task<Void, Never>?
    private var transcriptTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?

    /// Called when the session stops itself (write failure) rather than via
    /// the user; AppStores routes this through the normal stop flow so the
    /// meeting still gets transcribed.
    public var onAutoStop: (@MainActor () -> Void)?

    /// - Parameter makeRecorder: Factory for the recorder; defaults to a
    ///   real `MeetingRecorder`. Tests inject one built with fake capture
    ///   sources so record/pause/fallback flows can run without hardware.
    public init(makeRecorder: @MainActor () -> MeetingRecorder = { MeetingRecorder() }) {
        recorder = makeRecorder()
    }

    /// Paused still counts as recording — every guard, calendar suppression,
    /// and `isLiveMeeting` check keys off the active record, not the clock.
    public var isRecording: Bool { activeRecord != nil }

    public var isPaused: Bool { clock?.isPaused ?? false }

    /// Starts capture; when a transcription engine is available, live
    /// transcription runs alongside it feeding the split view.
    public func start(
        record: MeetingRecord,
        engine: (any TranscriptionEngine)? = nil,
        includeSystemAudio: Bool = true,
        preferredInputUID: String? = nil
    ) async {
        guard activeRecord == nil else { return }
        // Denied mic no longer aborts: the recorder falls back to system
        // audio only (and the pill shows a "mic off" indicator). It only
        // fails outright when there's no audio source at all.
        let micGranted = await MeetingRecorder.requestMicPermission()
        permissionDenied = false
        micUnavailable = false
        startFailureMessage = nil
        recordingFailureMessage = nil
        do {
            let output = try recorder.start(
                writingTo: record.audioURL, includeSystemAudio: includeSystemAudio,
                includeMic: micGranted, preferredInputUID: preferredInputUID
            )
            micUnavailable = !micGranted
            systemAudioUnavailable = includeSystemAudio && !recorder.systemAudioActive
            activeRecord = record
            clock = recorder.clock ?? RecordingClock(startedAt: .now)
            liveTranscript = LiveTranscriptState()
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
                liveTranscript.liveState = .loadingModel
                let updates = engine.transcribe(stream: output.chunks)
                transcriptTask = Task { [weak self] in
                    for await update in updates {
                        self?.apply(update)
                    }
                }
            } else {
                // No streaming-capable model at all — say so plainly instead
                // of leaving the pane on a "Listening…" placeholder forever.
                liveTranscript.liveState = .noModelInstalled
            }
        } catch MeetingRecorder.RecorderError.noAudioSource {
            // Mic denied and no system audio to fall back on — nothing to
            // record. Surface it as the mic-permission problem it is.
            activeRecord = nil
            permissionDenied = true
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
        liveTranscript = liveTranscript.applying(update)
    }

    // MARK: Pause / resume

    /// Gates capture without tearing anything down. Awaits the recorder (and
    /// its mixer-actor hop) so the published paused state can't run ahead of
    /// the sample gate.
    public func pause() async {
        guard isRecording, !isPaused else { return }
        await recorder.pause()
        // Reassign the struct — mutating in place wouldn't notify observers.
        clock = recorder.clock
        // The gated mixer stops yielding levels; flatten the waveform now
        // instead of freezing it mid-utterance.
        levels = Self.idleLevels
    }

    public func resume() async {
        guard isRecording, isPaused else { return }
        await recorder.resume()
        clock = recorder.clock
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
        clock = nil
        levels = Self.idleLevels
        systemAudioUnavailable = false
        micUnavailable = false
        liveTranscript = LiveTranscriptState()
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
