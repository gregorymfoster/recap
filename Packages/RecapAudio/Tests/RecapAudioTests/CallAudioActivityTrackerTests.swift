import Testing
@testable import RecapAudio

@Suite("CallAudioActivityTracker")
struct CallAudioActivityTrackerTests {
    @Test("a single active poll emits nothing")
    func singleActivePollEmitsNothing() {
        var tracker = CallAudioActivityTracker(startAfterPolls: 2, stopAfterPolls: 40)
        let events = tracker.ingest(activeIDs: ["us.zoom.xos"])
        #expect(events.isEmpty)
    }

    @Test("two consecutive active polls emit started once, not again on the third")
    func twoConsecutivePollsStartOnce() {
        var tracker = CallAudioActivityTracker(startAfterPolls: 2, stopAfterPolls: 40)

        #expect(tracker.ingest(activeIDs: ["us.zoom.xos"]).isEmpty)
        #expect(tracker.ingest(activeIDs: ["us.zoom.xos"]) == [.appStartedAudio(bundleID: "us.zoom.xos")])
        #expect(tracker.ingest(activeIDs: ["us.zoom.xos"]).isEmpty)
    }

    @Test("an interleaved gap resets the consecutive active count")
    func interleavedGapResetsConsecutiveCount() {
        var tracker = CallAudioActivityTracker(startAfterPolls: 2, stopAfterPolls: 40)

        // active, inactive, active, active -> should NOT have started after
        // the first active/inactive pair; needs 2 fresh consecutive polls.
        #expect(tracker.ingest(activeIDs: ["us.zoom.xos"]).isEmpty)
        #expect(tracker.ingest(activeIDs: []).isEmpty)
        #expect(tracker.ingest(activeIDs: ["us.zoom.xos"]).isEmpty)
        #expect(tracker.ingest(activeIDs: ["us.zoom.xos"]) == [.appStartedAudio(bundleID: "us.zoom.xos")])
    }

    @Test("stops only after N consecutive inactive polls")
    func stopsOnlyAfterNInactivePolls() {
        var tracker = CallAudioActivityTracker(startAfterPolls: 2, stopAfterPolls: 3)

        #expect(tracker.ingest(activeIDs: ["us.zoom.xos"]).isEmpty)
        #expect(tracker.ingest(activeIDs: ["us.zoom.xos"]) == [.appStartedAudio(bundleID: "us.zoom.xos")])

        // 2 inactive polls: not yet stopped (need 3 consecutive).
        #expect(tracker.ingest(activeIDs: []).isEmpty)
        #expect(tracker.ingest(activeIDs: []).isEmpty)
        // 3rd consecutive inactive poll: stopped.
        #expect(tracker.ingest(activeIDs: []) == [.appStoppedAudio(bundleID: "us.zoom.xos")])
    }

    @Test("a muted moment mid-call (single inactive poll) does not end the session")
    func mutedMomentDoesNotEndSession() {
        var tracker = CallAudioActivityTracker(startAfterPolls: 2, stopAfterPolls: 40)

        #expect(tracker.ingest(activeIDs: ["us.zoom.xos"]).isEmpty)
        #expect(tracker.ingest(activeIDs: ["us.zoom.xos"]) == [.appStartedAudio(bundleID: "us.zoom.xos")])

        // Single inactive poll, then active again — should not stop.
        #expect(tracker.ingest(activeIDs: []).isEmpty)
        #expect(tracker.ingest(activeIDs: ["us.zoom.xos"]).isEmpty)
        #expect(tracker.ingest(activeIDs: ["us.zoom.xos"]).isEmpty)
    }

    @Test("reactivation mid-countdown resets the inactive count")
    func reactivationMidCountdownResetsInactiveCount() {
        var tracker = CallAudioActivityTracker(startAfterPolls: 2, stopAfterPolls: 5)

        #expect(tracker.ingest(activeIDs: ["us.zoom.xos"]).isEmpty)
        #expect(tracker.ingest(activeIDs: ["us.zoom.xos"]) == [.appStartedAudio(bundleID: "us.zoom.xos")])

        // 4 inactive polls (one short of stopAfterPolls=5), then reactivate.
        #expect(tracker.ingest(activeIDs: []).isEmpty)
        #expect(tracker.ingest(activeIDs: []).isEmpty)
        #expect(tracker.ingest(activeIDs: []).isEmpty)
        #expect(tracker.ingest(activeIDs: []).isEmpty)
        #expect(tracker.ingest(activeIDs: ["us.zoom.xos"]).isEmpty)

        // Countdown should have reset: 4 more inactive polls should NOT stop it.
        #expect(tracker.ingest(activeIDs: []).isEmpty)
        #expect(tracker.ingest(activeIDs: []).isEmpty)
        #expect(tracker.ingest(activeIDs: []).isEmpty)
        #expect(tracker.ingest(activeIDs: []).isEmpty)
        // 5th consecutive inactive poll since reactivation: now it stops.
        #expect(tracker.ingest(activeIDs: []) == [.appStoppedAudio(bundleID: "us.zoom.xos")])
    }

    @Test("multiple ids are tracked independently")
    func multipleIdsTrackedIndependently() {
        var tracker = CallAudioActivityTracker(startAfterPolls: 2, stopAfterPolls: 3)

        // Zoom starts first poll; Teams isn't active yet.
        #expect(tracker.ingest(activeIDs: ["us.zoom.xos"]).isEmpty)
        // Zoom's 2nd poll starts it; Teams' 1st poll doesn't start it yet.
        #expect(
            tracker.ingest(activeIDs: ["us.zoom.xos", "com.microsoft.teams2"])
                == [.appStartedAudio(bundleID: "us.zoom.xos")]
        )
        // Teams' 2nd consecutive poll starts it; Zoom continues (no event).
        #expect(
            tracker.ingest(activeIDs: ["us.zoom.xos", "com.microsoft.teams2"])
                == [.appStartedAudio(bundleID: "com.microsoft.teams2")]
        )

        // Zoom drops out, Teams stays active.
        #expect(tracker.ingest(activeIDs: ["com.microsoft.teams2"]).isEmpty)
        #expect(tracker.ingest(activeIDs: ["com.microsoft.teams2"]).isEmpty)
        // Zoom's 3rd consecutive inactive poll: stops. Teams unaffected.
        #expect(
            tracker.ingest(activeIDs: ["com.microsoft.teams2"])
                == [.appStoppedAudio(bundleID: "us.zoom.xos")]
        )
    }

    @Test("events are returned in deterministic sorted order")
    func eventsReturnedInSortedOrder() {
        var tracker = CallAudioActivityTracker(startAfterPolls: 1, stopAfterPolls: 40)

        let events = tracker.ingest(activeIDs: ["us.zoom.xos", "com.microsoft.teams2", "com.apple.Music"])
        #expect(events == [
            .appStartedAudio(bundleID: "com.apple.Music"),
            .appStartedAudio(bundleID: "com.microsoft.teams2"),
            .appStartedAudio(bundleID: "us.zoom.xos"),
        ])
    }

    @Test("an id that never started emits nothing while merely inactive")
    func neverStartedEmitsNothingWhileInactive() {
        var tracker = CallAudioActivityTracker(startAfterPolls: 3, stopAfterPolls: 40)

        // Only 1 active poll — never crosses the start threshold.
        #expect(tracker.ingest(activeIDs: ["us.zoom.xos"]).isEmpty)
        // Now inactive — should emit nothing since it never started.
        #expect(tracker.ingest(activeIDs: []).isEmpty)
        #expect(tracker.ingest(activeIDs: []).isEmpty)
        #expect(tracker.ingest(activeIDs: []).isEmpty)
    }

    @Test("default thresholds match the documented 2 start / 40 stop polls")
    func defaultThresholdsMatchDocumentedValues() {
        let tracker = CallAudioActivityTracker()
        #expect(tracker.startAfterPolls == 2)
        #expect(tracker.stopAfterPolls == 40)
    }

    @Test("startAfterPolls of 1 starts immediately on the first active poll")
    func startAfterOnePollStartsImmediately() {
        var tracker = CallAudioActivityTracker(startAfterPolls: 1, stopAfterPolls: 40)
        #expect(tracker.ingest(activeIDs: ["us.zoom.xos"]) == [.appStartedAudio(bundleID: "us.zoom.xos")])
    }
}
