import Foundation
import Testing
@testable import RecapCore

@Suite struct RecordingClockTests {
    private let t0 = Date(timeIntervalSince1970: 1_780_000_000)

    private func t(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    @Test func elapsedTicksWhileRunning() {
        let clock = RecordingClock(startedAt: t0)
        #expect(!clock.isPaused)
        #expect(clock.elapsed(at: t0) == 0)
        #expect(clock.elapsed(at: t(90)) == 90)
    }

    @Test func pauseFreezesElapsed() {
        var clock = RecordingClock(startedAt: t0)
        clock.pause(at: t(10))
        #expect(clock.isPaused)
        #expect(clock.elapsed(at: t(10)) == 10)
        // Time keeps passing; elapsed doesn't.
        #expect(clock.elapsed(at: t(500)) == 10)
    }

    @Test func resumeContinuesFromAccumulated() {
        var clock = RecordingClock(startedAt: t0)
        clock.pause(at: t(10))
        clock.resume(at: t(60))
        #expect(!clock.isPaused)
        #expect(clock.elapsed(at: t(60)) == 10)
        #expect(clock.elapsed(at: t(75)) == 25)
    }

    @Test func doublePauseIsIdempotent() {
        var clock = RecordingClock(startedAt: t0)
        clock.pause(at: t(10))
        let frozen = clock
        clock.pause(at: t(400))
        #expect(clock == frozen)
        #expect(clock.elapsed(at: t(500)) == 10)
    }

    @Test func doubleResumeIsIdempotent() {
        var clock = RecordingClock(startedAt: t0)
        clock.pause(at: t(10))
        clock.resume(at: t(20))
        let running = clock
        clock.resume(at: t(300))
        #expect(clock == running)
        #expect(clock.elapsed(at: t(30)) == 20)
    }

    @Test func multiCycleAccumulation() {
        var clock = RecordingClock(startedAt: t0)
        clock.pause(at: t(10))    // +10 active
        clock.resume(at: t(100))
        clock.pause(at: t(130))   // +30 active
        clock.resume(at: t(1000))
        clock.pause(at: t(1005))  // +5 active
        #expect(clock.accumulated == 45)
        #expect(clock.elapsed(at: t(2000)) == 45)
    }

    @Test func syntheticStartDateInvariant() {
        var clock = RecordingClock(startedAt: t0)
        // Running, never paused: synthetic start is the real start.
        #expect(clock.syntheticStartDate(at: t(30)) == t0)

        clock.pause(at: t(10))
        clock.resume(at: t(100))
        // Invariant: now - syntheticStart == elapsed(at: now), whenever asked.
        for now in [t(100), t(130), t(986)] {
            let start = clock.syntheticStartDate(at: now)
            #expect(abs(now.timeIntervalSince(start) - clock.elapsed(at: now)) < 0.000001)
        }
        // 10s active + running since t100 → at t130 elapsed is 40.
        #expect(clock.elapsed(at: t(130)) == 40)
        #expect(clock.syntheticStartDate(at: t(130)) == t(90))
    }

    @Test func pausedClockSyntheticStartStillSatisfiesInvariant() {
        var clock = RecordingClock(startedAt: t0)
        clock.pause(at: t(25))
        let now = t(300)
        let start = clock.syntheticStartDate(at: now)
        #expect(now.timeIntervalSince(start) == clock.elapsed(at: now))
        #expect(clock.elapsed(at: now) == 25)
    }
}
