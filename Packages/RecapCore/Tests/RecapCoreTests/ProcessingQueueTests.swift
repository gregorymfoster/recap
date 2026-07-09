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
        let running = ProcessingJob(kind: .transcribe, meetingID: targetID)
        let pendingSameMeeting = ProcessingJob(kind: .enhance, meetingID: targetID)
        let pendingOtherMeeting = ProcessingJob(kind: .transcribe, meetingID: otherID)
        await queue.enqueue(running)
        #expect(await waitUntil { await queue.snapshot.running == running })
        await queue.enqueue(pendingSameMeeting)
        await queue.enqueue(pendingOtherMeeting)
        #expect(await queue.snapshot.pending == [pendingSameMeeting, pendingOtherMeeting])

        await queue.cancel(meetingID: targetID)

        // The pending job for the trashed meeting is gone; the other
        // meeting's pending job survives untouched.
        #expect(await queue.snapshot.pending == [pendingOtherMeeting])
        // The already-running job for the trashed meeting isn't interrupted —
        // cancel only prunes PENDING work.
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
