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

    private static let idleLevels = [Float](repeating: 0, count: 16)
    private let recorder = MicRecorder()
    private var levelTask: Task<Void, Never>?

    public init() {}

    public var isRecording: Bool { activeRecord != nil }

    public func start(record: MeetingRecord) async {
        guard activeRecord == nil else { return }
        guard await MicRecorder.requestPermission() else {
            permissionDenied = true
            return
        }
        permissionDenied = false
        do {
            let output = try recorder.start(writingTo: record.audioURL)
            activeRecord = record
            startedAt = .now
            levelTask = Task { [weak self] in
                for await level in output.levels {
                    self?.pushLevel(level)
                }
            }
        } catch {
            activeRecord = nil
        }
    }

    /// Stops capture and returns the finished record with its duration.
    @discardableResult
    public func stop() -> (record: MeetingRecord, duration: TimeInterval)? {
        guard let record = activeRecord else { return nil }
        let duration = recorder.stop()
        levelTask?.cancel()
        levelTask = nil
        activeRecord = nil
        startedAt = nil
        levels = Self.idleLevels
        return (record, duration)
    }

    private func pushLevel(_ level: Float) {
        levels.removeFirst()
        // Perceptual boost: raw speech RMS sits around 0.02–0.2.
        levels.append(min(1, level * 6))
    }
}
