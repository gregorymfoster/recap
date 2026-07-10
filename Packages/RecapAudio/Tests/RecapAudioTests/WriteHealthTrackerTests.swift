import Foundation
import Testing
@testable import RecapAudio

@Suite struct WriteHealthTrackerTests {
    @Test func startsHealthy() {
        let tracker = WriteHealthTracker()
        #expect(!tracker.isUnhealthy)
    }

    @Test func dropsAccumulateStrikesUntilThreshold() {
        var tracker = WriteHealthTracker()
        for _ in 0..<(WriteHealthTracker.strikeThreshold - 1) {
            tracker.recordDropped()
        }
        #expect(!tracker.isUnhealthy)

        tracker.recordDropped()
        #expect(tracker.isUnhealthy)
    }

    @Test func slowWritesAccumulateStrikesUntilThreshold() {
        var tracker = WriteHealthTracker()
        let start = ContinuousClock.now

        for i in 0..<(WriteHealthTracker.strikeThreshold - 1) {
            let began = start.advanced(by: .seconds(i * 10))
            tracker.recordWriteStarted(at: began)
            tracker.recordWriteCompleted(at: began.advanced(by: .seconds(4)))
        }
        #expect(!tracker.isUnhealthy)

        let lastBegan = start.advanced(by: .seconds(WriteHealthTracker.strikeThreshold * 10))
        tracker.recordWriteStarted(at: lastBegan)
        tracker.recordWriteCompleted(at: lastBegan.advanced(by: .seconds(4)))
        #expect(tracker.isUnhealthy)
    }

    @Test func writeUnderThresholdDoesNotCountAsStrike() {
        var tracker = WriteHealthTracker()
        let start = ContinuousClock.now

        for i in 0..<10 {
            let began = start.advanced(by: .seconds(i))
            tracker.recordWriteStarted(at: began)
            tracker.recordWriteCompleted(at: began.advanced(by: .milliseconds(50)))
        }
        #expect(!tracker.isUnhealthy)
    }

    @Test func timelyWriteResetsConsecutiveStrikesFromDrops() {
        var tracker = WriteHealthTracker()
        tracker.recordDropped()
        tracker.recordDropped()
        #expect(!tracker.isUnhealthy)

        let start = ContinuousClock.now
        tracker.recordWriteStarted(at: start)
        tracker.recordWriteCompleted(at: start.advanced(by: .milliseconds(10)))

        // The reset means it now takes a fresh run of strikes to trip, not
        // just one more.
        tracker.recordDropped()
        #expect(!tracker.isUnhealthy)
    }

    @Test func timelyWriteResetsConsecutiveStrikesFromSlowWrites() {
        var tracker = WriteHealthTracker()
        let start = ContinuousClock.now
        tracker.recordWriteStarted(at: start)
        tracker.recordWriteCompleted(at: start.advanced(by: .seconds(5)))
        tracker.recordWriteStarted(at: start.advanced(by: .seconds(10)))
        tracker.recordWriteCompleted(at: start.advanced(by: .seconds(15)))
        #expect(!tracker.isUnhealthy)

        // A fast write in between resets the strikes back to zero.
        tracker.recordWriteStarted(at: start.advanced(by: .seconds(20)))
        tracker.recordWriteCompleted(at: start.advanced(by: .seconds(20) + .milliseconds(10)))

        tracker.recordWriteStarted(at: start.advanced(by: .seconds(25)))
        tracker.recordWriteCompleted(at: start.advanced(by: .seconds(30)))
        #expect(!tracker.isUnhealthy)
    }

    @Test func writeCompletedWithoutMatchingStartIsANoOp() {
        var tracker = WriteHealthTracker()
        tracker.recordWriteCompleted(at: ContinuousClock.now)
        #expect(!tracker.isUnhealthy)
    }
}

// MARK: - WriteFailureLatch

@Suite struct WriteFailureLatchTests {
    @Test func reportsExactlyOnceWhenDropsCrossThreshold() {
        let latch = WriteFailureLatch()
        var reported = 0
        for _ in 0..<(WriteHealthTracker.strikeThreshold + 5) {
            if latch.recordDropped() {
                reported += 1
            }
        }
        #expect(reported == 1)
    }

    @Test func thrownErrorLatchIsIndependentOfHealthTrackerButSharesOneShot() {
        let latch = WriteFailureLatch()
        #expect(latch.recordThrownErrorThresholdTripped())
        // A second, independent trigger must not report again.
        #expect(!latch.recordThrownErrorThresholdTripped())
        #expect(!latch.recordDropped())
    }
}
