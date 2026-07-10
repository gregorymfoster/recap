/// Pure bounded-recovery bookkeeping for a stalled capture source, shared by
/// `MixerEngine`'s mic and system sides so the attempt-then-report logic
/// exists exactly once.
///
/// Lifecycle per stall episode: each `.stalled` report from the watchdog asks
/// `shouldAttempt()` — the first `attemptsAllowed` calls answer true (try a
/// rebuild), after which `shouldReport()` answers true exactly once (surface
/// the stall to the UI). A `.resumed` report calls `recordResumed()`, resetting
/// both, so a later independent stall gets fresh attempts and can report again.
struct RestartPolicy {
    /// Recovery attempts per stall episode before giving up and reporting.
    static let attemptsAllowed = 2

    private var attempts = 0
    private var reported = false

    /// True (and consumes an attempt) while attempts remain for the current
    /// stall episode; false once they're exhausted.
    mutating func shouldAttempt() -> Bool {
        guard attempts < Self.attemptsAllowed else { return false }
        attempts += 1
        return true
    }

    /// True exactly once per stall episode, only after attempts are
    /// exhausted — the caller's cue to emit its one-shot UI event.
    mutating func shouldReport() -> Bool {
        guard !reported else { return false }
        reported = true
        return true
    }

    /// The stalled side made real progress again — reset for a possible
    /// later, independent stall.
    mutating func recordResumed() {
        attempts = 0
        reported = false
    }
}
