import Foundation
import Testing
@testable import RecapCore
@testable import RecapUI

/// Invariants for every named `-fixtures <scenario>` graph. These exist so a
/// future edit to `FixtureScenarios.swift` can't silently break a scenario's
/// contract (e.g. `busy` dropping below its "exercises grouping" meeting
/// count, or `empty` accidentally shipping a meeting).
@MainActor
@Suite struct FixtureScenariosTests {
    // MARK: Parsing / fallback

    @Test func rawValueRoundTripsForEveryScenario() {
        for scenario in FixtureScenario.allCases {
            #expect(FixtureScenario(rawScenario: scenario.rawValue) == scenario)
        }
    }

    @Test func unknownScenarioFallsBackToDefault() {
        #expect(FixtureScenario(rawScenario: "not-a-real-scenario") == .default)
    }

    // MARK: default

    @Test func defaultHasAtLeastOnePlayableReadyMeeting() {
        let library = FixtureScenario.default.library
        let readyMeetings = library.meetings.filter { $0.meeting.status == .ready }
        #expect(!readyMeetings.isEmpty)
        // At least one ready meeting must carry a real (non-/dev/null) folder
        // so the player bar has something to dock — see `FixtureAudio`.
        #expect(readyMeetings.contains { $0.folderURL.path != "/dev/null" })
    }

    @Test func defaultHasQueueSummary() {
        #expect(FixtureScenario.default.library.queueSummary != nil)
    }

    // MARK: empty

    @Test func emptyHasNoMeetings() {
        let library = FixtureScenario.empty.library
        #expect(library.meetings.isEmpty)
        #expect(library.queueSummary == nil)
    }

    @Test func emptyHasNoUpcomingEvents() {
        let upcoming = FixtureScenario.empty.upcoming
        upcoming.refresh()
        #expect(upcoming.events.isEmpty)
    }

    @Test func emptyCalendarIsUnauthorized() {
        // `.empty` matches a bare first run: no meetings AND calendar not
        // connected — the agenda's "Connect your calendar" affordance.
        let upcoming = FixtureScenario.empty.upcoming
        upcoming.refresh()
        #expect(!upcoming.isAvailable)
    }

    // MARK: firstRunWithAgenda

    @Test func firstRunWithAgendaHasNoMeetingsButHasUpcomingEvents() {
        let library = FixtureScenario.firstRunWithAgenda.library
        #expect(library.meetings.isEmpty)

        let upcoming = FixtureScenario.firstRunWithAgenda.upcoming
        upcoming.refresh()
        #expect(upcoming.isAvailable)
        #expect(!upcoming.events.isEmpty)
    }

    // MARK: noMeetingsToday

    @Test func noMeetingsTodayIsAuthorizedWithZeroEvents() {
        // Authorized but empty — distinct from `.empty`'s unauthorized
        // state. Uses the populated `default` library so the empty agenda
        // state is also exercised above a non-trivial meeting list.
        let library = FixtureScenario.noMeetingsToday.library
        #expect(!library.meetings.isEmpty)

        let upcoming = FixtureScenario.noMeetingsToday.upcoming
        upcoming.refresh()
        #expect(upcoming.isAvailable)
        #expect(upcoming.events.isEmpty)
    }

    // MARK: busy

    @Test func busyHasManyMeetingsAcrossStatuses() {
        let library = FixtureScenario.busy.library
        #expect(library.meetings.count >= 20)
        let statuses = Set(library.meetings.map(\.meeting.status.caseLabel))
        // At least ready, queued, transcribing, needsModel, error should all
        // appear — that's the point of this scenario (exercise every status
        // the list can render).
        #expect(statuses.isSuperset(of: ["ready", "queued", "transcribing", "needsModel", "error"]))
    }

    @Test func busyHasAtLeastOnePlayableOrAnnotatedMeeting() {
        let library = FixtureScenario.busy.library
        let readyMeetings = library.meetings.filter { $0.meeting.status == .ready }
        #expect(!readyMeetings.isEmpty)
        // Several ready meetings should carry canned transcripts/notes.
        let withNotes = readyMeetings.filter { !library.loadNotes(for: $0).isEmpty }
        #expect(!withNotes.isEmpty)
    }

    // MARK: processing

    @Test func processingHasInFlightMeetings() {
        let library = FixtureScenario.processing.library
        let inFlight = library.meetings.filter {
            switch $0.meeting.status {
            case .transcribing, .queued, .enhancing: true
            default: false
            }
        }
        #expect(inFlight.count >= 3)
        #expect(library.queueSummary != nil)
        #expect(library.queueSummary?.jobCount ?? 0 > 0)
    }

    // MARK: error

    @Test func errorHasFailedAndRecoverableMeetings() {
        let library = FixtureScenario.error.library
        let failed = library.meetings.filter {
            if case .error = $0.meeting.status { return true }
            return false
        }
        let recoverable = library.meetings.filter { $0.meeting.status == .needsModel }
        #expect(!failed.isEmpty)
        #expect(!recoverable.isEmpty)
        #expect(library.queueSummary?.pauseReason != nil)
    }

    // MARK: default forwarding

    @Test func libraryStoreFixtureMatchesDefaultScenarioShape() {
        // `LibraryStore.fixture()` is the widely-used entry point in
        // previews/tests; it must keep forwarding to the default scenario
        // rather than drifting into its own copy.
        let viaLegacyEntryPoint = LibraryStore.fixture()
        let viaScenario = FixtureScenario.default.library
        #expect(viaLegacyEntryPoint.meetings.count == viaScenario.meetings.count)
    }
}

private extension MeetingStatus {
    /// Coarse case label for set-membership assertions above — avoids
    /// pattern-matching every associated-value case by hand in the test.
    var caseLabel: String {
        switch self {
        case .recording: "recording"
        case .queued: "queued"
        case .transcribing: "transcribing"
        case .enhancing: "enhancing"
        case .ready: "ready"
        case .needsModel: "needsModel"
        case .error: "error"
        case .recovered: "recovered"
        }
    }
}
