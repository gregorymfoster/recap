import Foundation
import Testing
@testable import RecapCore

/// Exercises the pure state-machine that turns `TranscriptionUpdate`s from
/// the streaming pass into live-transcript UI state — the seam that decides
/// what the transcript pane header shows (loading / live / no model /
/// failed) and what the RecordingPill's "last heard" snippet says.
@Suite struct LiveTranscriptStateTests {
    private func utterance(_ text: String, start: TimeInterval = 0, end: TimeInterval = 1) -> Utterance {
        Utterance(start: start, end: end, text: text)
    }

    @Test func startsAsNoModelInstalled() {
        #expect(LiveTranscriptState().liveState == .noModelInstalled)
    }

    @Test func loadingModelStatusUpdatesLiveState() {
        let state = LiveTranscriptState().applying(.status(.loadingModel))
        #expect(state.liveState == .loadingModel)
        #expect(state.utterances.isEmpty)
        #expect(state.partial == nil)
    }

    @Test func loadingThenLiveTransitionsInOrder() {
        var state = LiveTranscriptState()
        state = state.applying(.status(.loadingModel))
        #expect(state.liveState == .loadingModel)
        state = state.applying(.status(.live))
        #expect(state.liveState == .live)
    }

    @Test func failedStatusCarriesReason() {
        let state = LiveTranscriptState().applying(.status(.failed(reason: "model load error")))
        #expect(state.liveState == .failed(reason: "model load error"))
    }

    @Test func confirmedAppendsAndClearsPartial() {
        var state = LiveTranscriptState(partial: utterance("in progress"))
        state = state.applying(.confirmed(utterance("Hello there.")))
        #expect(state.utterances.map(\.text) == ["Hello there."])
        #expect(state.partial == nil)
    }

    @Test func confirmedUpdatesLastHeardText() {
        var state = LiveTranscriptState()
        state = state.applying(.confirmed(utterance("First sentence.")))
        #expect(state.lastHeardText == "First sentence.")
        state = state.applying(.confirmed(utterance("Second sentence.")))
        #expect(state.lastHeardText == "Second sentence.")
    }

    @Test func confirmedWithEmptyTextDoesNotClobberLastHeard() {
        var state = LiveTranscriptState()
        state = state.applying(.confirmed(utterance("Real words.")))
        state = state.applying(.confirmed(utterance("")))
        #expect(state.lastHeardText == "Real words.")
        // The empty utterance is still appended to the transcript…
        #expect(state.utterances.count == 2)
    }

    @Test func partialSetsInProgressUtteranceWithoutAppending() {
        let state = LiveTranscriptState().applying(.partial(utterance("Maya, do you want to")))
        #expect(state.partial?.text == "Maya, do you want to")
        #expect(state.utterances.isEmpty)
    }

    @Test func progressUpdateIsANoOp() {
        let before = LiveTranscriptState(liveState: .live)
        let after = before.applying(.progress(0.5))
        #expect(after == before)
    }

    @Test func fullPipelineSequenceEndsLiveWithTranscript() {
        var state = LiveTranscriptState()
        for update: TranscriptionUpdate in [
            .status(.loadingModel),
            .status(.live),
            .confirmed(utterance("Hello everyone.", start: 0, end: 2)),
            .partial(utterance("Let's get started", start: 2, end: 4)),
            .confirmed(utterance("Let's get started.", start: 2, end: 4)),
        ] {
            state = state.applying(update)
        }
        #expect(state.liveState == .live)
        #expect(state.utterances.map(\.text) == ["Hello everyone.", "Let's get started."])
        #expect(state.partial == nil)
        #expect(state.lastHeardText == "Let's get started.")
    }

    @Test func noModelInstalledNeverTransitionsWithoutAnEngine() {
        // Mirrors MeetingSessionStore.start's "no engine at all" branch: it
        // never applies any updates, so state should stay put rather than
        // drift toward `.live` on its own.
        let state = LiveTranscriptState(liveState: .noModelInstalled)
        #expect(state.liveState == .noModelInstalled)
    }
}
