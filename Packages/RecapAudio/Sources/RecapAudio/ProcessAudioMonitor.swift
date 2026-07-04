import CoreAudio
import Foundation
import os

private let detectionLog = Logger(subsystem: "com.gregfoster.recap", category: "MeetingDetection")

/// Polls CoreAudio's process-object list for per-app audio-activity
/// METADATA (is-running-output / is-running-input flags) — never taps or
/// captures audio content, so no TCC prompt is involved (design mock 9b).
///
/// Debounce semantics (avoiding a single ding starting/ending a session, and
/// a muted moment mid-call ending one) live in `CallAudioActivityTracker`;
/// this type is only responsible for the CoreAudio read and the poll loop.
@MainActor
public final class ProcessAudioMonitor: CallAudioMonitoring {
    /// Reads the CoreAudio process-object list and returns the subset of
    /// `watched` bundle ids that currently have a process running output or
    /// input. Injectable so the poll loop is testable without hardware.
    public typealias ActiveBundleIDReader = (_ watched: Set<String>) -> Set<String>

    private let pollInterval: Duration
    private let readActiveBundleIDs: ActiveBundleIDReader

    private var tracker = CallAudioActivityTracker()
    private var watchedBundleIDs: Set<String> = []
    private var onEvent: (@MainActor (CallAudioEvent) -> Void)?
    private var pollTask: Task<Void, Never>?

    public init(
        pollInterval: Duration = .seconds(3),
        startAfterPolls: Int = 2,
        stopAfterPolls: Int = 40,
        readActiveBundleIDs: @escaping ActiveBundleIDReader = { ProcessAudioMonitor.liveReadActiveBundleIDs(watched: $0) }
    ) {
        self.pollInterval = pollInterval
        self.readActiveBundleIDs = readActiveBundleIDs
        self.tracker = CallAudioActivityTracker(startAfterPolls: startAfterPolls, stopAfterPolls: stopAfterPolls)
    }

    public var isMonitoring: Bool { pollTask != nil }

    public func start(bundleIDs: Set<String>, onEvent: @escaping @MainActor (CallAudioEvent) -> Void) {
        pollTask?.cancel()
        tracker = CallAudioActivityTracker(startAfterPolls: tracker.startAfterPolls, stopAfterPolls: tracker.stopAfterPolls)
        watchedBundleIDs = bundleIDs
        self.onEvent = onEvent

        detectionLog.info("call audio monitor started: watching \(bundleIDs.count, privacy: .public) app(s)")

        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.tick()
                do {
                    try await Task.sleep(for: self.pollInterval)
                } catch {
                    return
                }
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        onEvent = nil
        detectionLog.info("call audio monitor stopped")
    }

    private func tick() async {
        let watched = watchedBundleIDs
        guard !watched.isEmpty else { return }
        let activeIDs = readActiveBundleIDs(watched)
        let events = tracker.ingest(activeIDs: activeIDs)
        guard !events.isEmpty else { return }
        for event in events {
            switch event {
            case .appStartedAudio(let bundleID):
                detectionLog.info("call audio event: \(bundleID, privacy: .public) started audio")
            case .appStoppedAudio(let bundleID):
                detectionLog.info("call audio event: \(bundleID, privacy: .public) stopped audio")
            }
            onEvent?(event)
        }
    }

    // MARK: - Real CoreAudio read

    /// Enumerates `kAudioHardwarePropertyProcessObjectList`, reads each
    /// process's bundle id and running-output/input flags, and returns the
    /// subset of `watched` ids backed by a currently-running process.
    /// Per-process reads can fail (a process can exit mid-enumeration) —
    /// failures are ignored silently rather than crashing the poll loop.
    public static func liveReadActiveBundleIDs(watched: Set<String>) -> Set<String> {
        guard !watched.isEmpty else { return [] }
        var active: Set<String> = []
        for processID in processObjectIDs() {
            guard let bundleID = processBundleID(processID), watched.contains(bundleID) else { continue }
            guard !active.contains(bundleID) else { continue }
            if processIsRunningOutput(processID) || processIsRunningInput(processID) {
                active.insert(bundleID)
            }
        }
        return active
    }

    private static func processObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        )
        guard status == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        )
        guard status == noErr else { return [] }
        return ids
    }

    private static func processBundleID(_ processID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var bundleID: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &bundleID) { ptr -> OSStatus in
            AudioObjectGetPropertyData(processID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        let value = bundleID as String
        return value.isEmpty ? nil : value
    }

    private static func processIsRunningOutput(_ processID: AudioObjectID) -> Bool {
        processBoolProperty(processID, selector: kAudioProcessPropertyIsRunningOutput)
    }

    private static func processIsRunningInput(_ processID: AudioObjectID) -> Bool {
        processBoolProperty(processID, selector: kAudioProcessPropertyIsRunningInput)
    }

    private static func processBoolProperty(_ processID: AudioObjectID, selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(processID, &address, 0, nil, &size, &value)
        guard status == noErr else { return false }
        return value != 0
    }
}
