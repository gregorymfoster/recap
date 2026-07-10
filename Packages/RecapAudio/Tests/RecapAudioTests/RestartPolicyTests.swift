import Testing
@testable import RecapAudio

/// Pure-logic tests for `RestartPolicy` — the shared bounded-recovery
/// counter both of `MixerEngine`'s sides (mic and system) drive from the
/// liveness watchdog's stall/resume reports.
///
/// (`shouldAttempt()`/`shouldReport()` are mutating, and `#expect`'s macro
/// expansion can't call mutating members inline — hence the local lets.)
@Suite struct RestartPolicyTests {
    /// Drives one full stall episode to exhaustion and returns
    /// (attemptsGranted, reportFired, secondReportFired).
    private func exhaust(_ policy: inout RestartPolicy) -> (attempts: Int, reported: Bool, reportedTwice: Bool) {
        var attempts = 0
        while policy.shouldAttempt() {
            attempts += 1
            if attempts > 10 { break }  // safety against a runaway loop
        }
        let reported = policy.shouldReport()
        let reportedTwice = policy.shouldReport()
        return (attempts, reported, reportedTwice)
    }

    @Test func allowsExactlyTwoAttemptsThenReportsOnce() {
        var policy = RestartPolicy()
        let outcome = exhaust(&policy)
        #expect(outcome.attempts == RestartPolicy.attemptsAllowed)
        #expect(outcome.attempts == 2)
        #expect(outcome.reported)
        // The report fires exactly once, then stays quiet — and no attempt
        // budget reappears without a resume.
        #expect(!outcome.reportedTwice)
        let extraAttempt = policy.shouldAttempt()
        #expect(!extraAttempt)
    }

    @Test func resumeResetsAttemptsForALaterIndependentStall() {
        var policy = RestartPolicy()
        let firstAttempt = policy.shouldAttempt()
        #expect(firstAttempt)

        policy.recordResumed()

        // A fresh stall episode gets its full attempt budget again.
        let outcome = exhaust(&policy)
        #expect(outcome.attempts == RestartPolicy.attemptsAllowed)
    }

    @Test func resumeAfterReportAllowsReportingAgain() {
        var policy = RestartPolicy()
        let first = exhaust(&policy)
        #expect(first.reported)

        policy.recordResumed()

        // Mirrors the mic side's pre-existing semantics: a genuine resume
        // clears the reported latch too, so a second, independent stall can
        // attempt and (if recovery fails again) report again.
        let second = exhaust(&policy)
        #expect(second.attempts == RestartPolicy.attemptsAllowed)
        #expect(second.reported)
        #expect(!second.reportedTwice)
    }
}
