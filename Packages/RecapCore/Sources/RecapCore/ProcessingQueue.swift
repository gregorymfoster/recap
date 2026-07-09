import Foundation
import os

private let queueLog = Logger(subsystem: "com.gregfoster.recap", category: "ProcessingQueue")

public struct ProcessingJob: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case transcribe
        case enhance
        case export
    }

    public var kind: Kind
    public var meetingID: UUID

    public init(kind: Kind, meetingID: UUID) {
        self.kind = kind
        self.meetingID = meetingID
    }

    public var id: String { "\(kind.rawValue):\(meetingID.uuidString)" }
}

public struct QueueSnapshot: Equatable, Sendable {
    public var pending: [ProcessingJob] = []
    public var running: ProcessingJob?
    public var runningProgress: Double = 0
    public var isPaused = false
    public var pauseReason: String?

    public var jobCount: Int { pending.count + (running == nil ? 0 : 1) }
}

/// Runs one job's actual work. Implementations own their error handling —
/// a throw drops the job and the queue moves on.
public protocol JobExecutor: Sendable {
    func execute(_ job: ProcessingJob, progress: @escaping @Sendable (Double) -> Void) async throws
}

/// Environment inputs that gate background processing.
public struct PowerState: Equatable, Sendable {
    public var onBattery = false
    public var lowPowerMode = false
    public var thermalPressure = false

    public init(onBattery: Bool = false, lowPowerMode: Bool = false, thermalPressure: Bool = false) {
        self.onBattery = onBattery
        self.lowPowerMode = lowPowerMode
        self.thermalPressure = thermalPressure
    }
}

/// FIFO background-processing queue: one job at a time at utility priority,
/// unconditionally pausing on battery, Low Power Mode, thermal pressure, or
/// manual request. In-flight jobs finish; pausing gates the *next* job.
public actor ProcessingQueue {
    private var pending: [ProcessingJob] = []
    private var running: ProcessingJob?
    private var runningProgress: Double = 0
    private var runningTask: Task<Void, Never>?

    private var manuallyPaused = false
    private var powerState = PowerState()

    private let executor: JobExecutor
    private var observer: (@Sendable (QueueSnapshot) -> Void)?
    private var lastLoggedPauseReason: String??

    public init(executor: JobExecutor) {
        self.executor = executor
        // Seeded to "not paused" so the initial notify() (queue starts
        // unpaused) doesn't log a spurious "resumed".
        self.lastLoggedPauseReason = .some(nil)
    }

    /// Called after every state change with a fresh snapshot.
    public func setObserver(_ observer: @escaping @Sendable (QueueSnapshot) -> Void) {
        self.observer = observer
        notify()
    }

    public func enqueue(_ job: ProcessingJob) {
        guard job != running, !pending.contains(job) else { return }
        pending.append(job)
        pump()
    }

    /// Drops every PENDING job for `meetingID` (e.g. the meeting was just
    /// moved to Trash). An already-running job for this meeting is left to
    /// finish/fail on its own — this queue doesn't interrupt in-flight work,
    /// it just makes sure nothing new is dispatched for a meeting that no
    /// longer exists.
    public func cancel(meetingID: UUID) {
        let before = pending.count
        pending.removeAll { $0.meetingID == meetingID }
        let removed = before - pending.count
        guard removed > 0 else { return }
        queueLog.info("jobs canceled: meetingID=\(meetingID.uuidString, privacy: .private) count=\(removed, privacy: .public)")
        notify()
    }

    public func pause() {
        manuallyPaused = true
        notify()
    }

    public func resume() {
        manuallyPaused = false
        pump()
    }

    public func powerStateChanged(_ state: PowerState) {
        powerState = state
        pump()
    }

    public var snapshot: QueueSnapshot {
        QueueSnapshot(
            pending: pending,
            running: running,
            runningProgress: runningProgress,
            isPaused: isPaused,
            pauseReason: pauseReason
        )
    }

    // MARK: Private

    private var isPaused: Bool {
        pauseReason != nil
    }

    private var pauseReason: String? {
        if manuallyPaused { return "paused" }
        if powerState.thermalPressure { return "paused — Mac is warm" }
        if powerState.lowPowerMode { return "paused — Low Power Mode" }
        if powerState.onBattery { return "paused — on battery" }
        return nil
    }

    private func pump() {
        notify()
        guard running == nil, !isPaused, !pending.isEmpty else { return }
        let job = pending.removeFirst()
        running = job
        runningProgress = 0
        notify()
        queueLog.info("job started: kind=\(job.kind.rawValue, privacy: .public) meetingID=\(job.meetingID.uuidString, privacy: .private)")
        runningTask = Task(priority: .utility) {
            do {
                try await executor.execute(job) { [weak self] fraction in
                    guard let self else { return }
                    Task { await self.updateProgress(fraction) }
                }
                queueLog.info("job finished: kind=\(job.kind.rawValue, privacy: .public) meetingID=\(job.meetingID.uuidString, privacy: .private)")
            } catch {
                queueLog.error("job failed: kind=\(job.kind.rawValue, privacy: .public) meetingID=\(job.meetingID.uuidString, privacy: .private) error=\(String(describing: error), privacy: .private)")
            }
            self.jobFinished()
        }
    }

    private func updateProgress(_ fraction: Double) {
        guard running != nil else { return }
        runningProgress = fraction
        notify()
    }

    private func jobFinished() {
        running = nil
        runningProgress = 0
        runningTask = nil
        pump()
    }

    private func notify() {
        logPauseReasonTransition()
        observer?(snapshot)
    }

    /// Pause reason is a pure function of state, not a stored transition — log
    /// only when it actually changes so this stays a decision-point log, not
    /// per-notify noise.
    private func logPauseReasonTransition() {
        let reason = pauseReason
        guard lastLoggedPauseReason != .some(reason) else { return }
        lastLoggedPauseReason = .some(reason)
        if let reason {
            queueLog.info("paused: \(reason, privacy: .public)")
        } else {
            queueLog.info("resumed")
        }
    }
}
