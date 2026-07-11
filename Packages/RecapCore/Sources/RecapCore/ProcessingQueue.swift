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

/// Thrown (via onJobFailed) when a job exceeded its deadline. Not retried:
/// a hang is not transient, and retrying would risk a second concurrent
/// engine run while the cancelled (possibly wedged) attempt winds down.
public struct JobTimedOut: Error, Equatable, Sendable {
    public let job: ProcessingJob
    public let limit: Duration

    public init(job: ProcessingJob, limit: Duration) {
        self.job = job
        self.limit = limit
    }
}

public enum JobTimeoutPolicy {
    /// transcribe: max(10 min, 1× audio duration); enhance: 10 min; export: 5 min.
    public static func limit(kind: ProcessingJob.Kind, audioSeconds: TimeInterval?) -> Duration {
        switch kind {
        case .transcribe:
            let seconds = max(600, audioSeconds ?? 0)
            return .seconds(seconds)
        case .enhance:
            return .seconds(600)
        case .export:
            return .seconds(300)
        }
    }
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
    private var runToken: UUID?

    private var manuallyPaused = false
    private var powerState = PowerState()

    private let executor: JobExecutor
    /// Optional per-job deadline. Returning nil means "no timeout" for that
    /// job. Sendable closure, so nonisolated per SE-0313 — callable directly
    /// from the unstructured tasks in `runWithTimeout` without hopping actors.
    private let timeoutLimit: (@Sendable (ProcessingJob) async -> Duration?)?
    private let timeoutSleep: @Sendable (Duration) async throws -> Void
    private var observer: (@Sendable (QueueSnapshot) -> Void)?
    private var onJobFailed: (@Sendable (ProcessingJob, Error) -> Void)?
    private var lastLoggedPauseReason: String??

    public init(
        executor: JobExecutor,
        timeoutLimit: (@Sendable (ProcessingJob) async -> Duration?)? = nil,
        timeoutSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.executor = executor
        self.timeoutLimit = timeoutLimit
        self.timeoutSleep = timeoutSleep
        // Seeded to "not paused" so the initial notify() (queue starts
        // unpaused) doesn't log a spurious "resumed".
        self.lastLoggedPauseReason = .some(nil)
    }

    /// Called after every state change with a fresh snapshot.
    public func setObserver(_ observer: @escaping @Sendable (QueueSnapshot) -> Void) {
        self.observer = observer
        notify()
    }

    /// Called once a job has failed twice (initial attempt + one automatic
    /// retry) and been dropped from the queue. The meeting is left in
    /// whichever status the failed stage started in — the UI layer decides
    /// how to surface that.
    public func setOnJobFailed(_ callback: @escaping @Sendable (ProcessingJob, Error) -> Void) {
        self.onJobFailed = callback
    }

    public func enqueue(_ job: ProcessingJob) {
        guard job != running, !pending.contains(job) else { return }
        pending.append(job)
        pump()
    }

    /// Drops every PENDING job for `meetingID` (e.g. the meeting was just
    /// moved to Trash), and cancels an in-flight job for the same meeting so
    /// work doesn't keep running against a meeting that no longer exists. A
    /// cancelled running job is treated as a clean stop, not a failure — it
    /// isn't retried and doesn't invoke `onJobFailed`.
    public func cancel(meetingID: UUID) {
        let before = pending.count
        pending.removeAll { $0.meetingID == meetingID }
        let removedPending = before - pending.count

        var cancelledRunning = false
        if running?.meetingID == meetingID {
            runningTask?.cancel()
            cancelledRunning = true
        }

        guard removedPending > 0 || cancelledRunning else { return }
        queueLog.info("jobs canceled: meetingID=\(meetingID.uuidString, privacy: .private) pending=\(removedPending, privacy: .public) running=\(cancelledRunning, privacy: .public)")
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
        let token = UUID()
        runToken = token
        notify()
        queueLog.info("job started: kind=\(job.kind.rawValue, privacy: .public) meetingID=\(job.meetingID.uuidString, privacy: .private)")
        runningTask = Task(priority: .utility) {
            await self.runJob(job, isRetry: false, token: token)
        }
    }

    /// Runs one attempt of `job`. A throw other than cancellation or a
    /// timeout is retried once automatically; a second failure (or any
    /// timeout) is reported via `onJobFailed` and the job is dropped so the
    /// queue can move on instead of stalling.
    private func runJob(_ job: ProcessingJob, isRetry: Bool, token: UUID) async {
        do {
            if let limit = await timeoutLimit?(job) {
                try await runWithTimeout(job, limit: limit, token: token)
            } else {
                try await executor.execute(job) { [weak self] fraction in
                    guard let self else { return }
                    Task { await self.updateProgress(fraction, for: job, token: token) }
                }
            }
            queueLog.info("job finished: kind=\(job.kind.rawValue, privacy: .public) meetingID=\(job.meetingID.uuidString, privacy: .private)")
            jobFinished()
        } catch is CancellationError {
            queueLog.info("job canceled: kind=\(job.kind.rawValue, privacy: .public) meetingID=\(job.meetingID.uuidString, privacy: .private)")
            jobFinished()
        } catch let timedOut as JobTimedOut {
            // Not retried: see `JobTimedOut`'s doc comment. The original
            // attempt may still be running in the background (e.g. hung on
            // an uncancellable continuation) — we deliberately don't wait
            // for it so the queue isn't wedged by it.
            queueLog.error("job timed out: kind=\(job.kind.rawValue, privacy: .public) meetingID=\(job.meetingID.uuidString, privacy: .private) limit=\(String(describing: timedOut.limit), privacy: .public)")
            onJobFailed?(job, timedOut)
            jobFinished()
        } catch {
            guard !isRetry else {
                queueLog.error("job failed after retry: kind=\(job.kind.rawValue, privacy: .public) meetingID=\(job.meetingID.uuidString, privacy: .private) error=\(String(describing: error), privacy: .private)")
                onJobFailed?(job, error)
                jobFinished()
                return
            }
            queueLog.error("job failed, retrying once: kind=\(job.kind.rawValue, privacy: .public) meetingID=\(job.meetingID.uuidString, privacy: .private) error=\(String(describing: error), privacy: .private)")
            await runJob(job, isRetry: true, token: token)
        }
    }

    /// Races `executor.execute` against `timeoutLimit`'s deadline using
    /// unstructured tasks (not a `TaskGroup`) deliberately: a `TaskGroup`
    /// implicitly awaits every child task before returning, so a truly
    /// hung executor (stuck on an uncancellable continuation, never
    /// observing `Task.cancel()`) would wedge this call — and the whole
    /// queue — forever. With unstructured tasks, whichever side finishes
    /// first resumes the continuation and this function returns; the loser
    /// (cancelled, but possibly still running if it ignores cancellation)
    /// is simply abandoned.
    private func runWithTimeout(_ job: ProcessingJob, limit: Duration, token: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resume = SingleResume(continuation)
            let executionTask = Task {
                do {
                    try await self.executor.execute(job) { [weak self] fraction in
                        guard let self else { return }
                        Task { await self.updateProgress(fraction, for: job, token: token) }
                    }
                    await resume.finish(with: .success(()))
                } catch {
                    await resume.finish(with: .failure(error))
                }
            }
            Task {
                try? await self.timeoutSleep(limit)
                executionTask.cancel()
                await resume.finish(with: .failure(JobTimedOut(job: job, limit: limit)))
            }
        }
    }

    private func updateProgress(_ fraction: Double, for job: ProcessingJob, token: UUID) {
        guard running == job, runToken == token else { return }
        runningProgress = fraction
        notify()
    }

    private func jobFinished() {
        running = nil
        runningProgress = 0
        runningTask = nil
        runToken = nil
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

/// Resumes a `CheckedContinuation` at most once — guards the execution-vs-
/// timeout race in `ProcessingQueue.runWithTimeout` against a double-resume
/// crash when both sides settle around the same moment.
private actor SingleResume {
    private var resumed = false
    private let continuation: CheckedContinuation<Void, Error>

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func finish(with result: Result<Void, Error>) {
        guard !resumed else { return }
        resumed = true
        continuation.resume(with: result)
    }
}
