import Testing
@testable import RecapAudio

/// Pure-logic tests for `LivenessWatchdog`, mirroring the behaviors
/// `MeetingRecorderTests`'s system-stall tests exercise end-to-end through
/// `MixerEngine`, plus the mic direction and resume/reset semantics that
/// only exist at this layer.
@Suite struct LivenessWatchdogTests {
    private let threshold = LivenessWatchdog.stallThreshold

    // MARK: System-stall direction (symmetric with the mic direction)

    @Test func systemStallFiresWhenMicKeepsAdvancingAndSystemDoesNot() {
        var watchdog = LivenessWatchdog()

        // Both sides make some initial progress together.
        #expect(watchdog.recordProgress(micTotal: 1_000, systemTotal: 1_000, systemExpected: true, micExpected: true) == nil)

        // System stops advancing; mic keeps going past the threshold.
        let event = watchdog.recordProgress(
            micTotal: 1_000 + threshold + 1, systemTotal: 1_000, systemExpected: true, micExpected: true
        )
        #expect(event == .stalled(.system))
    }

    @Test func systemStallRefiresAfterEachFurtherThresholdOfContinuedSilence() {
        var watchdog = LivenessWatchdog()
        #expect(watchdog.recordProgress(micTotal: 0, systemTotal: 0, systemExpected: true, micExpected: true) == nil)

        let first = watchdog.recordProgress(
            micTotal: threshold + 1, systemTotal: 0, systemExpected: true, micExpected: true
        )
        #expect(first == .stalled(.system))

        // Not enough further silence yet — must not refire immediately.
        let tooSoon = watchdog.recordProgress(
            micTotal: threshold + 1 + 10, systemTotal: 0, systemExpected: true, micExpected: true
        )
        #expect(tooSoon == nil)

        // Another full threshold of continued silence — measured from the
        // bumped baseline (`threshold + 1`, set when `first` fired), not
        // from zero. This is what lets `MeetingRecorder` retry the tap
        // rebuild a bounded number of times instead of latching forever.
        let second = watchdog.recordProgress(
            micTotal: threshold + 1 + threshold + 2, systemTotal: 0, systemExpected: true, micExpected: true
        )
        #expect(second == .stalled(.system))
    }

    @Test func systemResumingAfterStallReportsResumedExactlyOnce() {
        var watchdog = LivenessWatchdog()
        #expect(watchdog.recordProgress(micTotal: 0, systemTotal: 0, systemExpected: true, micExpected: true) == nil)

        let stalled = watchdog.recordProgress(
            micTotal: threshold + 1, systemTotal: 0, systemExpected: true, micExpected: true
        )
        #expect(stalled == .stalled(.system))

        // System audio starts producing samples again (a successful rebuild).
        let resumed = watchdog.recordProgress(
            micTotal: threshold + 100, systemTotal: 1, systemExpected: true, micExpected: true
        )
        #expect(resumed == .resumed(.system))

        // Continued system progress afterward reports nothing further.
        let quiet = watchdog.recordProgress(
            micTotal: threshold + 200, systemTotal: 2, systemExpected: true, micExpected: true
        )
        #expect(quiet == nil)
    }

    @Test func systemStayingLiveNeverFiresSystemStall() {
        var watchdog = LivenessWatchdog()
        var lastEvent: LivenessWatchdog.Event?
        var mic = 0
        var system = 0
        for _ in 0..<10 {
            mic += threshold / 2
            system += threshold / 2
            lastEvent = watchdog.recordProgress(
                micTotal: mic, systemTotal: system, systemExpected: true, micExpected: true
            )
            #expect(lastEvent != .stalled(.system))
        }
    }

    @Test func systemStallNotCheckedWhenSystemNotExpected() {
        // Mic-only recording: system total pinned at 0 forever must never
        // spuriously report a system stall.
        var watchdog = LivenessWatchdog()
        let event = watchdog.recordProgress(
            micTotal: threshold * 3, systemTotal: 0, systemExpected: false, micExpected: true
        )
        #expect(event == nil)
    }

    // MARK: Mic-stall direction (the new, symmetric half)

    @Test func micStallFiresWhenSystemKeepsAdvancingAndMicDoesNot() {
        var watchdog = LivenessWatchdog()

        #expect(watchdog.recordProgress(micTotal: 1_000, systemTotal: 1_000, systemExpected: true, micExpected: true) == nil)

        let event = watchdog.recordProgress(
            micTotal: 1_000, systemTotal: 1_000 + threshold + 1, systemExpected: true, micExpected: true
        )
        #expect(event == .stalled(.mic))
    }

    @Test func micStallRefiresAfterEachFurtherThresholdOfContinuedSilence() {
        var watchdog = LivenessWatchdog()
        #expect(watchdog.recordProgress(micTotal: 0, systemTotal: 0, systemExpected: true, micExpected: true) == nil)

        let first = watchdog.recordProgress(
            micTotal: 0, systemTotal: threshold + 1, systemExpected: true, micExpected: true
        )
        #expect(first == .stalled(.mic))

        // Not enough further silence yet — must not refire immediately.
        let tooSoon = watchdog.recordProgress(
            micTotal: 0, systemTotal: threshold + 1 + 10, systemExpected: true, micExpected: true
        )
        #expect(tooSoon == nil)

        // Another full threshold of continued silence — measured from the
        // bumped baseline (`threshold + 1`, set when `first` fired), not
        // from zero. This is what lets `MeetingRecorder` retry a bounded
        // number of times rather than the mic direction latching forever
        // like the system side does.
        let second = watchdog.recordProgress(
            micTotal: 0, systemTotal: threshold + 1 + threshold + 2, systemExpected: true, micExpected: true
        )
        #expect(second == .stalled(.mic))
    }

    @Test func micResumingAfterStallReportsResumedExactlyOnce() {
        var watchdog = LivenessWatchdog()
        #expect(watchdog.recordProgress(micTotal: 0, systemTotal: 0, systemExpected: true, micExpected: true) == nil)

        let stalled = watchdog.recordProgress(
            micTotal: 0, systemTotal: threshold + 1, systemExpected: true, micExpected: true
        )
        #expect(stalled == .stalled(.mic))

        // Mic starts producing samples again.
        let resumed = watchdog.recordProgress(
            micTotal: 1, systemTotal: threshold + 100, systemExpected: true, micExpected: true
        )
        #expect(resumed == .resumed(.mic))

        // Continued mic progress afterward reports nothing further.
        let quiet = watchdog.recordProgress(
            micTotal: 2, systemTotal: threshold + 200, systemExpected: true, micExpected: true
        )
        #expect(quiet == nil)
    }

    @Test func micStallNotCheckedWhenMicNotExpected() {
        // Mic denied entirely from the start: mic total pinned at 0 must
        // never spuriously report a mic stall.
        var watchdog = LivenessWatchdog()
        let event = watchdog.recordProgress(
            micTotal: 0, systemTotal: threshold * 3, systemExpected: true, micExpected: false
        )
        #expect(event == nil)
    }

    @Test func micStallNotCheckedWhenSystemNotExpected() {
        // System audio off: there's no independent heartbeat to measure the
        // mic's silence against, so the mic direction must never fire either
        // — a known limitation of the push-driven design (see the type's
        // doc comment), not a bug.
        var watchdog = LivenessWatchdog()
        let event = watchdog.recordProgress(
            micTotal: 0, systemTotal: 0, systemExpected: false, micExpected: true
        )
        #expect(event == nil)
    }

    @Test func bothDirectionsAreIndependent() {
        // A stall/resume reported on one side must not affect the other
        // side's bookkeeping.
        var watchdog = LivenessWatchdog()
        #expect(watchdog.recordProgress(micTotal: 0, systemTotal: 0, systemExpected: true, micExpected: true) == nil)

        let micStall = watchdog.recordProgress(
            micTotal: 0, systemTotal: threshold + 1, systemExpected: true, micExpected: true
        )
        #expect(micStall == .stalled(.mic))

        // Mic resumes with a small increment (not a big jump back past the
        // system baseline, which would spuriously look like a system stall
        // in the same call — real capture always advances incrementally).
        let micResumed = watchdog.recordProgress(
            micTotal: 1, systemTotal: threshold + 2, systemExpected: true, micExpected: true
        )
        #expect(micResumed == .resumed(.mic))

        // Now flip it: mic keeps advancing well past the threshold while
        // system audio stops making progress — the system direction should
        // still fire normally, unaffected by the earlier mic-stall episode.
        let systemStall = watchdog.recordProgress(
            micTotal: 1 + threshold + 1, systemTotal: threshold + 2, systemExpected: true, micExpected: true
        )
        #expect(systemStall == .stalled(.system))
    }
}
