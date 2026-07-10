import Foundation
import Testing
@testable import RecapCore

/// Records executed jobs and lets tests control job completion.
private actor FakeExecutor: JobExecutor {
    private(set) var executed: [ProcessingJob] = []
    private var gates: [CheckedContinuation<Void, Never>] = []
    var holdsJobs = false

    func setHoldsJobs(_ value: Bool) {
        holdsJobs = value
    }

    func execute(_ job: ProcessingJob, progress: @escaping @Sendable (Double) -> Void) async throws {
        executed.append(job)
        progress(0.5)
        if holdsJobs {
            await withCheckedContinuation { gates.append($0) }
        }
    }

    func releaseHeldJob() {
        guard !gates.isEmpty else { return }
        gates.removeFirst().resume()
    }
}

/// Fails every attempt at a given job — used to exercise the queue's
/// retry-once-then-report-failure path.
private actor AlwaysFailingExecutor: JobExecutor {
    enum Failure: Error { case boom }

    private var attempts: [String: Int] = [:]

    func execute(_ job: ProcessingJob, progress: @escaping @Sendable (Double) -> Void) async throws {
        attempts[job.id, default: 0] += 1
        throw Failure.boom
    }

    func attemptCount(for job: ProcessingJob) -> Int {
        attempts[job.id] ?? 0
    }
}

/// Sleeps until cancelled, so `Task.cancel()` propagates as a real
/// `CancellationError` from `execute` — mirrors how a real executor observes
/// cancellation via `Task.checkCancellation()`/`Task.sleep`.
private actor CancellableExecutor: JobExecutor {
    private(set) var executed: [ProcessingJob] = []
    private(set) var completed: [ProcessingJob] = []

    func execute(_ job: ProcessingJob, progress: @escaping @Sendable (Double) -> Void) async throws {
        executed.append(job)
        try await Task.sleep(for: .seconds(30))
        completed.append(job)
    }
}

/// Records `execute` calls and hands back each job's progress closure so a
/// test can invoke it "late," after the queue has moved on to another job.
private actor CapturingExecutor: JobExecutor {
    private(set) var executed: [ProcessingJob] = []
    private var progressCallbacks: [String: @Sendable (Double) -> Void] = [:]
    private var gates: [CheckedContinuation<Void, Never>] = []

    func execute(_ job: ProcessingJob, progress: @escaping @Sendable (Double) -> Void) async throws {
        executed.append(job)
        progressCallbacks[job.id] = progress
        progress(0.5)
        await withCheckedContinuation { gates.append($0) }
    }

    func progressCallback(for job: ProcessingJob) -> (@Sendable (Double) -> Void)? {
        progressCallbacks[job.id]
    }

    /// Releases whichever job is currently held — FIFO, mirrors `FakeExecutor`.
    func releaseHeldJob() {
        guard !gates.isEmpty else { return }
        gates.removeFirst().resume()
    }
}

private actor FailureLog {
    private(set) var jobs: [ProcessingJob] = []

    func record(_ job: ProcessingJob) {
        jobs.append(job)
    }

    var count: Int { jobs.count }
}

private func waitUntil(
    timeout: Duration = .seconds(2), _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

@Suite struct ProcessingQueueTests {
    @Test func executesJobsInOrder() async {
        let executor = FakeExecutor()
        let queue = ProcessingQueue(executor: executor)
        let a = ProcessingJob(kind: .transcribe, meetingID: UUID())
        let b = ProcessingJob(kind: .transcribe, meetingID: UUID())
        await queue.enqueue(a)
        await queue.enqueue(b)

        #expect(await waitUntil { await executor.executed.count == 2 })
        #expect(await executor.executed == [a, b])
        #expect(await queue.snapshot.jobCount == 0)
    }

    @Test func duplicateJobsAreDropped() async {
        let executor = FakeExecutor()
        await executor.setHoldsJobs(true)
        let queue = ProcessingQueue(executor: executor)
        let job = ProcessingJob(kind: .transcribe, meetingID: UUID())
        await queue.enqueue(job)
        #expect(await waitUntil { await queue.snapshot.running == job })
        await queue.enqueue(job)  // already running → dropped
        #expect(await queue.snapshot.pending.isEmpty)
        await executor.releaseHeldJob()
    }

    /// Pause-on-battery is unconditional behavior now — no setting gates it.
    @Test func batteryPowerAlwaysPausesNextJobAndResumeOnAC() async {
        let executor = FakeExecutor()
        let queue = ProcessingQueue(executor: executor)
        await queue.powerStateChanged(PowerState(onBattery: true))
        await queue.enqueue(ProcessingJob(kind: .transcribe, meetingID: UUID()))

        try? await Task.sleep(for: .milliseconds(100))
        #expect(await executor.executed.isEmpty)
        #expect(await queue.snapshot.pauseReason == "paused — on battery")

        await queue.powerStateChanged(PowerState(onBattery: false))
        #expect(await waitUntil { await executor.executed.count == 1 })
    }

    @Test func manualPauseHoldsQueueButFinishesRunningJob() async {
        let executor = FakeExecutor()
        await executor.setHoldsJobs(true)
        let queue = ProcessingQueue(executor: executor)
        let first = ProcessingJob(kind: .transcribe, meetingID: UUID())
        let second = ProcessingJob(kind: .enhance, meetingID: UUID())
        await queue.enqueue(first)
        #expect(await waitUntil { await queue.snapshot.running == first })

        await queue.pause()
        await queue.enqueue(second)
        await executor.setHoldsJobs(false)
        await executor.releaseHeldJob()

        // First job finished; second stays pending while paused.
        #expect(await waitUntil { await queue.snapshot.running == nil })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await executor.executed == [first])
        #expect(await queue.snapshot.pending == [second])

        await queue.resume()
        #expect(await waitUntil { await executor.executed.count == 2 })
    }

    @Test func cancelMeetingIDRemovesOnlyThatMeetingsPendingJobs() async {
        let executor = FakeExecutor()
        await executor.setHoldsJobs(true)
        let queue = ProcessingQueue(executor: executor)
        let targetID = UUID()
        let otherID = UUID()
        // Running job belongs to a DIFFERENT meeting (and a different kind,
        // so its `id` doesn't collide with `pendingOtherMeeting`) so this
        // test stays focused on pending-job pruning; running-job
        // cancellation is covered separately below.
        let running = ProcessingJob(kind: .export, meetingID: otherID)
        let pendingSameMeeting = ProcessingJob(kind: .enhance, meetingID: targetID)
        let pendingOtherMeeting = ProcessingJob(kind: .transcribe, meetingID: otherID)
        await queue.enqueue(running)
        #expect(await waitUntil { await queue.snapshot.running == running })
        await queue.enqueue(pendingSameMeeting)
        await queue.enqueue(pendingOtherMeeting)
        #expect(await queue.snapshot.pending == [pendingSameMeeting, pendingOtherMeeting])

        await queue.cancel(meetingID: targetID)

        // The pending job for the trashed meeting is gone; the other
        // meeting's pending job and running job survive untouched.
        #expect(await queue.snapshot.pending == [pendingOtherMeeting])
        #expect(await queue.snapshot.running == running)

        await executor.setHoldsJobs(false)
        await executor.releaseHeldJob()
        #expect(await waitUntil { await executor.executed.count == 2 })
        #expect(await executor.executed == [running, pendingOtherMeeting])
    }

    @Test func cancelMeetingIDWithNoPendingJobsIsANoOp() async {
        let executor = FakeExecutor()
        let queue = ProcessingQueue(executor: executor)
        await queue.cancel(meetingID: UUID())
        #expect(await queue.snapshot.pending.isEmpty)
        #expect(await queue.snapshot.running == nil)
    }

    /// Fix: cancel(meetingID:) now stops an in-flight job for that meeting
    /// too (not just pending jobs) — the underlying task is cancelled, the
    /// job isn't retried or reported as failed, and the queue advances to
    /// the next pending job.
    @Test func cancelMeetingIDStopsRunningJobAndAdvancesQueue() async {
        let executor = CancellableExecutor()
        let queue = ProcessingQueue(executor: executor)
        let meetingID = UUID()
        let running = ProcessingJob(kind: .transcribe, meetingID: meetingID)
        let next = ProcessingJob(kind: .enhance, meetingID: UUID())

        let failures = FailureLog()
        await queue.setOnJobFailed { job, _ in
            Task { await failures.record(job) }
        }

        await queue.enqueue(running)
        #expect(await waitUntil { await executor.executed.contains(running) })
        await queue.enqueue(next)

        await queue.cancel(meetingID: meetingID)

        #expect(await waitUntil { await executor.executed.contains(next) })
        // The cancelled job never reaches "completed" (its Task.sleep threw).
        #expect(await executor.completed.isEmpty)
        // Cancellation is a clean stop, not a reported failure.
        #expect(await failures.count == 0)
    }

    @Test func observerSeesProgressAndCompletion() async {
        let executor = FakeExecutor()
        await executor.setHoldsJobs(true)
        let queue = ProcessingQueue(executor: executor)
        let seen = SnapshotLog()
        await queue.setObserver { snapshot in
            Task { await seen.append(snapshot) }
        }
        await queue.enqueue(ProcessingJob(kind: .transcribe, meetingID: UUID()))

        // Job is held open, so the 0.5 progress update lands while running.
        #expect(await waitUntil { await seen.sawProgress(0.5) })
        await executor.setHoldsJobs(false)
        await executor.releaseHeldJob()
        #expect(await waitUntil { await queue.snapshot.jobCount == 0 })
        #expect(await waitUntil { await seen.sawIdle() })
    }

    /// Fix: a throwing executor no longer silently drops the job — it's
    /// retried once, and only reported via `onJobFailed` (and removed from
    /// `running`) after the retry also fails. The queue must then advance to
    /// the next job instead of stalling.
    @Test func throwingExecutorRetriesOnceThenReportsFailureAndAdvances() async {
        let executor = AlwaysFailingExecutor()
        let queue = ProcessingQueue(executor: executor)
        let failing = ProcessingJob(kind: .transcribe, meetingID: UUID())
        let next = ProcessingJob(kind: .enhance, meetingID: UUID())

        let failures = FailureLog()
        await queue.setOnJobFailed { job, _ in
            Task { await failures.record(job) }
        }

        await queue.enqueue(failing)
        await queue.enqueue(next)

        // Both jobs fail every attempt, so the queue eventually reports both
        // (proving it advanced past the first failure instead of stalling)
        // — without asserting on the exact moment the first is reported,
        // since both may resolve within the same poll tick.
        #expect(await waitUntil { await failures.count == 2 })
        #expect(await failures.jobs == [failing, next])
        #expect(await executor.attemptCount(for: failing) == 2)
        #expect(await executor.attemptCount(for: next) == 2)
        #expect(await queue.snapshot.running == nil)
        #expect(await queue.snapshot.pending.isEmpty)
    }

    /// Fix: `updateProgress` is now guarded by job identity, not just
    /// "something is running" — a stale progress callback from a job that's
    /// already finished must not paint the *next* running job's progress.
    @Test func lateProgressCallbackFromFinishedJobDoesNotPaintNextJob() async {
        let executor = CapturingExecutor()
        let queue = ProcessingQueue(executor: executor)
        let jobA = ProcessingJob(kind: .transcribe, meetingID: UUID())
        let jobB = ProcessingJob(kind: .enhance, meetingID: UUID())

        await queue.enqueue(jobA)
        #expect(await waitUntil { await queue.snapshot.running == jobA })
        // `running` flips synchronously in `pump()` before the executor's
        // Task actually starts, so poll for the callback rather than
        // fetching it once — otherwise this occasionally races ahead of
        // `execute(jobA:)` registering it.
        #expect(await waitUntil { await executor.progressCallback(for: jobA) != nil })
        let staleProgress = await executor.progressCallback(for: jobA)
        #expect(staleProgress != nil)

        await queue.enqueue(jobB)
        await executor.releaseHeldJob()
        #expect(await waitUntil { await queue.snapshot.running == jobB })
        #expect(await waitUntil { await queue.snapshot.runningProgress == 0.5 })

        // Job A's stale progress closure fires after B has taken over.
        staleProgress?(0.9)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await queue.snapshot.running == jobB)
        #expect(await queue.snapshot.runningProgress == 0.5)

        await executor.releaseHeldJob()
        #expect(await waitUntil { await queue.snapshot.jobCount == 0 })
    }
}

private actor SnapshotLog {
    private(set) var snapshots: [QueueSnapshot] = []

    func append(_ snapshot: QueueSnapshot) {
        snapshots.append(snapshot)
    }

    func sawProgress(_ value: Double) -> Bool {
        snapshots.contains { $0.runningProgress == value }
    }

    func sawIdle() -> Bool {
        snapshots.contains { $0.jobCount == 0 }
    }
}
