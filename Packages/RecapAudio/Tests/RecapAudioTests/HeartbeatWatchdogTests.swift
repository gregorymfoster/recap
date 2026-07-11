import Testing
@testable import RecapAudio

@Suite struct HeartbeatWatchdogTests {
    @Test func doesNotFireBeforeStallTicksReached() {
        var watchdog = HeartbeatWatchdog()
        for _ in 0..<(HeartbeatWatchdog.stallTicks - 1) {
            #expect(watchdog.tick(micTotal: 0) == nil)
        }
    }

    @Test func firesExactlyAtStallTicksNotOneEarlier() {
        var watchdog = HeartbeatWatchdog()
        for _ in 0..<(HeartbeatWatchdog.stallTicks - 1) {
            #expect(watchdog.tick(micTotal: 0) == nil)
        }
        #expect(watchdog.tick(micTotal: 0) == .stalled(.mic))
    }

    /// After a fire, the counter is bumped so the very next silent tick
    /// doesn't immediately refire — a fresh full window of silence is
    /// required, mirroring `LivenessWatchdog`'s baseline-bump behavior.
    @Test func reArmsAfterAFireRequiringAFullWindowAgain() {
        var watchdog = HeartbeatWatchdog()
        for _ in 0..<HeartbeatWatchdog.stallTicks {
            _ = watchdog.tick(micTotal: 0)
        }
        for _ in 0..<(HeartbeatWatchdog.stallTicks - 1) {
            #expect(watchdog.tick(micTotal: 0) == nil)
        }
        #expect(watchdog.tick(micTotal: 0) == .stalled(.mic))
    }

    @Test func progressBeforeThresholdResetsCounterAndSuppressesFire() {
        var watchdog = HeartbeatWatchdog()
        for _ in 0..<(HeartbeatWatchdog.stallTicks - 1) {
            _ = watchdog.tick(micTotal: 0)
        }
        // Progress arrives just before the fire would have happened.
        #expect(watchdog.tick(micTotal: 100) == nil)
        // The counter is back to zero — another full window is needed.
        for _ in 0..<(HeartbeatWatchdog.stallTicks - 1) {
            #expect(watchdog.tick(micTotal: 100) == nil)
        }
        #expect(watchdog.tick(micTotal: 100) == .stalled(.mic))
    }

    @Test func resumedFiresOnProgressAfterAStall() {
        var watchdog = HeartbeatWatchdog()
        for _ in 0..<HeartbeatWatchdog.stallTicks {
            _ = watchdog.tick(micTotal: 0)
        }
        #expect(watchdog.tick(micTotal: 50) == .resumed(.mic))
    }

    @Test func noProgressAndNoStallNeverFiresResumed() {
        var watchdog = HeartbeatWatchdog()
        #expect(watchdog.tick(micTotal: 0) == nil)
        #expect(watchdog.tick(micTotal: 10) == nil)
    }
}
